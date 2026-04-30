using Azure.Data.Tables;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace CloudCompressor;

public class DownloadJob(BlobServiceClient blobService, TableServiceClient tableService)
{
    private readonly TableClient _table = tableService.GetTableClient("CompressionJobs");

    [Function("Download-Job")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequest req)
    {
        var jobId = req.Query["jobId"].ToString();
        if (string.IsNullOrEmpty(jobId))
            return new BadRequestObjectResult("jobId required");

        TableEntity job;
        try   { job = await _table.GetEntityAsync<TableEntity>("jobs", jobId); }
        catch { return new NotFoundResult(); }

        if (job.GetString("status") != "ready")
            return new NotFoundResult();

        var blobName     = job.GetString("outputBlobName")!;
        var originalName = job.GetString("originalName") ?? blobName;
        var blob         = blobService.GetBlobContainerClient("output").GetBlobClient(blobName);

        if (!await blob.ExistsAsync())
            return new NotFoundResult();

        var props  = await blob.GetPropertiesAsync();
        var stream = await blob.OpenReadAsync();

        req.HttpContext.Response.ContentLength = props.Value.ContentLength;

        return new FileStreamResult(stream, "application/octet-stream")
        {
            FileDownloadName = originalName
        };
    }
}
