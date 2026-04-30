<#
.SYNOPSIS
    Builds and publishes the Cloud Compressor Azure Functions (.NET 8 Isolated Worker).
.DESCRIPTION
    Runs dotnet publish then zip-deploys to the Function App.
    Requires: dotnet CLI, Azure CLI (az).
.PARAMETER FunctionAppName
    Name of the Azure Function App. Reads from config\resource-names.json if not provided.
.PARAMETER ResourceGroupName
    Resource group. Reads from config\resource-names.json if not provided.
#>
param(
    [string]$FunctionAppName,
    [string]$ResourceGroupName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $FunctionAppName -or -not $ResourceGroupName) {
    $configPath = "$PSScriptRoot\..\config\resource-names.json"
    if (-not (Test-Path $configPath)) {
        Write-Error "config\resource-names.json not found. Run Setup-Infrastructure.ps1 first, or provide -FunctionAppName and -ResourceGroupName."
    }
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    if (-not $FunctionAppName)    { $FunctionAppName    = $config.functionAppName }
    if (-not $ResourceGroupName)  { $ResourceGroupName  = $config.resourceGroupName }
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error ".NET SDK not found. Install from https://dot.net"
}
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI not found. Install with: winget install -e --id Microsoft.AzureCLI"
}

$functionsDir = "$PSScriptRoot\..\functions"
$publishDir   = "$PSScriptRoot\..\publish"
$zipPath      = "$PSScriptRoot\..\publish.zip"

Write-Host "Building functions..."
dotnet publish $functionsDir -c Release -o $publishDir --nologo
if ($LASTEXITCODE -ne 0) { Write-Error "dotnet publish failed." }

Write-Host "Creating deployment package..."
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path "$publishDir\*" -DestinationPath $zipPath

Write-Host "Deploying to $FunctionAppName..."
az functionapp deployment source config-zip `
    --resource-group $ResourceGroupName `
    --name $FunctionAppName `
    --src $zipPath
if ($LASTEXITCODE -ne 0) { Write-Error "Deployment failed." }

Remove-Item $zipPath   -Force
Remove-Item $publishDir -Recurse -Force

Write-Host ""
Write-Host "Deployment complete."
Write-Host ""
Write-Host "Retrieve function keys:"
Write-Host "  az functionapp keys list --resource-group $ResourceGroupName --name $FunctionAppName"
