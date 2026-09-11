metadata name = 'Key Vault Change Monitor Email'
metadata description = 'Creates or reuses Azure Communication Services email and grants the Automation identity sender access.'

targetScope = 'resourceGroup'

@description('Name of the Azure Communication Services resource.')
param communicationServiceName string

@description('Data residency location for newly created Communication Services resources.')
param dataLocation string

@description('Name of the Email Communication Services resource created with a new communication service.')
param emailServiceName string

@description('Sender address configured on an existing Azure Communication Services resource.')
param existingSenderAddress string?

@description('Object ID of the Automation account managed identity.')
param principalId string

@description('Resource ID of the custom communication email sender role.')
param roleDefinitionId string

@description('Whether to create Azure Communication Services email resources instead of reusing an existing resource.')
param shouldCreateCommunicationService bool

@description('Tags applied to newly created Communication Services resources.')
param tags object

resource emailService 'Microsoft.Communication/emailServices@2025-05-01' = if (shouldCreateCommunicationService) {
  name: emailServiceName
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
  }
}

resource emailDomain 'Microsoft.Communication/emailServices/domains@2025-05-01' = if (shouldCreateCommunicationService) {
  name: 'AzureManagedDomain'
  location: 'global'
  parent: emailService
  properties: {
    domainManagement: 'AzureManaged'
    userEngagementTracking: 'Disabled'
  }
}

resource newCommunicationService 'Microsoft.Communication/communicationServices@2025-05-01' = if (shouldCreateCommunicationService) {
  name: communicationServiceName
  location: 'global'
  tags: tags
  properties: {
    dataLocation: dataLocation
    disableLocalAuth: true
    linkedDomains: [
      emailDomain.id
    ]
    publicNetworkAccess: 'Enabled'
  }
}

resource communicationService 'Microsoft.Communication/communicationServices@2025-05-01' existing = {
  name: communicationServiceName
}

resource communicationSenderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(communicationService.id, principalId, roleDefinitionId)
  scope: communicationService
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: roleDefinitionId
  }
  dependsOn: [
    newCommunicationService
  ]
}

@description('Azure Communication Services endpoint used by the runbook.')
output communicationEndpoint string = 'https://${communicationService.properties.hostName}'

@description('Verified sender address used by the runbook.')
output senderAddress string = shouldCreateCommunicationService
  ? 'DoNotReply@${emailDomain!.properties.mailFromSenderDomain}'
  : (existingSenderAddress ?? '')
