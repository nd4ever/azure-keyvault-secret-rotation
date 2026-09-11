metadata name = 'Key Vault Change Monitor State Storage'
metadata description = 'Deploys private blob state storage and grants the Automation identity data access.'

targetScope = 'resourceGroup'

@description('Azure region for the storage account.')
param location string

@description('Resource ID of the Automation account permitted through the storage firewall.')
param automationAccountResourceId string

@description('Tenant ID of the Automation account resource instance rule.')
param automationTenantId string

@description('Object ID of the Automation account managed identity.')
param principalId string

@description('Name of the blob container that stores monitor state.')
param stateContainerName string

@description('Globally unique name of the state storage account.')
param storageAccountName string

@description('Tags applied to state storage resources.')
param tags object

var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
      resourceAccessRules: [
        {
          resourceId: automationAccountResourceId
          tenantId: automationTenantId
        }
      ]
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  name: 'default'
  parent: storageAccount
  properties: {
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 7
    }
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  name: stateContainerName
  parent: blobService
  properties: {
    publicAccess: 'None'
  }
}

resource blobDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, principalId, storageBlobDataContributorRoleId)
  scope: storageAccount
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: storageBlobDataContributorRoleId
  }
}

@description('Blob service endpoint used by the runbook.')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob

@description('Name of the state blob container.')
output stateContainerName string = stateContainer.name

@description('Name of the state storage account.')
output storageAccountName string = storageAccount.name
