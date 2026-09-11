metadata name = 'Azure Key Vault Change Monitor'
metadata description = 'Deploys scheduled monitoring and email notifications for changes to existing Azure Key Vault resources.'

targetScope = 'subscription'

@description('Name used when creating an Azure Automation account. (Ignored when an existing account is provided.)')
param automationAccountName string = take('aa-kv-change-${uniqueString(subscription().id, resourceGroupName)}', 50)

@description('Data residency location for newly created Azure Communication Services resources.')
param communicationDataLocation string = 'United States'

@description('Name used when creating Azure Communication Services. (Ignored when an existing resource is provided.)')
param communicationServiceName string = take('acs-kv-change-${uniqueString(subscription().id, resourceGroupName)}', 63)

@description('Name used when creating Email Communication Services.')
param emailServiceName string = take('ecs-kv-change-${uniqueString(subscription().id, resourceGroupName)}', 63)

@description('Name of an existing Azure Automation account. (When null, a new account is created.)')
param existingAutomationAccountName string?

@description('Azure region of an existing Azure Automation account. (Required with an existing account name.)')
param existingAutomationAccountLocation string?

@description('Resource group of an existing Azure Automation account. (Required with an existing account name.)')
param existingAutomationAccountResourceGroupName string?

@description('Subscription ID of an existing Azure Automation account. (Defaults to the deployment subscription.)')
param existingAutomationAccountSubscriptionId string?

@description('Name of an existing Azure Communication Services resource. (When null, new email resources are created.)')
param existingCommunicationServiceName string?

@description('Resource group of an existing Azure Communication Services resource. (Required with an existing resource name.)')
param existingCommunicationServiceResourceGroupName string?

@description('Verified sender address for an existing Azure Communication Services resource. (Required with an existing resource name.)')
param existingCommunicationServiceSenderAddress string?

@description('Subscription ID of an existing Azure Communication Services resource. (Defaults to the deployment subscription.)')
param existingCommunicationServiceSubscriptionId string?

@description('Azure region for solution resources.')
param location string

@description('Location of the solution resource group. (Must match an existing resource group location.)')
param resourceGroupLocation string = location

@description('Subscription IDs whose existing Key Vault resources are monitored.')
param monitoredSubscriptionIds array = [
  subscription().subscriptionId
]

@description('UPN or email address that receives Key Vault change notifications.')
param notificationRecipient string

@description('Name of the resource group created for solution-owned resources.')
param resourceGroupName string

@description('UTC start time for the daily Automation schedule.')
param scheduleStartTime string = dateTimeAdd(utcNow(), 'PT15M')

@description('Name of the blob that stores the previous Key Vault metadata snapshot.')
param stateBlobName string = 'key-vault-state.json'

@description('Name of the blob container that stores monitor state.')
param stateContainerName string = 'monitor-state'

@description('Globally unique name of the monitor state storage account.')
param stateStorageAccountName string = take('stkvchg${uniqueString(subscription().id, resourceGroupName)}', 24)

@description('Tags applied to solution resources.')
param tags object = {}

@description('Optional tags merged only into the state storage account (for example, an SFI public-network-access policy exemption). Left empty by default so environment-specific values stay out of source control.')
param stateStoragePolicyExemptionTags object = {}

var automationResourceGroupName = existingAutomationAccountResourceGroupName ?? resourceGroupName
var automationSubscriptionId = existingAutomationAccountSubscriptionId ?? subscription().subscriptionId
var resolvedAutomationAccountLocation = existingAutomationAccountLocation ?? location
var communicationResourceGroupName = existingCommunicationServiceResourceGroupName ?? resourceGroupName
var communicationSubscriptionId = existingCommunicationServiceSubscriptionId ?? subscription().subscriptionId
var resolvedAutomationAccountName = existingAutomationAccountName ?? automationAccountName
var resolvedCommunicationServiceName = existingCommunicationServiceName ?? communicationServiceName
var runbookName = 'Watch-KeyVaultChanges'
var scheduleName = 'Daily-KeyVault-Change-Scan'
var shouldCreateAutomationAccount = existingAutomationAccountName == null
var shouldCreateCommunicationService = existingCommunicationServiceName == null

resource resourceGroupResource 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: resourceGroupLocation
  tags: tags
}

module automation 'modules/automation.bicep' = {
  scope: resourceGroup(automationSubscriptionId, automationResourceGroupName)
  params: {
    automationAccountName: resolvedAutomationAccountName
    location: resolvedAutomationAccountLocation
    runbookName: runbookName
    scheduleName: scheduleName
    scheduleStartTime: scheduleStartTime
    shouldCreateAutomationAccount: shouldCreateAutomationAccount
    tags: tags
  }
  dependsOn: [
    resourceGroupResource
  ]
}

module stateStorage 'modules/state-storage.bicep' = {
  scope: resourceGroupResource
  params: {
    location: location
    automationAccountResourceId: automation.outputs.automationAccountId
    automationTenantId: tenant().tenantId
    principalId: automation.outputs.automationPrincipalId
    stateContainerName: stateContainerName
    storageAccountName: stateStorageAccountName
    tags: union(tags, stateStoragePolicyExemptionTags)
  }
}

module communicationRole 'modules/communication-role.bicep' = {
  scope: subscription(communicationSubscriptionId)
  params: {
    roleName: 'Key Vault Change Monitor Communication Sender'
  }
}

module communication 'modules/communication.bicep' = {
  scope: resourceGroup(communicationSubscriptionId, communicationResourceGroupName)
  params: {
    communicationServiceName: resolvedCommunicationServiceName
    dataLocation: communicationDataLocation
    emailServiceName: emailServiceName
    existingSenderAddress: existingCommunicationServiceSenderAddress
    principalId: automation.outputs.automationPrincipalId
    roleDefinitionId: communicationRole.outputs.roleDefinitionId
    shouldCreateCommunicationService: shouldCreateCommunicationService
    tags: tags
  }
  dependsOn: [
    resourceGroupResource
  ]
}

@description('Deployment values consumed when publishing and scheduling the runbook.')
output automationConfiguration object = {
  accountName: resolvedAutomationAccountName
  accountResourceGroupName: automationResourceGroupName
  accountSubscriptionId: automationSubscriptionId
  communicationEndpoint: communication.outputs.communicationEndpoint
  monitoredSubscriptionIdsJson: string(monitoredSubscriptionIds)
  notificationRecipient: notificationRecipient
  runbookName: runbookName
  scheduleName: scheduleName
  senderAddress: communication.outputs.senderAddress
  stateBlobName: stateBlobName
  stateContainerName: stateStorage.outputs.stateContainerName
  storageAccountName: stateStorage.outputs.storageAccountName
}

@description('Principal ID of the Automation account managed identity.')
output automationPrincipalId string = automation.outputs.automationPrincipalId

@description('Resource ID of the deployed resource group.')
output resourceGroupId string = resourceGroupResource.id
