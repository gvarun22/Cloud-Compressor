param location string = 'centralus'
param aciLocation string = 'centralus'
param storageAccountName string
param keyVaultName string
param functionAppName string
param appServicePlanName string = '${functionAppName}-plan'
param containerRegistryName string

// Storage account — blobs (input/output), file share (ACI mount), tables (job state)
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: { enabled: false }
  }
}

resource inputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'input'
  properties: { publicAccess: 'None' }
}

resource outputContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'output'
  properties: { publicAccess: 'None' }
}

// Lifecycle policy: auto-delete output blobs after 7 days (safety net if phone never retrieves)
resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-01-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'delete-stale-output'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'] }
            actions: {
              baseBlob: {
                delete: { daysAfterCreationGreaterThan: 7 }
              }
            }
          }
        }
      ]
    }
  }
  // Only apply lifecycle to output container via Bicep limitation workaround — see note below
  // Azure lifecycle policies filter by prefix, not container. The prefix 'output/' is not valid
  // for container-scoped blobs. The 7-day policy above applies to ALL blobs as a safety net.
  // Input blobs are deleted within minutes by the functions; this policy is a backstop only.
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource fileShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-01-01' = {
  parent: fileService
  name: 'compress-share'
  properties: { shareQuota: 100 }
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource jobsTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-01-01' = {
  parent: tableService
  name: 'CompressionJobs'
}

// Container Registry — hosts ffmpeg image to avoid Docker Hub rate limits on Azure IPs
resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: containerRegistryName
  location: location
  sku: { name: 'Basic' }
  properties: {
    adminUserEnabled: true
  }
}

// Key Vault — RBAC model, holds storage-account-key for ACI volume mount
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// Consumption plan (serverless, no idle cost)
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: appServicePlanName
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: {}
}

// Function App — PowerShell 7.4, system-assigned Managed Identity
resource functionApp 'Microsoft.Web/sites@2023-01-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'dotnet-isolated' }
        { name: 'WEBSITE_USE_PLACEHOLDER_DOTNETISOLATED', value: '1' }
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net' }
        { name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', value: 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=core.windows.net' }
        { name: 'WEBSITE_CONTENTSHARE', value: toLower(functionAppName) }
        { name: 'WEBSITE_RUN_FROM_PACKAGE', value: '1' }
        { name: 'STORAGE_ACCOUNT_NAME', value: storageAccount.name }
        { name: 'KEY_VAULT_URL', value: keyVault.properties.vaultUri }
        { name: 'RESOURCE_GROUP_NAME', value: resourceGroup().name }
        { name: 'ACI_LOCATION', value: aciLocation }
        { name: 'ACI_SUBSCRIPTION_ID', value: subscription().subscriptionId }
        { name: 'ACR_LOGIN_SERVER', value: containerRegistry.properties.loginServer }
        // Identity-based connection for the EventGrid blob trigger (connection strings not supported with source:EventGrid)
        { name: 'InputStorage__accountName', value: storageAccount.name }
        { name: 'InputStorage__credential', value: 'managedidentity' }
      ]
    }
    httpsOnly: true
  }
}

output functionAppName string = functionApp.name
output functionAppPrincipalId string = functionApp.identity.principalId
output storageAccountName string = storageAccount.name
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output containerRegistryName string = containerRegistry.name
output containerRegistryLoginServer string = containerRegistry.properties.loginServer
