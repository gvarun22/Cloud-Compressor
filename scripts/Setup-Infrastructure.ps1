<#
.SYNOPSIS
    One-time Azure infrastructure setup for the Cloud Compressor pipeline.
.DESCRIPTION
    Deploys Bicep template, assigns RBAC roles to the Function App managed identity,
    and stores the storage account key in Key Vault.
.PARAMETER SubscriptionId
    Azure subscription ID to deploy into.
.PARAMETER Location
    Azure region. Defaults to centralus. Must match across all resources.
.PARAMETER StorageAccountName
    Globally unique storage account name (3-24 chars, lowercase alphanumeric).
.PARAMETER KeyVaultName
    Globally unique Key Vault name (3-24 chars).
.PARAMETER FunctionAppName
    Globally unique Function App name.
.PARAMETER ResourceGroupName
    Resource group name. Created if it does not exist.
.PARAMETER TenantId
    Optional. Specify to avoid warnings when your account spans multiple tenants.
.PARAMETER Force
    Overwrite existing config/resource-names.json if present.
#>
param(
    [Parameter(Mandatory)][string]$SubscriptionId,
    [string]$TenantId                = '',
    [string]$Location                = 'centralus',
    [string]$ResourceGroupName       = 'rg-cloud-compressor',
    [string]$StorageAccountName      = 'stcloudcompress',
    [string]$KeyVaultName            = 'kv-cloudcompress',
    [string]$FunctionAppName         = 'func-cloudcompress',
    [string]$ContainerRegistryName   = 'acrcloudcompress',
    [string]$CurrentUserOid          = '',   # Override if auto-detection fails (OID visible in KV Forbidden errors)
    [switch]$Force,
    [switch]$SkipLogin                       # Skip Connect-AzAccount if already authenticated
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Pre-flight: Az module required
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az PowerShell module not found. Install it with:`n  Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force"
}

# Pre-flight: Bicep CLI required
if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    Write-Error "Bicep CLI not found. Install it with:`n  winget install -e --id Microsoft.Bicep`nor:`n  az bicep install"
}

# Pre-flight: Azure CLI required (for az acr import)
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI not found. Install it with:`n  winget install -e --id Microsoft.AzureCLI"
}

$configPath = "$PSScriptRoot\..\config\resource-names.json"

if ((Test-Path $configPath) -and -not $Force) {
    Write-Error "config\resource-names.json already exists. Use -Force to overwrite."
}

# --- Auth ---
if ($SkipLogin) {
    Write-Host "Skipping login (using existing Az context)..."
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
} else {
    Write-Host "Connecting to Azure subscription $SubscriptionId..."
    $connectParams = @{ ErrorAction = 'Stop' }
    if ($TenantId) { $connectParams.TenantId = $TenantId }
    Connect-AzAccount @connectParams | Out-Null
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
}

# --- Resource group ---
Write-Host "Ensuring resource group '$ResourceGroupName'..."
New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force | Out-Null

# --- Bicep deployment ---
Write-Host "Deploying Bicep template..."
$principalId = $null
$saName      = $null
$kvName      = $null

try {
    $deploy = New-AzResourceGroupDeployment `
        -ResourceGroupName $ResourceGroupName `
        -TemplateFile "$PSScriptRoot\..\infra\main.bicep" `
        -storageAccountName $StorageAccountName `
        -keyVaultName $KeyVaultName `
        -functionAppName $FunctionAppName `
        -containerRegistryName $ContainerRegistryName `
        -location $Location `
        -Mode Incremental `
        -ErrorAction Stop

    $principalId = $deploy.Outputs.functionAppPrincipalId.Value
    $saName      = $deploy.Outputs.storageAccountName.Value
    $kvName      = $deploy.Outputs.keyVaultName.Value
    $acrName     = $deploy.Outputs.containerRegistryName.Value
} catch {
    Write-Warning "New-AzResourceGroupDeployment threw an error: $_"
    Write-Warning "Checking whether resources already exist and continuing..."
    $principalId = (Get-AzWebApp -ResourceGroupName $ResourceGroupName -Name $FunctionAppName -ErrorAction SilentlyContinue).Identity.PrincipalId
    $saName      = $StorageAccountName
    $kvName      = $KeyVaultName
    $acrName     = $ContainerRegistryName
}

if (-not $principalId) {
    Write-Error "Could not determine Function App managed identity principal ID. Ensure the Bicep deployment completed successfully in the portal before re-running."
}

Write-Host "Function App MI principal ID: $principalId"

# --- RBAC role assignments ---
$storageId = (Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $saName).Id
$kvId      = (Get-AzKeyVault -ResourceGroupName $ResourceGroupName -VaultName $kvName).ResourceId
$rgId      = (Get-AzResourceGroup -Name $ResourceGroupName).ResourceId

# Function App MI assignments
$assignments = @(
    @{ RoleDefinitionName = 'Storage Blob Data Contributor';              Scope = $storageId }
    @{ RoleDefinitionName = 'Storage Blob Delegator';                     Scope = $storageId }
    @{ RoleDefinitionName = 'Storage Table Data Contributor';             Scope = $storageId }
    @{ RoleDefinitionName = 'Key Vault Secrets User';                     Scope = $kvId      }
    @{ RoleDefinitionName = 'Contributor';                                Scope = $rgId      }
)

