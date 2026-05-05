using Azure;
using Azure.Data.Tables;
using Azure.ResourceManager;
using Azure.ResourceManager.ContainerInstance;
using Azure.ResourceManager.ContainerInstance.Models;
using Azure.ResourceManager.Resources;
using Azure.Security.KeyVault.Secrets;
using Azure.Storage.Blobs;
using Azure.Storage.Sas;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace CloudCompressor;

public class StartEncoding(
    BlobServiceClient blobService,
    TableServiceClient tableService,
    ArmClient armClient,
    SecretClient kvClient)
{
    private readonly TableClient _table          = tableService.GetTableClient("CompressionJobs");
    private readonly string _saName             = Environment.GetEnvironmentVariable("STORAGE_ACCOUNT_NAME")!;
    private readonly string _rg                 = Environment.GetEnvironmentVariable("RESOURCE_GROUP_NAME")!;
    private readonly string _aciLocation        = Environment.GetEnvironmentVariable("ACI_LOCATION")!;
    private readonly string _acrServer          = Environment.GetEnvironmentVariable("ACR_LOGIN_SERVER")!;
    private readonly string _subscriptionId     = Environment.GetEnvironmentVariable("ACI_SUBSCRIPTION_ID")!;

    [Function("Start-Encoding")]
    public async Task Run([TimerTrigger("*/5 * * * *")] TimerInfo _, FunctionContext ctx)
    {
        var log = ctx.GetLogger<StartEncoding>();
        log.LogInformation("Start-Encoding fired at {time}", DateTimeOffset.UtcNow);

        var pendingJobs = new List<TableEntity>();
        await foreach (var job in _table.QueryAsync<TableEntity>(
            filter: "PartitionKey eq 'jobs' and status eq 'pending'"))
            pendingJobs.Add(job);

        if (pendingJobs.Count == 0) { log.LogInformation("No pending jobs."); return; }
        log.LogInformation("Found {count} pending job(s).", pendingJobs.Count);

        var acrUsername = (await kvClient.GetSecretAsync("acr-username")).Value.Value;
        var acrPassword = (await kvClient.GetSecretAsync("acr-password")).Value.Value;

        var rgId = ResourceGroupResource.CreateResourceIdentifier(_subscriptionId, _rg);
        var rg   = armClient.GetResourceGroupResource(rgId);

        var delegationKey = (await blobService.GetUserDelegationKeyAsync(
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddHours(6))).Value;

        foreach (var job in pendingJobs)
        {
            var jobId    = job.RowKey;
            var ext      = job.GetString("extension") ?? "mp4";
            var blobName = $"{jobId}.{ext}";

            var inputBlob = blobService.GetBlobContainerClient("input").GetBlobClient(blobName);
            if (!await inputBlob.ExistsAsync())
            {
                log.LogInformation("Job {jobId}: blob not yet uploaded — skipping.", jobId);
                continue;
            }

            var props            = await inputBlob.GetPropertiesAsync();
            var originalSizeBytes = props.Value.ContentLength;

            var inputSas = new BlobSasBuilder
            {
                BlobContainerName = "input", BlobName = blobName, Resource = "b",
                ExpiresOn = DateTimeOffset.UtcNow.AddHours(6)
            };
            inputSas.SetPermissions(BlobSasPermissions.Read);
            var inputSasUrl = new BlobUriBuilder(inputBlob.Uri)
                { Sas = inputSas.ToSasQueryParameters(delegationKey, _saName) }.ToUri();

            var outputBlob = blobService.GetBlobContainerClient("output").GetBlobClient(blobName);
            var outputSas  = new BlobSasBuilder
            {
                BlobContainerName = "output", BlobName = blobName, Resource = "b",
                ExpiresOn = DateTimeOffset.UtcNow.AddHours(6)
            };
            outputSas.SetPermissions(BlobSasPermissions.Create | BlobSasPermissions.Write);
            var outputSasUrl = new BlobUriBuilder(outputBlob.Uri)
                { Sas = outputSas.ToSasQueryParameters(delegationKey, _saName) }.ToUri();

            var aciName   = $"aci-{jobId}";
            // FFmpeg cannot round-trip Apple timed metadata tracks (mebx streams) that carry
            // camera model, lens, and GPS. exiftool handles Apple QuickTime metadata correctly.
            // Step 1: FFmpeg encodes video/audio.
            // Step 2: exiftool copies all QuickTime metadata from original to output.
            // Step 3: exiftool re-sets our encode marker (TagsFromFile may overwrite it).
            // FFmpeg cannot round-trip the Apple mebx timed metadata track (lens model, GPS) through
            // its MOV muxer. MP4Box (GPAC) grafts that track from the original at the container level.
            // exiftool then copies Keys/ilst atoms (camera model, creation time, location ISO6709).
            var ffmpegCmd = $"apk add --no-cache curl exiftool gpac && " +
                $"curl -sf -o /tmp/input.{ext} '{inputSasUrl}' && " +
                $"mkdir -p /tmp/output && " +
                $"ffmpeg -y -i /tmp/input.{ext} " +
                $"-map 0:v:0 -map 0:a " +
                $"-c:v libx265 -crf 24 -preset veryfast -pix_fmt yuv420p -tag:v hvc1 " +
                $"-c:a copy " +
                $"/tmp/output/{blobName} && " +
                $"(MP4Box -add /tmp/output/{blobName} -add /tmp/input.{ext}#3 -out /tmp/output/{blobName}.merged 2>/dev/null && mv /tmp/output/{blobName}.merged /tmp/output/{blobName} || rm -f /tmp/output/{blobName}.merged) && " +
                $"exiftool -overwrite_original -TagsFromFile /tmp/input.{ext} '-QuickTime:all>QuickTime:all' /tmp/output/{blobName} && " +
                $"exiftool -overwrite_original '-Comment=cloudcompressor:crf24:h265:veryfast:hvc1' /tmp/output/{blobName} && " +
                $"curl -sf -X PUT " +
                $"-H 'x-ms-blob-type: BlockBlob' " +
                $"-H 'Content-Type: application/octet-stream' " +
                $"--upload-file /tmp/output/{blobName} '{outputSasUrl}'";

            var containerData = new ContainerGroupData(
                new Azure.Core.AzureLocation(_aciLocation),
                [
                    new ContainerInstanceContainer(
                        "ffmpeg",
                        $"{_acrServer}/ffmpeg:4.4-alpine",
                        new ContainerResourceRequirements(
                            new ContainerResourceRequestsContent(1.5, 1.0)))
                    {
                        Command = { "sh", "-c", ffmpegCmd }
                    }
                ],
                ContainerInstanceOperatingSystemType.Linux)
            {
                RestartPolicy = ContainerGroupRestartPolicy.Never,
                ImageRegistryCredentials =
                {
                    new ContainerGroupImageRegistryCredential(_acrServer)
                    {
                        Username = acrUsername,
                        Password = acrPassword
                    }
                }
            };

            log.LogInformation("Creating ACI {aciName} in {loc}...", aciName, _aciLocation);
            await rg.GetContainerGroups()
                .CreateOrUpdateAsync(WaitUntil.Started, aciName, containerData);

            job["aciName"]          = aciName;
            job["aciStartedAt"]     = DateTimeOffset.UtcNow.ToString("o");
            job["originalSizeBytes"] = originalSizeBytes;
            job["status"]           = "submitted";
            try
            {
                await _table.UpdateEntityAsync(job, job.ETag, TableUpdateMode.Replace);
                log.LogInformation("Job {jobId} submitted (ACI {aciName}).", jobId, aciName);
            }
            catch (RequestFailedException ex) when (ex.Status == 412)
            {
                log.LogWarning("Job {jobId} already claimed by another instance.", jobId);
            }
        }
    }
}
