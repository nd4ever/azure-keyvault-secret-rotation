#Requires -Modules Pester
#Requires -Version 7.2

BeforeAll {
    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    $script:Package = Get-Content -LiteralPath (Join-Path $ProjectRoot 'package.json') -Raw |
        ConvertFrom-Json
    $script:MainTemplate = Get-Content -LiteralPath (Join-Path $ProjectRoot 'infra/main.bicep') -Raw
}

Describe 'Key Vault change monitor project' -Tag 'Unit' {
    It 'Uses the expected project name' {
        $script:Package.name | Should -BeExactly 'azure-keyvault-change-monitor'
    }

    It 'Provides the complete validation command' {
        $script:Package.scripts.validate | Should -BeExactly 'npm run build:bicep && npm run lint:ps && npm run test:ps'
    }

    It 'Does not deploy an Azure Key Vault' {
        $script:MainTemplate | Should -Not -Match 'Microsoft\.KeyVault/vaults@'
        Test-Path -LiteralPath (Join-Path $ProjectRoot 'infra/modules/key-vault.bicep') |
            Should -BeFalse
    }

    It 'Deploys the monitoring resource modules' {
        $script:MainTemplate | Should -Match "module automation 'modules/automation\.bicep'"
        $script:MainTemplate | Should -Match "module communication 'modules/communication\.bicep'"
        $script:MainTemplate | Should -Match "module stateStorage 'modules/state-storage\.bicep'"
    }

    It 'Grants monitored subscription access idempotently from the wrapper' {
        $Wrapper = Get-Content -LiteralPath (Join-Path $ProjectRoot 'scripts/Deploy-Solution.ps1') -Raw
        $Wrapper | Should -Match 'function Set-MonitoredSubscriptionAccess'
        $Wrapper | Should -Match "'role'"
        Test-Path -LiteralPath (Join-Path $ProjectRoot 'infra/modules/subscription-access.bicep') |
            Should -BeFalse
    }

    It 'Provides an interactive deployment wrapper and monitoring runbook' {
        Test-Path -LiteralPath (Join-Path $ProjectRoot 'scripts/Deploy-Solution.ps1') |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path $ProjectRoot 'runbooks/Watch-KeyVaultChanges.ps1') |
            Should -BeTrue
    }
}