foreach ($a in $assignments) {
    $existing = Get-AzRoleAssignment -ObjectId $principalId `
        -RoleDefinitionName $a.RoleDefinitionName -Scope $a.Scope -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host "  [exists] $($a.RoleDefinitionName)"
    } else {
        New-AzRoleAssignment -ObjectId $principalId `
            -RoleDefinitionName $a.RoleDefinitionName -Scope $a.Scope | Out-Null
        Write-Host "  [assigned] $($a.RoleDefinitionName)"
    }
}

# Current user needs Key Vault Secrets Officer to write the storage key secret during setup.
# Extract OID from the JWT access token — works cross-tenant where Get-AzADUser may fail.
$currentUserOid = $null
if ($CurrentUserOid) {
    $currentUserOid = $CurrentUserOid
    Write-Host "Current user OID (provided): $currentUserOid"
} else {
    try {
        $tokenObj = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
        $rawToken = $tokenObj.Token
        if ($rawToken -is [System.Security.SecureString]) {
            $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($rawToken)
            try   { $rawToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr) }
            finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
        }
        $payload = $rawToken.Split('.')[1]
        $payload += '=' * ((4 - $payload.Length % 4) % 4)   # pad base64
        $claims  = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($payload)) | ConvertFrom-Json
        $currentUserOid = $claims.oid
        Write-Host "Current user OID: $currentUserOid"
    } catch {
        Write-Warning "Could not extract OID from token: $_"
    }
}

if ($currentUserOid) {
    $existingOfficer = Get-AzRoleAssignment -ObjectId $currentUserOid `
        -RoleDefinitionName 'Key Vault Secrets Officer' -Scope $kvId -ErrorAction SilentlyContinue
    if (-not $existingOfficer) {
        New-AzRoleAssignment -ObjectId $currentUserOid `
            -RoleDefinitionName 'Key Vault Secrets Officer' -Scope $kvId | Out-Null
        Write-Host "  [assigned] Key Vault Secrets Officer (current user)"
    } else {
        Write-Host "  [exists] Key Vault Secrets Officer (current user)"
    }
} else {
    Write-Warning "Could not resolve current user OID. Manually assign 'Key Vault Secrets Officer' on $kvName to your account, then re-run with -Force."
}

Write-Host "Waiting 30s for role assignment propagation..."
Start-Sleep -Seconds 30

# Verify storage blob role is visible
$check = Get-AzRoleAssignment -ObjectId $principalId `
    -RoleDefinitionName 'Storage Blob Data Contributor' -Scope $storageId -ErrorAction SilentlyContinue
if (-not $check) {
    Write-Warning "Storage Blob Data Contributor assignment not yet visible. If functions fail, wait a few minutes and retry."
}

# --- Store storage account key in Key Vault (needed for ACI volume mount) ---
Write-Host "Storing storage account key in Key Vault..."
$storageKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $saName)[0].Value
$secret = ConvertTo-SecureString $storageKey -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $kvName -Name 'storage-account-key' -SecretValue $secret | Out-Null
Write-Host "  Key stored as secret 'storage-account-key'"

# --- Import ffmpeg image into ACR (bypasses Docker Hub rate limits on Azure IPs) ---
Write-Host "Importing ffmpeg image into ACR '$acrName'..."
az acr import `
    --name $acrName `
    --source docker.io/jrottenberg/ffmpeg:4.4-alpine `
    --image ffmpeg:4.4-alpine `
    --force 2>&1 | Write-Host
if ($LASTEXITCODE -ne 0) {
    Write-Error "az acr import failed with exit code $LASTEXITCODE"
}
Write-Host "  Image imported: $acrName.azurecr.io/ffmpeg:4.4-alpine"

# --- Store ACR admin credentials in Key Vault (needed for ACI image pull) ---
Write-Host "Storing ACR credentials in Key Vault..."
$acrCreds = az acr credential show --name $acrName | ConvertFrom-Json
$acrUsername = $acrCreds.username
$acrPassword = $acrCreds.passwords[0].value

Set-AzKeyVaultSecret -VaultName $kvName -Name 'acr-username' `
    -SecretValue (ConvertTo-SecureString $acrUsername -AsPlainText -Force) | Out-Null
Set-AzKeyVaultSecret -VaultName $kvName -Name 'acr-password' `
    -SecretValue (ConvertTo-SecureString $acrPassword -AsPlainText -Force) | Out-Null
Write-Host "  ACR credentials stored as secrets 'acr-username' and 'acr-password'"

# --- Write config file ---
$configDir = Split-Path $configPath
if (-not (Test-Path $configDir)) { New-Item $configDir -ItemType Directory | Out-Null }

@{
    subscriptionId         = $SubscriptionId
    resourceGroupName      = $ResourceGroupName
    storageAccountName     = $saName
    keyVaultName           = $kvName
    functionAppName        = $FunctionAppName
    containerRegistryName  = $acrName
    location               = $Location
} | ConvertTo-Json | Set-Content $configPath -Encoding UTF8

Write-Host ""
Write-Host "Setup complete. Resource names written to config\resource-names.json"
Write-Host ""
Write-Host "Next step: deploy functions with scripts\Deploy-Functions.ps1"
Write-Host "Then retrieve function keys from portal and configure iOS Shortcuts."
