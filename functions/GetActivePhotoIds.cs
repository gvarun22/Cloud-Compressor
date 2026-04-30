using Azure.Data.Tables;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace CloudCompressor;

public class GetActivePhotoIds(TableServiceClient tableService)
{
    private readonly TableClient _table = tableService.GetTableClient("CompressionJobs");

    [Function("Get-ActivePhotoIds")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequest req)
    {
        var photoIds = new List<string>();

        // Return photoIds for every job that is not yet done — these act as distributed locks.
        // A content hash in this set means: don't re-upload, a job is already in flight or ready.
        await foreach (var job in _table.QueryAsync<TableEntity>(
            filter: "PartitionKey eq 'jobs' and " +
                    "(status eq 'pending' or status eq 'submitted' or " +
                    " status eq 'processing' or status eq 'ready')"))
        {
            var photoId = job.GetString("photoId");
            if (!string.IsNullOrEmpty(photoId))
                photoIds.Add(photoId);
        }

        return new OkObjectResult(photoIds);
    }
}
