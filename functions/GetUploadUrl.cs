using System.Net;
using System.Security.Cryptography;
using Azure.Data.Tables;
using Azure.Storage.Blobs;
using Azure.Storage.Sas;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace CloudCompressor;

public class GetUploadUrl(BlobServiceClient blobService, TableServiceClient tableService)
{
    private static readonly string[] AllowedExtensions = ["mp4", "mov", "avi", "m4v"];
    private readonly TableClient _table = tableService.GetTableClient("CompressionJobs");
    private readonly string _saName = Environment.GetEnvironmentVariable("STORAGE_ACCOUNT_NAME")!;

    [Function("Get-UploadUrl")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "get")] HttpRequest req)
    {
        var filename = req.Query["filename"].ToString();
        var photoId  = req.Query["photoId"].ToString();

        if (string.IsNullOrEmpty(filename))
            return new BadRequestObjectResult("Required query param: filename");

        var ext = Path.GetExtension(filename).TrimStart('.').ToLower();
        if (!AllowedExtensions.Contains(ext))
            return new BadRequestObjectResult($"Unsupported extension: {ext}");

        var jobId    = Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLower();
        var blobName = $"{jobId}.{ext}";

        var delegationKey = (await blobService.GetUserDelegationKeyAsync(
            DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddHours(2))).Value;

        var sasBuilder = new BlobSasBuilder
        {
            BlobContainerName = "input",
            BlobName          = blobName,
            Resource          = "b",
            ExpiresOn         = DateTimeOffset.UtcNow.AddHours(2)
        };
        sasBuilder.SetPermissions(BlobSasPermissions.Create | BlobSasPermissions.Write);

        var uploadUri = new BlobUriBuilder(
            new Uri($"https://{_saName}.blob.core.windows.net/input/{blobName}"))
        {
            Sas = sasBuilder.ToSasQueryParameters(delegationKey, _saName)
        }.ToUri();

        await _table.CreateIfNotExistsAsync();
        await _table.AddEntityAsync(new TableEntity("jobs", jobId)
        {
            ["status"]            = "pending",
            ["originalName"]      = filename,
            ["extension"]         = ext,
            ["photoId"]           = photoId,
            ["startedAt"]         = DateTimeOffset.UtcNow.ToString("o"),
            ["originalSizeBytes"] = 0L
        });

        return new OkObjectResult(new { uploadUrl = uploadUri.ToString(), jobId });
    }
}
