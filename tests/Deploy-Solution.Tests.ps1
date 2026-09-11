#Requires -Modules Pester
#Requires -Version 7.2

BeforeAll {
    . (Join-Path $PSScriptRoot '../scripts/Deploy-Solution.ps1')

    $script:AutomationConfiguration = [pscustomobject]@{
        accountName                     = 'aa-monitor'
        accountResourceGroupName        = 'rg-automation'
        accountSubscriptionId           = '11111111-1111-1111-1111-111111111111'
        communicationEndpoint           = 'https://acs-monitor.communication.azure.com'
        monitoredSubscriptionIdsJson    = '["22222222-2222-2222-2222-222222222222"]'
        notificationRecipient           = 'operator@contoso.com'
        runbookName                      = 'Watch-KeyVaultChanges'
        scheduleName                     = 'Daily-KeyVault-Change-Scan'
        senderAddress                    = 'DoNotReply@contoso.azurecomm.net'
        stateBlobName                    = 'key-vault-state.json'
        stateContainerName               = 'monitor-state'
        storageAccountName               = 'stmonitor'
    }
}

Describe 'ConvertTo-DeploymentParameterDocument' -Tag 'Unit' {
    It 'Preserves array values and omits null or blank optional values' {
        $Document = ConvertTo-DeploymentParameterDocument -Values ([ordered]@{
            location                         = 'eastus2'
            monitoredSubscriptionIds         = @('sub-one', 'sub-two')
            existingAutomationAccountName    = $null
            existingCommunicationServiceName = ''
        })

        $Document.parameters.location.value | Should -BeExactly 'eastus2'
        $Document.parameters.monitoredSubscriptionIds.value | Should -Be @('sub-one', 'sub-two')
        $Document.parameters.Contains('existingAutomationAccountName') | Should -BeFalse
        $Document.parameters.Contains('existingCommunicationServiceName') | Should -BeFalse
    }
}

Describe 'Get-EnabledTenantSubscription' -Tag 'Unit' {
    It 'Returns only enabled subscriptions from the deployment tenant' {
        $Subscriptions = @(
            [pscustomobject]@{ id = 'enabled-current'; state = 'Enabled'; tenantId = 'tenant-one' }
            [pscustomobject]@{ id = 'disabled-current'; state = 'Disabled'; tenantId = 'tenant-one' }
            [pscustomobject]@{ id = 'enabled-other'; state = 'Enabled'; tenantId = 'tenant-two' }
        )

        $Result = @(Get-EnabledTenantSubscription `
            -Subscriptions $Subscriptions `
            -TenantId 'tenant-one')

        $Result | Should -HaveCount 1
        $Result[0].id | Should -BeExactly 'enabled-current'
    }
}

Describe 'Publish-AutomationRunbook' -Tag 'Unit' {
    BeforeEach {
        $script:AzureCliCalls = @()
        Mock Invoke-AzureCli {
            $script:AzureCliCalls += , @($Arguments)
            return ''
        }
        Mock Wait-AutomationRunbook {}
    }

    It 'Replaces draft content and publishes through the stable Automation API' {
        $RunbookPath = 'C:\temp\Watch-KeyVaultChanges.ps1'

        Publish-AutomationRunbook `
            -Configuration $script:AutomationConfiguration `
            -RunbookPath $RunbookPath

        $script:AzureCliCalls | Should -HaveCount 2
        $DraftUrlIndex = [Array]::IndexOf($script:AzureCliCalls[0], '--url')
        $BodyIndex = [Array]::IndexOf($script:AzureCliCalls[0], '--body')
        $PublishUrlIndex = [Array]::IndexOf($script:AzureCliCalls[1], '--url')
        $ExpectedRunbookUrl = 'https://management.azure.com/subscriptions/' +
            '11111111-1111-1111-1111-111111111111/resourceGroups/rg-automation/' +
            'providers/Microsoft.Automation/automationAccounts/aa-monitor/runbooks/Watch-KeyVaultChanges'

        $script:AzureCliCalls[0][$DraftUrlIndex + 1] |
            Should -BeExactly "$ExpectedRunbookUrl/draft/content?api-version=2024-10-23"
        $script:AzureCliCalls[0][$BodyIndex + 1] | Should -BeExactly "@$RunbookPath"
        $script:AzureCliCalls[1][$PublishUrlIndex + 1] |
            Should -BeExactly "$ExpectedRunbookUrl/publish?api-version=2024-10-23"
        Should -Invoke Wait-AutomationRunbook -Times 1 -Exactly -ParameterFilter {
            $State -eq 'DraftReady'
        }
        Should -Invoke Wait-AutomationRunbook -Times 1 -Exactly -ParameterFilter {
            $State -eq 'Published'
        }
    }
}

