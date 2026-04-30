using Azure.Identity;
using Azure.ResourceManager;
using Azure.Security.KeyVault.Secrets;
using Azure.Storage.Blobs;
using Azure.Data.Tables;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;

var credential = new DefaultAzureCredential();
var saName     = Environment.GetEnvironmentVariable("STORAGE_ACCOUNT_NAME")!;
var kvUrl      = Environment.GetEnvironmentVariable("KEY_VAULT_URL")!;

var host = new HostBuilder()
    .ConfigureFunctionsWebApplication()
    .ConfigureServices(services =>
    {
        services.AddSingleton(credential);
        services.AddSingleton(new BlobServiceClient(
            new Uri($"https://{saName}.blob.core.windows.net"), credential));
        services.AddSingleton(new TableServiceClient(
            new Uri($"https://{saName}.table.core.windows.net"), credential));
        services.AddSingleton(new ArmClient(credential));
        services.AddSingleton(new SecretClient(new Uri(kvUrl), credential));
    })
    .Build();

host.Run();
