#Requires -Modules Pester
#Requires -Version 7.2

BeforeAll {
    $RunbookPath = Join-Path $PSScriptRoot '../runbooks/Watch-KeyVaultChanges.ps1'
    . $RunbookPath `
        -CommunicationEndpoint 'https://example.communication.azure.com' `
        -MonitoredSubscriptionIdsJson '["00000000-0000-0000-0000-000000000000"]' `
        -NotificationRecipient 'recipient@example.com' `
        -SenderAddress 'sender@example.azurecomm.net' `
        -StateBlobName 'state.json' `
        -StateContainerName 'monitor-state' `
        -StateStorageAccountName 'statestorage'

    function Get-TestMonitorItem {
        param(
            [string]$Fingerprint = '100|True|||',
            [string]$Identifier = 'https://vault-one.vault.azure.net/secrets/example',
            [string]$ObjectType = 'Secret',
            [string]$SubscriptionId = 'subscription-one',
            [string]$VaultResourceId = '/subscriptions/subscription-one/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/vault-one'
        )

        return @{
            fingerprint     = $Fingerprint
            identifier      = $Identifier
            name            = 'example'
            objectType      = $ObjectType
            subscriptionId  = $SubscriptionId
            updatedAtEpoch  = [long]($Fingerprint.Split('|')[0])
            vaultName       = 'vault-one'
            vaultResourceId = $VaultResourceId
        }
    }

    $script:ExpiryNowEpoch = [DateTimeOffset]::new(
        [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).ToUnixTimeSeconds()

    function Get-ExpiryTestItem {
        param(
            [long]$ExpiresInDays,
            [object]$NotifiedDaysAgo = $null
        )

        $Item = [ordered]@{
            expiresAtEpoch = $script:ExpiryNowEpoch + ($ExpiresInDays * 86400)
            name           = 'expiring'
            objectType     = 'Secret'
            subscriptionId = 'subscription-one'
            vaultName      = 'vault-one'
        }
        if ($null -ne $NotifiedDaysAgo) {
            $Item['expiryNotifiedEpoch'] = $script:ExpiryNowEpoch - ([long]$NotifiedDaysAgo * 86400)
        }

        return $Item
    }
}

Describe 'ConvertTo-MonitorItem' -Tag 'Unit' {
    It 'Stores metadata without storing a secret value' {
        $Secret = [pscustomobject]@{
            attributes = [pscustomobject]@{
                enabled = $true
                updated = 100
            }
            id         = 'https://vault-one.vault.azure.net/secrets/example'
            value      = 'must-not-be-stored'
        }

        $Result = ConvertTo-MonitorItem `
            -Item $Secret `
            -SubscriptionId 'subscription-one' `
            -VaultName 'vault-one' `
            -VaultResourceId '/subscriptions/subscription-one/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/vault-one' `
            -ObjectType Secret

        ($Result | ConvertTo-Json -Depth 5) | Should -Not -Match 'must-not-be-stored'
        $Result.name | Should -BeExactly 'example'
        $Result.objectType | Should -BeExactly 'Secret'
    }
}