Describe 'Set-LegacyKeyVaultAccessPolicy' -Tag 'Unit' {
    BeforeEach {
        $script:AzureCliCalls = @()
        Mock Invoke-AzureCliJson {
            if ($Arguments -contains 'list') {
                return @(
                    [pscustomobject]@{ name = 'rbac-vault' }
                    [pscustomobject]@{ name = 'legacy-vault' }
                )
            }

            $NameIndex = [Array]::IndexOf([object[]]$Arguments, '--name')
            $VaultName = $Arguments[$NameIndex + 1]
            if ($VaultName -eq 'rbac-vault') {
                return [pscustomobject]@{
                    id            = '/subscriptions/sub-one/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/rbac-vault'
                    name          = 'rbac-vault'
                    resourceGroup = 'rg'
                    properties    = [pscustomobject]@{
                        accessPolicies          = @()
                        enableRbacAuthorization = $true
                    }
                }
            }

            return [pscustomobject]@{
                id            = '/subscriptions/sub-one/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/legacy-vault'
                name          = 'legacy-vault'
                resourceGroup = 'rg'
                properties    = [pscustomobject]@{
                    enableRbacAuthorization = $false
                    accessPolicies          = @(
                        [pscustomobject]@{
                            objectId    = 'principal-one'
                            permissions = [pscustomobject]@{
                                certificates = @('get')
                                keys         = @('get')
                                secrets      = @('get')
                                storage      = @()
                            }
                        }
                    )
                }
            }
        }
        Mock Invoke-AzureCli {
            $script:AzureCliCalls += , @($Arguments)
            return ''
        }
    }

    It 'Adds list access only to legacy vaults and preserves existing permissions' {
        Set-LegacyKeyVaultAccessPolicy `
            -PrincipalId 'principal-one' `
            -SubscriptionIds 'sub-one' `
            -Confirm:$false

        $script:AzureCliCalls | Should -HaveCount 1
        $Call = $script:AzureCliCalls[0]
        $Call | Should -Contain 'legacy-vault'
        $Call | Should -Not -Contain 'rbac-vault'
        $Call | Should -Contain '--key-permissions'
        $Call | Should -Contain '--secret-permissions'
        $Call | Should -Contain '--certificate-permissions'
        $Call | Should -Contain 'get'
        $Call | Should -Contain 'list'
    }

    It 'Tolerates a vault that rejects policies for RBAC authorization' {
        Mock Invoke-AzureCli {
            throw "Azure CLI command failed: Cannot set policies to a vault with '--enable-rbac-authorization' specified"
        }

        { Set-LegacyKeyVaultAccessPolicy `
                -PrincipalId 'principal-one' `
                -SubscriptionIds 'sub-one' `
                -Confirm:$false } | Should -Not -Throw
    }
}

