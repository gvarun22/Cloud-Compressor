using System.Text.Json;
using Azure.Data.Tables;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace CloudCompressor;

public class SyncProcessed(TableServiceClient tableService)
{
    private readonly TableClient _table = tableService.GetTableClient("ProcessedHashes");

    // GET /api/Sync-Processed?since=2026-05-11T09:00:00Z
    // Returns all hashes, or only those newer than `since`.
    [Function("Sync-Processed-Get")]
    public async Task<IActionResult> Get(
        [HttpTrigger(AuthorizationLevel.Function, "get", Route = "Sync-Processed")] HttpRequest req)
    {
        await _table.CreateIfNotExistsAsync();

        var sinceStr = req.Query["since"].ToString();
        var filter   = string.IsNullOrEmpty(sinceStr)
            ? "PartitionKey eq 'hashes'"
            : $"PartitionKey eq 'hashes' and processedAt ge '{sinceStr}'";

        var results = new List<object>();
        await foreach (var entity in _table.QueryAsync<TableEntity>(filter: filter))
        {
            results.Add(new
            {
                thumbprint  = entity.RowKey,
                crf         = entity.GetInt32("crf") ?? 0,
                processedAt = entity.GetString("processedAt") ?? "",
                filename    = entity.GetString("filename")
            });
        }
        return new OkObjectResult(results);
    }

    // POST /api/Sync-Processed  body: [{thumbprint, crf, processedAt, filename}]
    // Upserts each entry. Idempotent — safe to call multiple times with the same data.
    [Function("Sync-Processed-Post")]
    public async Task<IActionResult> Post(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "Sync-Processed")] HttpRequest req)
    {
        await _table.CreateIfNotExistsAsync();

        var body    = await new StreamReader(req.Body).ReadToEndAsync();
        var entries = JsonSerializer.Deserialize<List<ProcessedHashDto>>(body,
            new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

        if (entries == null || entries.Count == 0)
            return new BadRequestObjectResult("Empty or invalid body");

        foreach (var entry in entries)
        {
            if (string.IsNullOrEmpty(entry.Thumbprint)) continue;
            var entity = new TableEntity("hashes", entry.Thumbprint)
            {
                ["crf"]         = entry.Crf,
                ["processedAt"] = entry.ProcessedAt ?? DateTimeOffset.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ"),
                ["filename"]    = entry.Filename ?? ""
            };
            await _table.UpsertEntityAsync(entity, TableUpdateMode.Replace);
        }

        return new OkObjectResult(new { upserted = entries.Count });
    }
}

public class ProcessedHashDto
{
    public string  Thumbprint  { get; set; } = "";
    public int     Crf         { get; set; }
    public string? ProcessedAt { get; set; }
    public string? Filename    { get; set; }
}
