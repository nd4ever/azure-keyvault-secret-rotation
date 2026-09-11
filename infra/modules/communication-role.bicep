metadata name = 'Key Vault Change Monitor Communication Role'
metadata description = 'Creates the least-privilege custom role used to send email through Azure Communication Services.'

targetScope = 'subscription'

@description('Name of the custom Azure Communication Services sender role.')
param roleName string

var roleDefinitionGuid = guid(subscription().id, roleName)

resource communicationEmailSenderRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: roleDefinitionGuid
  properties: {
    assignableScopes: [
      subscription().id
    ]
    description: 'Allows a workload identity to authenticate and send through one Azure Communication Services resource.'
    permissions: [
      {
        actions: [
          'Microsoft.Communication/CommunicationServices/Read'
          'Microsoft.Communication/CommunicationServices/Write'
        ]
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
    roleName: roleName
    type: 'CustomRole'
  }
}

@description('Resource ID of the custom Azure Communication Services sender role.')
output roleDefinitionId string = communicationEmailSenderRole.id