Describe 'Set-MonitoredSubscriptionAccess' -Tag 'Unit' {
    BeforeEach {
        $script:AzureCliCalls = @()
        Mock Invoke-AzureCliJson { return @() }
        Mock Invoke-AzureCli {
            $script:AzureCliCalls += , @($Arguments)
            return ''
        }
    }

    It 'Grants Reader and Key Vault Reader on each subscription when missing' {
        Set-MonitoredSubscriptionAccess `
            -PrincipalId 'principal-one' `
            -SubscriptionIds @('sub-one', 'sub-two') `
            -Confirm:$false

        $script:AzureCliCalls | Should -HaveCount 4
        foreach ($Call in $script:AzureCliCalls) {
            $Call | Should -Contain 'role'
            $Call | Should -Contain 'assignment'
            $Call | Should -Contain 'create'
            $Call | Should -Contain 'principal-one'
        }
        $Scopes = $script:AzureCliCalls | ForEach-Object {
            $_[[Array]::IndexOf($_, '--scope') + 1]
        }
        $Scopes | Should -Contain '/subscriptions/sub-one'
        $Scopes | Should -Contain '/subscriptions/sub-two'
        $Roles = $script:AzureCliCalls | ForEach-Object {
            $_[[Array]::IndexOf($_, '--role') + 1]
        }
        $Roles | Should -Contain 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
        $Roles | Should -Contain '21090545-7ca7-4776-b22c-e363652d74d2'
    }

    It 'Skips role assignments that already exist' {
        Mock Invoke-AzureCliJson {
            return @(
                '/subscriptions/sub-one/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'
                '/subscriptions/sub-one/providers/Microsoft.Authorization/roleDefinitions/21090545-7ca7-4776-b22c-e363652d74d2'
            )
        }

        Set-MonitoredSubscriptionAccess `
            -PrincipalId 'principal-one' `
            -SubscriptionIds @('sub-one') `
            -Confirm:$false

        $script:AzureCliCalls | Should -HaveCount 0
    }

    It 'Tolerates an existing assignment reported during create' {
        Mock Invoke-AzureCli {
            throw 'Azure CLI command failed: ... (RoleAssignmentExists) The role assignment already exists.'
        }

        { Set-MonitoredSubscriptionAccess `
                -PrincipalId 'principal-one' `
                -SubscriptionIds @('sub-one') `
                -Confirm:$false } | Should -Not -Throw
    }
}

Describe 'Set-AutomationJobSchedule' -Tag 'Unit' {
    BeforeEach {
        $script:AzureCliCalls = @()
        Mock Get-AzureRestCollection {
            return @(
                [pscustomobject]@{
                    id         = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-automation/providers/Microsoft.Automation/automationAccounts/aa-monitor/jobSchedules/matching'
                    properties = [pscustomobject]@{
                        runbook  = [pscustomobject]@{ name = 'Watch-KeyVaultChanges' }
                        schedule = [pscustomobject]@{ name = 'Daily-KeyVault-Change-Scan' }
                    }
                }
                [pscustomobject]@{
                    id         = '/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-automation/providers/Microsoft.Automation/automationAccounts/aa-monitor/jobSchedules/unrelated'
                    properties = [pscustomobject]@{
                        runbook  = [pscustomobject]@{ name = 'Other-Runbook' }
                        schedule = [pscustomobject]@{ name = 'Other-Schedule' }
                    }
                }
            )
        }
        Mock Invoke-AzureCli {
            $script:AzureCliCalls += , @($Arguments)
            $BodyIndex = [Array]::IndexOf([object[]]$Arguments, '--body')
            if ($BodyIndex -ge 0 -and $Arguments[$BodyIndex + 1] -like '@*') {
                $script:CapturedBody = Get-Content -LiteralPath $Arguments[$BodyIndex + 1].Substring(1) -Raw
            }
            return ''
        }
    }

    It 'Replaces only the matching binding and binds the runbook and schedule without parameters' {
        Set-AutomationJobSchedule `
            -Configuration $script:AutomationConfiguration `
            -Confirm:$false

        $script:AzureCliCalls | Should -HaveCount 2
        $DeleteCall = $script:AzureCliCalls | Where-Object { $_ -contains 'delete' }
        $PutCall = $script:AzureCliCalls | Where-Object { $_ -contains 'put' }
        $DeleteUrlIndex = [Array]::IndexOf($DeleteCall, '--url')
        $PutUrlIndex = [Array]::IndexOf($PutCall, '--url')
        $BodyIndex = [Array]::IndexOf($PutCall, '--body')

        $DeleteCall[$DeleteUrlIndex + 1] | Should -BeExactly (
            'https://management.azure.com/subscriptions/11111111-1111-1111-1111-111111111111/' +
            'resourceGroups/rg-automation/providers/Microsoft.Automation/automationAccounts/' +
            'aa-monitor/jobSchedules/matching?api-version=2024-10-23'
        )
        $PutCall[$PutUrlIndex + 1] | Should -Match (
            '/jobSchedules/[0-9a-f-]{36}\?api-version=2024-10-23$'
        )

        $PutCall[$BodyIndex + 1] | Should -Match '^@'
        $Request = $script:CapturedBody | ConvertFrom-Json
        $Request.properties.runbook.name | Should -BeExactly 'Watch-KeyVaultChanges'
        $Request.properties.schedule.name | Should -BeExactly 'Daily-KeyVault-Change-Scan'
        $Request.properties.psobject.Properties.Name | Should -Not -Contain 'parameters'
    }
}

Describe 'Set-AutomationConfigurationVariable' -Tag 'Unit' {
    BeforeEach {
        $script:VariableBodies = @{}
        Mock Invoke-AzureCli {
            $UrlIndex = [Array]::IndexOf([object[]]$Arguments, '--url')
            $BodyIndex = [Array]::IndexOf([object[]]$Arguments, '--body')
            $Url = $Arguments[$UrlIndex + 1]
            $VariableName = ($Url -split '/variables/')[1] -replace '\?.*$', ''
            $Body = Get-Content -LiteralPath $Arguments[$BodyIndex + 1].Substring(1) -Raw
            $script:VariableBodies[$VariableName] = $Body
            return ''
        }
    }

    It 'Writes every configuration value as a JSON-encoded Automation variable' {
        Set-AutomationConfigurationVariable `
            -Configuration $script:AutomationConfiguration `
            -Confirm:$false

        $script:VariableBodies.Keys | Should -HaveCount 7
        $script:VariableBodies.Keys | Should -Contain 'KeyVaultMonitor-MonitoredSubscriptionIdsJson'

        $Recipient = $script:VariableBodies['KeyVaultMonitor-NotificationRecipient'] | ConvertFrom-Json
        $Recipient.name | Should -BeExactly 'KeyVaultMonitor-NotificationRecipient'
        $Recipient.properties.isEncrypted | Should -BeFalse
        # The stored value is the JSON-encoded string, so decoding it yields the original text.
        ($Recipient.properties.value | ConvertFrom-Json) | Should -BeExactly 'operator@contoso.com'

        $Subscriptions = $script:VariableBodies['KeyVaultMonitor-MonitoredSubscriptionIdsJson'] | ConvertFrom-Json
        ($Subscriptions.properties.value | ConvertFrom-Json) |
            Should -BeExactly '["22222222-2222-2222-2222-222222222222"]'
    }
}