Describe 'Compare-MonitorItem' -Tag 'Unit' {
    It 'Reports a changed item that existed in the previous baseline' {
        $Key = 'https://vault-one.vault.azure.net/secrets/example'
        $PreviousItems = @{ $Key = Get-TestMonitorItem -Fingerprint '100|True|||' }
        $CurrentItems = @{ $Key = Get-TestMonitorItem -Fingerprint '200|True|||' }

        $Changes = @(Compare-MonitorItem -PreviousItems $PreviousItems -CurrentItems $CurrentItems)

        $Changes | Should -HaveCount 1
        $Changes[0].ChangeType | Should -BeExactly 'Modified'
        $Changes[0].PreviousUpdatedAtEpoch | Should -Be 100
        $Changes[0].CurrentUpdatedAtEpoch | Should -Be 200
    }

    It 'Reports an item that is new to the current baseline' {
        $CurrentItems = @{
            'https://vault-one.vault.azure.net/secrets/new-secret' = Get-TestMonitorItem `
                -Identifier 'https://vault-one.vault.azure.net/secrets/new-secret'
        }

        $Changes = @(Compare-MonitorItem -PreviousItems @{} -CurrentItems $CurrentItems)

        $Changes | Should -HaveCount 1
        $Changes[0].ChangeType | Should -BeExactly 'New'
        $Changes[0].PreviousUpdatedAtEpoch | Should -BeNullOrEmpty
        $Changes[0].CurrentUpdatedAtEpoch | Should -Be 100
    }

    It 'Reports an item that was deleted from the current baseline' {
        $Key = 'https://vault-one.vault.azure.net/secrets/example'
        $PreviousItems = @{ $Key = Get-TestMonitorItem }

        $Changes = @(Compare-MonitorItem -PreviousItems $PreviousItems -CurrentItems @{})

        $Changes | Should -HaveCount 1
        $Changes[0].ChangeType | Should -BeExactly 'Deleted'
        $Changes[0].PreviousUpdatedAtEpoch | Should -Be 100
        $Changes[0].CurrentUpdatedAtEpoch | Should -BeNullOrEmpty
    }

    It 'Does not report an unchanged existing item' {
        $Key = 'https://vault-one.vault.azure.net/secrets/example'
        $PreviousItems = @{ $Key = Get-TestMonitorItem }
        $CurrentItems = @{ $Key = Get-TestMonitorItem }

        $Changes = @(Compare-MonitorItem -PreviousItems $PreviousItems -CurrentItems $CurrentItems)

        $Changes | Should -HaveCount 0
    }
}

Describe 'Failed scan state preservation' -Tag 'Unit' {
    It 'Preserves all prior items for a subscription discovery failure' {
        $PreviousItems = @{
            first = Get-TestMonitorItem -SubscriptionId 'failed-subscription'
            other = Get-TestMonitorItem -SubscriptionId 'successful-subscription'
        }
        $CurrentItems = @{}

        Copy-SubscriptionMonitorItem `
            -PreviousItems $PreviousItems `
            -CurrentItems $CurrentItems `
            -SubscriptionId 'failed-subscription'

        $CurrentItems.Keys | Should -HaveCount 1
        $CurrentItems.Contains('first') | Should -BeTrue
    }

    It 'Preserves only the failed object type for a vault' {
        $VaultResourceId = '/subscriptions/subscription-one/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/vault-one'
        $PreviousItems = @{
            certificate = Get-TestMonitorItem -ObjectType Certificate -VaultResourceId $VaultResourceId
            secret      = Get-TestMonitorItem -ObjectType Secret -VaultResourceId $VaultResourceId
        }
        $CurrentItems = @{}

        Copy-VaultTypeMonitorItem `
            -PreviousItems $PreviousItems `
            -CurrentItems $CurrentItems `
            -VaultResourceId $VaultResourceId `
            -ObjectType Certificate

        $CurrentItems.Keys | Should -HaveCount 1
        $CurrentItems.Contains('certificate') | Should -BeTrue
    }
}

Describe 'Get-PagedMonitorValue' -Tag 'Unit' {
    It 'Follows nextLink until all result pages are collected' {
        Mock Invoke-MonitorRequest {
            if ($Uri -eq 'https://example.test/page-one') {
                return [pscustomobject]@{
                    Content    = '{"value":[{"name":"first"}],"nextLink":"https://example.test/page-two"}'
                    Headers    = @{}
                    StatusCode = 200
                }
            }

            return [pscustomobject]@{
                Content    = '{"value":[{"name":"second"}],"nextLink":null}'
                Headers    = @{}
                StatusCode = 200
            }
        }

        $Results = @(Get-PagedMonitorValue `
            -InitialUri 'https://example.test/page-one' `
            -AccessToken 'token' `
            -Operation 'Test pagination')

        $Results | Should -HaveCount 2
        $Results[1].name | Should -BeExactly 'second'
        Should -Invoke Invoke-MonitorRequest -Times 2 -Exactly
    }
}

Describe 'ConvertTo-MonitorEmailContent' -Tag 'Unit' {
    It 'HTML encodes item and failure details' {
        $Changes = @(
            [pscustomobject]@{
                ChangeType             = 'Modified'
                CurrentUpdatedAtEpoch  = 200
                Name                   = '<script>alert(1)</script>'
                ObjectType             = 'Secret'
                PreviousUpdatedAtEpoch = 100
                SubscriptionId         = 'subscription-one'
                VaultName              = 'vault-one'
            }
        )
        $Failures = @(
            [pscustomobject]@{
                Message = '<unsafe>'
                Scope   = 'Certificate metadata'
            }
        )

        $Content = ConvertTo-MonitorEmailContent `
            -Changes $Changes `
            -Expirations @() `
            -Failures $Failures `
            -VaultCount 1 `
            -IsFirstRun $false

        $Content.Html | Should -Not -Match '<script>'
        $Content.Html | Should -Match '&lt;script&gt;'
        $Content.Html | Should -Match '&lt;unsafe&gt;'
        $Content.Subject | Should -BeExactly 'Key Vault monitor: 1 change(s), 1 scan failure(s)'
    }

    It 'Accepts an empty changes collection when only failures are reported' {
        $Failures = @(
            [pscustomobject]@{
                Message = 'Discovery failed'
                Scope   = 'Subscription discovery'
            }
        )

        $Content = ConvertTo-MonitorEmailContent `
            -Changes @() `
            -Expirations @() `
            -Failures $Failures `
            -VaultCount 0 `
            -IsFirstRun $true

        $Content.Subject | Should -BeExactly 'Key Vault monitor: 1 scan failure(s)'
        $Content.Html | Should -Match 'Changes detected: 0'
    }

    It 'Renders an expirations section and subject' {
        $Expirations = @(
            [pscustomobject]@{
                DaysUntilExpiry = 10
                ExpiresAtEpoch  = 1893456000
                Name            = 'expiring-secret'
                ObjectType      = 'Secret'
                SubscriptionId  = 'subscription-one'
                VaultName       = 'vault-one'
            }
        )

        $Content = ConvertTo-MonitorEmailContent `
            -Changes @() `
            -Expirations $Expirations `
            -Failures @() `
            -VaultCount 1 `
            -IsFirstRun $false

        $Content.Subject | Should -BeExactly 'Key Vault monitor: 1 expiring'
        $Content.Html | Should -Match 'Upcoming expirations'
        $Content.PlainText | Should -Match 'expires in 10 day\(s\)'
    }
}

Describe 'Get-MonitorExpiryAlert' -Tag 'Unit' {
    It 'Alerts on first notification within the warning window' {
        $Key = 'https://vault-one.vault.azure.net/secrets/expiring'
        $Current = @{ $Key = Get-ExpiryTestItem -ExpiresInDays 10 }
        $Keys = [System.Collections.Generic.HashSet[string]]::new()
        [void]$Keys.Add($Key)

        $Alerts = @(Get-MonitorExpiryAlert `
            -PreviousItems @{} `
            -CurrentItems $Current `
            -EvaluatedKeys $Keys `
            -WarningThresholdDays 30 `
            -ReminderIntervalDays 7 `
            -NowEpoch $script:ExpiryNowEpoch)

        $Alerts | Should -HaveCount 1
        $Alerts[0].DaysUntilExpiry | Should -Be 10
        $Current[$Key]['expiryNotifiedEpoch'] | Should -Be $script:ExpiryNowEpoch
    }

    It 'Does not alert outside the warning window' {
        $Key = 'https://vault-one.vault.azure.net/secrets/future'
        $Current = @{ $Key = Get-ExpiryTestItem -ExpiresInDays 45 }
        $Keys = [System.Collections.Generic.HashSet[string]]::new()
        [void]$Keys.Add($Key)

        $Alerts = @(Get-MonitorExpiryAlert `
            -PreviousItems @{} `
            -CurrentItems $Current `
            -EvaluatedKeys $Keys `
            -WarningThresholdDays 30 `
            -ReminderIntervalDays 7 `
            -NowEpoch $script:ExpiryNowEpoch)

        $Alerts | Should -HaveCount 0
    }

    It 'Suppresses a reminder within the interval' {
        $Key = 'https://vault-one.vault.azure.net/secrets/expiring'
        $Previous = @{ $Key = Get-ExpiryTestItem -ExpiresInDays 10 -NotifiedDaysAgo 3 }
        $Current = @{ $Key = Get-ExpiryTestItem -ExpiresInDays 10 }
        $Keys = [System.Collections.Generic.HashSet[string]]::new()
        [void]$Keys.Add($Key)

        $Alerts = @(Get-MonitorExpiryAlert `
            -PreviousItems $Previous `
            -CurrentItems $Current `
            -EvaluatedKeys $Keys `
            -WarningThresholdDays 30 `
            -ReminderIntervalDays 7 `
            -NowEpoch $script:ExpiryNowEpoch)

        $Alerts | Should -HaveCount 0
        $Current[$Key]['expiryNotifiedEpoch'] | Should -Be $Previous[$Key]['expiryNotifiedEpoch']
    }

    It 'Sends a reminder after the interval elapses' {
        $Key = 'https://vault-one.vault.azure.net/secrets/expiring'
        $Previous = @{ $Key = Get-ExpiryTestItem -ExpiresInDays 5 -NotifiedDaysAgo 8 }
        $Current = @{ $Key = Get-ExpiryTestItem -ExpiresInDays 5 }
        $Keys = [System.Collections.Generic.HashSet[string]]::new()
        [void]$Keys.Add($Key)

        $Alerts = @(Get-MonitorExpiryAlert `
            -PreviousItems $Previous `
            -CurrentItems $Current `
            -EvaluatedKeys $Keys `
            -WarningThresholdDays 30 `
            -ReminderIntervalDays 7 `
            -NowEpoch $script:ExpiryNowEpoch)

        $Alerts | Should -HaveCount 1
        $Current[$Key]['expiryNotifiedEpoch'] | Should -Be $script:ExpiryNowEpoch
    }

    It 'Alerts on an already expired item' {
        $Key = 'https://vault-one.vault.azure.net/secrets/expired'
        $Current = @{ $Key = Get-ExpiryTestItem -ExpiresInDays -3 }
        $Keys = [System.Collections.Generic.HashSet[string]]::new()
        [void]$Keys.Add($Key)

        $Alerts = @(Get-MonitorExpiryAlert `
            -PreviousItems @{} `
            -CurrentItems $Current `
            -EvaluatedKeys $Keys `
            -WarningThresholdDays 30 `
            -ReminderIntervalDays 7 `
            -NowEpoch $script:ExpiryNowEpoch)

        $Alerts | Should -HaveCount 1
        $Alerts[0].DaysUntilExpiry | Should -Be -3
    }
}