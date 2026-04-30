using Azure;
using Azure.Data.Tables;
using Azure.ResourceManager;
using Azure.ResourceManager.ContainerInstance;
using Azure.ResourceManager.Resources;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace CloudCompressor;

public class CollectJobs(BlobServiceClient blobService, TableServiceClient tableService, ArmClient armClient)
{
    private readonly TableClient _table      = tableService.GetTableClient("CompressionJobs");
    private readonly string _saName         = Environment.GetEnvironmentVariable("STORAGE_ACCOUNT_NAME")!;
    private readonly string _rg             = Environment.GetEnvironmentVariable("RESOURCE_GROUP_NAME")!;
    private readonly string _subscriptionId = Environment.GetEnvironmentVariable("ACI_SUBSCRIPTION_ID")!;
    private const int TimeoutMinutes        = 180;

    [Function("Collect-Jobs")]
    public async Task Run([TimerTrigger("0 */15 * * * *")] TimerInfo timer, FunctionContext ctx)
    {
        var log = ctx.GetLogger<CollectJobs>();
        log.LogInformation("Collect-Jobs triggered at {time}", DateTimeOffset.UtcNow);

        var activeJobs = new List<TableEntity>();
        await foreach (var job in _table.QueryAsync<TableEntity>(filter:
            "PartitionKey eq 'jobs' and (status eq 'pending' or status eq 'submitted' or status eq 'processing')"))
            activeJobs.Add(job);

        if (activeJobs.Count == 0) { log.LogInformation("No active jobs."); return; }
        log.LogInformation("Found {count} active job(s).", activeJobs.Count);

        foreach (var job in activeJobs)
        {
            var jobId   = job.RowKey;
            var aciName = job.GetString("aciName");

            if (job.GetString("status") == "pending" && string.IsNullOrEmpty(aciName))
            {
                log.LogInformation("Job {jobId}: pending, no ACI yet — skipping.", jobId);
                continue;
            }

            if (job.GetString("status") != "processing")
            {
                job["status"] = "processing";
                try { await _table.UpdateEntityAsync(job, job.ETag, TableUpdateMode.Replace); }
                catch (RequestFailedException ex) when (ex.Status == 412)
                {
                    log.LogInformation("Job {jobId} already claimed — skipping.", jobId);
                    continue;
                }
            }

            if (string.IsNullOrEmpty(aciName))
            {
                log.LogWarning("Job {jobId}: no aciName — marking failed.", jobId);
                await MarkFailed(job, "No ACI name — Start-Encoding failed before creating ACI");
                continue;
            }

            var clockBase   = job.GetString("aciStartedAt") ?? job.GetString("startedAt")!;
            var baseTime    = DateTimeOffset.Parse(clockBase);
            var ageMinutes  = (DateTimeOffset.UtcNow - baseTime).TotalMinutes;
            var timedOut    = ageMinutes > TimeoutMinutes;

            ContainerGroupResource? aci = null;
            try
            {
                var aciId = ContainerGroupResource.CreateResourceIdentifier(_subscriptionId, _rg, aciName);
                aci = (await armClient.GetContainerGroupResource(aciId).GetAsync()).Value;
            }
            catch (RequestFailedException ex) when (ex.Status == 404) { }

            var aciState = aci?.Data?.InstanceView?.State;
            var exitCode  = aci?.Data?.Containers?.FirstOrDefault()?.InstanceView?.CurrentState?.ExitCode;

            log.LogInformation("Job {jobId}: aciState={state} exitCode={exit} age={age:F1}min",
                jobId, aciState, exitCode, ageMinutes);

            var succeeded = aciState == "Succeeded";
            var failed    = aci == null || timedOut || aciState == "Failed" ||
                            (aciState == "Terminated" && exitCode != 0);

            if (succeeded)
                await HandleSuccess(job, aci!, log);
            else if (failed)
            {
                var reason = aci == null        ? "ACI not found"
                           : timedOut           ? $"timed out after {ageMinutes:F0}min"
                           :                      $"exit code {exitCode}";
                await HandleFailure(job, aci, reason, log);
            }
            else
                log.LogInformation("Job {jobId} still running ({age:F1}min).", jobId, ageMinutes);
        }
    }

    private async Task HandleSuccess(TableEntity job, ContainerGroupResource aci, ILogger log)
    {
        var jobId    = job.RowKey;
        var blobName = $"{jobId}.{job.GetString("extension") ?? "mp4"}";

        try
        {
            var outputBlob = blobService.GetBlobContainerClient("output").GetBlobClient(blobName);
            if (!await outputBlob.ExistsAsync())
                throw new Exception("Output blob missing — curl upload may have failed");

            var outputSize = (await outputBlob.GetPropertiesAsync()).Value.ContentLength;
            if (outputSize == 0) throw new Exception("Output blob is empty");

            var originalName = job.GetString("originalName") ?? blobName;
            await outputBlob.SetHttpHeadersAsync(new BlobHttpHeaders
            {
                ContentDisposition = $"attachment; filename=\"{originalName}\""
            });

            log.LogInformation("Output blob: {size} bytes (original: {orig} bytes)",
                outputSize, job.GetInt64("originalSizeBytes"));

            await aci.DeleteAsync(WaitUntil.Started);
            try { await blobService.GetBlobContainerClient("input").GetBlobClient(blobName).DeleteAsync(); }
            catch { }

            var update = new TableEntity("jobs", jobId)
            {
                ["status"]              = "ready",
                ["outputBlobName"]      = blobName,
                ["compressedSizeBytes"] = outputSize,
                ["completedAt"]         = DateTimeOffset.UtcNow.ToString("o")
            };
            await _table.UpdateEntityAsync(update, ETag.All, TableUpdateMode.Merge);

            log.LogInformation("Job {jobId} complete. Saved {saved:F1} MB.", jobId,
                ((job.GetInt64("originalSizeBytes") ?? 0) - outputSize) / 1_048_576.0);
        }
        catch (Exception ex)
        {
            log.LogError("Job {jobId} output processing failed: {error}", jobId, ex.Message);
        }
    }

    private async Task HandleFailure(TableEntity job, ContainerGroupResource? aci, string reason, ILogger log)
    {
        var jobId    = job.RowKey;
        log.LogWarning("Job {jobId} failed: {reason}", jobId, reason);

        if (aci != null)
        {
            try { await aci.DeleteAsync(WaitUntil.Started); } catch { }
        }

        var blobName = $"{jobId}.{job.GetString("extension") ?? "mp4"}";
        try { await blobService.GetBlobContainerClient("input").GetBlobClient(blobName).DeleteAsync(); }
        catch { }

        var update = new TableEntity("jobs", jobId)
        {
            ["status"]        = "failed",
            ["failedAt"]      = DateTimeOffset.UtcNow.ToString("o"),
            ["failureReason"] = reason
        };
        await _table.UpdateEntityAsync(update, ETag.All, TableUpdateMode.Merge);
    }

    private async Task MarkFailed(TableEntity job, string reason)
    {
        var update = new TableEntity("jobs", job.RowKey)
        {
            ["status"]        = "failed",
            ["failedAt"]      = DateTimeOffset.UtcNow.ToString("o"),
            ["failureReason"] = reason
        };
        await _table.UpdateEntityAsync(update, ETag.All, TableUpdateMode.Merge);
    }
}
