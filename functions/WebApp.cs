using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;

namespace CloudCompressor;

public class WebApp
{
    [Function("app")]
    public async Task<ContentResult> Run(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", Route = "app")] HttpRequest req)
    {
        var html = await File.ReadAllTextAsync(
            Path.Combine(AppContext.BaseDirectory, "index.html"));

        return new ContentResult
        {
            Content     = html,
            ContentType = "text/html; charset=utf-8",
            StatusCode  = 200
        };
    }
}
