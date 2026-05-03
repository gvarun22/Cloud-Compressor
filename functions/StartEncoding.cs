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
            var ffmpegCmd = $"apk add --no-cache curl && mkdir -p /tmp/output && " +
                $"ffmpeg -y -i '{inputSasUrl}' " +
                $"-c:v libx265 -crf 24 -preset veryfast -pix_fmt yuv420p -tag:v hvc1 -c:a copy " +
                $"-map_metadata 0 -movflags use_metadata_tags " +
                $"-metadata comment=cloudcompressor:crf24:h265:veryfast:hvc1 " +
                $"/tmp/output/{blobName} && " +
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
