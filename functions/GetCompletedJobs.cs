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

        var results = new List<object>();

        await foreach (var job in _table.QueryAsync<TableEntity>(
            filter: "PartitionKey eq 'jobs' and status eq 'ready'"))
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
