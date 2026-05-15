using System.Net;
using Azure;
using Azure.Data.Tables;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace CloudCompressor;

public class AcknowledgeJob(BlobServiceClient blobService, TableServiceClient tableService)
{
    private readonly TableClient _table = tableService.GetTableClient("CompressionJobs");

    [Function("Acknowledge-Job")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequest req)
    {
        var jobId = req.Query["jobId"].ToString();
        if (string.IsNullOrEmpty(jobId))
            return new BadRequestObjectResult("Required query param: jobId");

        TableEntity job;
        try { job = (await _table.GetEntityAsync<TableEntity>("jobs", jobId)).Value; }
        catch (RequestFailedException ex) when (ex.Status == 404)
        { return new NotFoundObjectResult($"Job {jobId} not found"); }

        var status = job.GetString("status");
        if (status == "retrieved")
            return new OkObjectResult($"Job {jobId} already acknowledged");
        if (status != "ready" && status != "failed" && status != "no_gain" && status != "permanent_failure")
            return new ObjectResult($"Job {jobId} is in status '{status}', expected ready/failed/no_gain/permanent_failure")
                { StatusCode = (int)HttpStatusCode.Conflict };

        // Only 'ready' jobs have an output blob to clean up; failed/no_gain/permanent_failure
        // already had their input + output blobs deleted by Collect-Jobs.
        var outputBlobName = job.GetString("outputBlobName");
        if (status == "ready" && !string.IsNullOrEmpty(outputBlobName))
        {
            try { await blobService.GetBlobContainerClient("output")
                    .GetBlobClient(outputBlobName).DeleteAsync(); }
            catch { }
        }

        var update = new TableEntity("jobs", jobId)
        {
            ["status"]      = "retrieved",
            ["retrievedAt"] = DateTimeOffset.UtcNow.ToString("o")
        };
        await _table.UpdateEntityAsync(update, ETag.All, TableUpdateMode.Merge);

        return new OkObjectResult($"Job {jobId} acknowledged");
    }
}
