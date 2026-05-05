using Azure.Data.Tables;
using Azure.Storage.Blobs;
using Azure.Storage.Sas;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace CloudCompressor;

public class GetCompletedJobs(BlobServiceClient blobService, TableServiceClient tableService)
{
    private readonly TableClient _table = tableService.GetTableClient("CompressionJobs");
    private readonly string _saName    = Environment.GetEnvironmentVariable("STORAGE_ACCOUNT_NAME")!;

    [Function("Get-CompletedJobs")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequest req)
    {
        var delegationKey = (await blobService.GetUserDelegationKeyAsync(
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddHours(24))).Value;

        var deviceId    = req.Query["deviceId"].ToString();
        var baseFilter  = "PartitionKey eq 'jobs' and status eq 'ready'";
        var deviceFilter = string.IsNullOrEmpty(deviceId)
            ? baseFilter
            : $"{baseFilter} and deviceId eq '{deviceId}'";

        var results = new List<object>();

        // Try device-scoped query first; fall back to all ready jobs if nothing matches.
        // This handles signing-context mismatches (Xcode debug vs AltStore vs App Store)
        // where the same physical device may upload under different deviceIds.
        var jobs = new List<TableEntity>();
        await foreach (var job in _table.QueryAsync<TableEntity>(filter: deviceFilter))
            jobs.Add(job);
        if (jobs.Count == 0 && !string.IsNullOrEmpty(deviceId))
            await foreach (var job in _table.QueryAsync<TableEntity>(filter: baseFilter))
                jobs.Add(job);

        foreach (var job in jobs)
        {
            var blobName   = job.GetString("outputBlobName")!;
            var outputBlob = blobService.GetBlobContainerClient("output").GetBlobClient(blobName);

            var sas = new BlobSasBuilder
            {
                BlobContainerName = "output",
                BlobName          = blobName,
                Resource          = "b",
                ExpiresOn         = DateTimeOffset.UtcNow.AddHours(24)
            };
            sas.SetPermissions(BlobSasPermissions.Read);
            var downloadUrl = new BlobUriBuilder(outputBlob.Uri)
                { Sas = sas.ToSasQueryParameters(delegationKey, _saName) }.ToUri();

            results.Add(new
            {
                jobId               = job.RowKey,
                downloadUrl         = downloadUrl.ToString(),
                photoId             = job.GetString("photoId"),
                localId             = job.GetString("localId"),
                originalName        = job.GetString("originalName"),
                originalSizeBytes   = job.GetInt64("originalSizeBytes") ?? 0L,
                compressedSizeBytes = job.GetInt64("compressedSizeBytes") ?? 0L,
                completedAt         = job.GetString("completedAt")
            });
        }

        return new OkObjectResult(results);
    }
}
