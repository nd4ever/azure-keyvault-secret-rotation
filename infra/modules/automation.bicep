metadata name = 'Key Vault Change Monitor Automation'
metadata description = 'Creates or reuses an Automation account and provisions the runbook and daily schedule resources.'

targetScope = 'resourceGroup'

@description('Name of the Azure Automation account.')
param automationAccountName string

@description('Azure region used when creating the Azure Automation account.')
param location string

@description('Name of the Key Vault monitoring runbook.')
param runbookName string

@description('UTC start time for the daily schedule.')
param scheduleStartTime string

@description('Name of the daily Automation schedule.')
param scheduleName string

@description('Whether to create an Azure Automation account instead of reusing an existing account.')
param shouldCreateAutomationAccount bool

@description('Tags applied to a newly created Azure Automation account.')
param tags object

resource automationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' existing = {
  name: automationAccountName
}

resource newAutomationAccount 'Microsoft.Automation/automationAccounts@2024-10-23' = if (shouldCreateAutomationAccount) {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    disableLocalAuth: true
    publicNetworkAccess: true
    sku: {
      name: 'Basic'
    }
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2024-10-23' = {
  name: runbookName
  parent: automationAccount
  location: location
  properties: {
    description: 'Scans existing Key Vault secret and certificate metadata and reports changes.'
    draft: {}
    logActivityTrace: 0
    logProgress: true
    logVerbose: false
    runbookType: 'PowerShell72'
  }
  dependsOn: [
    newAutomationAccount
  ]
}

resource dailySchedule 'Microsoft.Automation/automationAccounts/schedules@2024-10-23' = {
  name: scheduleName
  parent: automationAccount
  properties: {
    description: 'Runs the Key Vault change monitor once per day.'
    frequency: 'Day'
    interval: 1
    startTime: scheduleStartTime
    timeZone: 'Etc/UTC'
  }
  dependsOn: [
    newAutomationAccount
  ]
}

@description('Resource ID of the Azure Automation account.')
output automationAccountId string = automationAccount.id

@description('Principal ID of the Automation account system-assigned managed identity.')
output automationPrincipalId string = automationAccount.identity.principalId

@description('Name of the provisioned runbook.')
output runbookName string = runbook.name

@description('Name of the provisioned daily schedule.')
output scheduleName string = dailySchedule.name
