using 'main.bicep'

param location = 'eastus2'
param resourceGroupName = 'rg-keyvault-change-monitor'
param notificationRecipient = 'keyvault-operator@contoso.com'
param monitoredSubscriptionIds = [
  '00000000-0000-0000-0000-000000000000'
]
param tags = {
  solution: 'azure-keyvault-change-monitor'
  environment: 'development'
}
