#!/usr/bin/env pwsh
#Requires -Version 7.2

<#
.SYNOPSIS
    Deploys and configures the Azure Key Vault change monitor.
.DESCRIPTION
    Prompts for solution settings, including whether to reuse an Automation
    account and Azure Communication Services resource. Deploys the Bicep
    resources, publishes the PowerShell 7.2 runbook, and links its daily
    schedule. In noninteractive mode, omitted existing resources are created.
.PARAMETER DeploymentSubscriptionId
    Subscription used for the root deployment and solution resource group.
.PARAMETER Location
    Azure region for solution-owned resources and deployment metadata.
.PARAMETER ResourceGroupName
    Resource group created for solution-owned resources.
.PARAMETER NotificationRecipient
    UPN or email address that receives monitor notifications.
.PARAMETER MonitoredSubscriptionIds
    Subscription IDs to scan. Defaults to every enabled subscription visible
    to the current Azure CLI identity.
.PARAMETER ExistingAutomationAccountName
    Name of an Automation account to reuse. Omit to create an account.
.PARAMETER ExistingCommunicationServiceName
    Name of an Azure Communication Services resource to reuse. Omit to create
    Azure Communication Services email resources.
.PARAMETER NonInteractive
    Disables prompts and requires all otherwise interactive values.
.PARAMETER SkipLegacyAccessPolicies
    Does not add metadata-list permissions to Key Vaults that use legacy access
    policies. Use this only when those permissions are managed separately.
.PARAMETER StateStoragePolicyExemptionTags
    Optional tags merged only into the state storage account, for example an SFI
    public-network-access policy exemption. Supply environment-specific values at
    deploy time so they stay out of source control.
.EXAMPLE
    ./scripts/Deploy-Solution.ps1
.EXAMPLE
    ./scripts/Deploy-Solution.ps1 -NonInteractive `
        -Location eastus2 `
        -ResourceGroupName rg-kv-monitor `
        -NotificationRecipient operator@contoso.com
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$DeploymentSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$Location,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$NotificationRecipient,

    [Parameter(Mandatory = $false)]
    [string[]]$MonitoredSubscriptionIds,

    [Parameter(Mandatory = $false)]
    [string]$ExistingAutomationAccountName,

    [Parameter(Mandatory = $false)]
    [string]$ExistingAutomationAccountResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ExistingAutomationAccountSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ExistingCommunicationServiceName,

    [Parameter(Mandatory = $false)]
    [string]$ExistingCommunicationServiceResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$ExistingCommunicationServiceSubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ExistingCommunicationServiceSenderAddress,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ScheduleStartTime = [DateTime]::UtcNow.AddMinutes(15).ToString('O'),

    [Parameter(Mandatory = $false)]
    [hashtable]$StateStoragePolicyExemptionTags = @{},

    [Parameter(Mandatory = $false)]
    [switch]$NonInteractive,

    [Parameter(Mandatory = $false)]
    [switch]$SkipLegacyAccessPolicies
)

$ErrorActionPreference = 'Stop'
$script:AutomationApiVersion = '2024-10-23'

function Get-AzureApiUri {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$BaseUri,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ApiVersion
    )

    if ($BaseUri -notmatch '^https://') {
        throw "Cannot build an Azure REST URL from base '$BaseUri'."
    }

    return "$BaseUri`?api-version=$ApiVersion"
}

function Invoke-AzureCli {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $false)]
        [switch]$AllowEmptyOutput
    )

    $Output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $Message = ($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        throw "Azure CLI command failed: az $($Arguments -join ' ')$([Environment]::NewLine)$Message"
    }

    $Text = ($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if (-not $AllowEmptyOutput -and [string]::IsNullOrWhiteSpace($Text)) {
        throw "Azure CLI command returned no output: az $($Arguments -join ' ')"
    }

    return $Text
}

function Invoke-AzureCliJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $Json = Invoke-AzureCli -Arguments ($Arguments + @('--only-show-errors', '--output', 'json'))
    return $Json | ConvertFrom-Json
}

function Read-RequiredInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$DefaultValue
    )

    $DisplayPrompt = if ([string]::IsNullOrWhiteSpace($DefaultValue)) {
        $Prompt
    }
    else {
        "$Prompt [$DefaultValue]"
    }
    $Value = Read-Host -Prompt $DisplayPrompt
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = $DefaultValue
    }
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Prompt is required."
    }

    return $Value.Trim()
}

function Test-YesResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    return (Read-Host -Prompt "$Prompt [y/N]") -match '^(?i:y|yes)$'
}

function Assert-EmailAddress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Address,

        [Parameter(Mandatory = $true)]
        [string]$ParameterName
    )

    try {
        $ParsedAddress = [System.Net.Mail.MailAddress]::new($Address)
    }
    catch {
        throw "$ParameterName must be a valid email address."
    }

    if ($ParsedAddress.Address -ne $Address) {
        throw "$ParameterName must contain one email address without a display name."
    }
}

function Get-EnabledTenantSubscription {
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Subscriptions,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$TenantId
    )

    return @(
        $Subscriptions | Where-Object {
            $_.state -eq 'Enabled' -and $_.tenantId -eq $TenantId
        }
    )
}

function Get-ExistingResourceGroupLocation {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $Output = & az group show `
        --name $Name `
        --subscription $SubscriptionId `
        --only-show-errors `
        --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    $Text = ($Output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    return ($Text | ConvertFrom-Json).location
}

function Get-ExistingAzureResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceId,

        [Parameter(Mandatory = $true)]
        [string]$ApiVersion
    )

    return Invoke-AzureCliJson -Arguments @(
        'resource'
        'show'
        '--ids'
        $ResourceId
        '--api-version'
        $ApiVersion
    )
}

function ConvertTo-DeploymentParameterDocument {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Values
    )

    $Parameters = [ordered]@{}
    foreach ($Entry in $Values.GetEnumerator()) {
        if ($null -ne $Entry.Value -and -not [string]::IsNullOrWhiteSpace([string]$Entry.Value)) {
            $Parameters[$Entry.Key] = @{ value = $Entry.Value }
        }
    }

    return [ordered]@{
        '$schema'       = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = $Parameters
    }
}

function Get-AutomationResourceUri {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    return 'https://management.azure.com/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f (
        $Configuration.accountSubscriptionId,
        $Configuration.accountResourceGroupName,
        $Configuration.accountName
    )
}

function Get-AzureRestCollection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InitialUri
    )

    $Items = [System.Collections.Generic.List[object]]::new()
    $NextUri = $InitialUri
    while (-not [string]::IsNullOrWhiteSpace($NextUri)) {
        $Page = Invoke-AzureCliJson -Arguments @('rest', '--method', 'get', '--url', $NextUri)
        foreach ($Item in @($Page.value)) {
            if ($null -ne $Item) {
                $Items.Add($Item)
            }
        }
        $NextUri = $Page.nextLink
    }

    return $Items.ToArray()
}

function Wait-AutomationRunbook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$RunbookUri,

        [Parameter(Mandatory = $true)]
        [ValidateSet('DraftReady', 'Published')]
        [string]$State,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 300)]
        [int]$TimeoutSeconds = 120
    )

    $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $Runbook = Invoke-AzureCliJson -Arguments @(
            'rest'
            '--method'
            'get'
            '--url'
            (Get-AzureApiUri -BaseUri $RunbookUri -ApiVersion $script:AutomationApiVersion)
        )
        $IsReady = if ($State -eq 'DraftReady') {
            $Runbook.properties.provisioningState -eq 'Succeeded'
        }
        else {
            $Runbook.properties.provisioningState -eq 'Succeeded' -and
            $Runbook.properties.state -eq 'Published' -and
            -not $Runbook.properties.draft.inEdit
        }

        if ($IsReady) {
            return
        }

        Start-Sleep -Seconds 2
    }

    throw "Timed out waiting for runbook state '$State'."
}

function Publish-AutomationRunbook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration,

        [Parameter(Mandatory = $true)]
        [string]$RunbookPath
    )

    $AutomationUri = Get-AutomationResourceUri -Configuration $Configuration
    $RunbookUri = "$AutomationUri/runbooks/$($Configuration.runbookName)"
    Invoke-AzureCli -Arguments @(
        'rest'
        '--method'
        'put'
        '--url'
        (Get-AzureApiUri -BaseUri "$RunbookUri/draft/content" -ApiVersion $script:AutomationApiVersion)
        '--headers'
        'Content-Type=text/plain'
        '--body'
        "@$RunbookPath"
        '--only-show-errors'
        '--output'
        'none'
    ) -AllowEmptyOutput | Out-Null
    Wait-AutomationRunbook -RunbookUri $RunbookUri -State DraftReady

    Invoke-AzureCli -Arguments @(
        'rest'
        '--method'
        'post'
        '--url'
        (Get-AzureApiUri -BaseUri "$RunbookUri/publish" -ApiVersion $script:AutomationApiVersion)
        '--only-show-errors'
        '--output'
        'none'
    ) -AllowEmptyOutput | Out-Null
    Wait-AutomationRunbook -RunbookUri $RunbookUri -State Published
}

function Set-MonitoredSubscriptionAccess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SubscriptionIds
    )

    $Roles = [ordered]@{
        'Reader'           = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
        'Key Vault Reader' = '21090545-7ca7-4776-b22c-e363652d74d2'
    }
    foreach ($SubscriptionId in $SubscriptionIds) {
        $Scope = "/subscriptions/$SubscriptionId"
        $ExistingRoleDefinitionIds = @(Invoke-AzureCliJson -Arguments @(
            'role'
            'assignment'
            'list'
            '--scope'
            $Scope
            '--query'
            "[?principalId=='$PrincipalId'].roleDefinitionId"
        ))
        foreach ($Role in $Roles.GetEnumerator()) {
            $AlreadyAssigned = @(
                $ExistingRoleDefinitionIds | Where-Object { $_ -like "*/$($Role.Value)" }
            ).Count -gt 0
            if ($AlreadyAssigned) {
                continue
            }
            if ($PSCmdlet.ShouldProcess($Scope, "Grant '$($Role.Key)' to Automation identity")) {
                try {
                    Invoke-AzureCli -Arguments @(
                        'role'
                        'assignment'
                        'create'
                        '--assignee-object-id'
                        $PrincipalId
                        '--assignee-principal-type'
                        'ServicePrincipal'
                        '--role'
                        $Role.Value
                        '--scope'
                        $Scope
                        '--only-show-errors'
                        '--output'
                        'none'
                    ) -AllowEmptyOutput | Out-Null
                }
                catch {
                    # Tolerate an assignment created by a prior run or held under a different name.
                    if ($_.Exception.Message -notmatch 'RoleAssignmentExists') {
                        throw
                    }
                }
            }
        }
    }
}

function Set-LegacyKeyVaultAccessPolicy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PrincipalId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$SubscriptionIds
    )

    foreach ($SubscriptionId in $SubscriptionIds) {
        $Vaults = @(Invoke-AzureCliJson -Arguments @(
            'keyvault'
            'list'
            '--subscription'
            $SubscriptionId
        ))
        foreach ($Vault in $Vaults) {
            $VaultDetail = Invoke-AzureCliJson -Arguments @(
                'keyvault'
                'show'
                '--name'
                $Vault.name
                '--subscription'
                $SubscriptionId
            )
            if ($VaultDetail.properties.enableRbacAuthorization) {
                continue
            }

            $ExistingPolicy = @(
                $VaultDetail.properties.accessPolicies | Where-Object {
                    $_.objectId -eq $PrincipalId
                }
            ) | Select-Object -First 1
            $KeyPermissions = @($ExistingPolicy.permissions.keys | Sort-Object -Unique)
            $SecretPermissions = @(
                @($ExistingPolicy.permissions.secrets) + 'list' |
                    Sort-Object -Unique
            )
            $CertificatePermissions = @(
                @($ExistingPolicy.permissions.certificates) + 'list' |
                    Sort-Object -Unique
            )
            $StoragePermissions = @($ExistingPolicy.permissions.storage | Sort-Object -Unique)
            $Arguments = [System.Collections.Generic.List[string]]::new()
            $Arguments.AddRange([string[]]@(
                'keyvault'
                'set-policy'
                '--subscription'
                $SubscriptionId
                '--resource-group'
                $VaultDetail.resourceGroup
                '--name'
                $VaultDetail.name
                '--object-id'
                $PrincipalId
            ))
            foreach ($PermissionSet in @(
                @{ Name = '--key-permissions'; Values = $KeyPermissions }
                @{ Name = '--secret-permissions'; Values = $SecretPermissions }
                @{ Name = '--certificate-permissions'; Values = $CertificatePermissions }
                @{ Name = '--storage-permissions'; Values = $StoragePermissions }
            )) {
                if ($PermissionSet.Values.Count -gt 0) {
                    $Arguments.Add($PermissionSet.Name)
                    $Arguments.AddRange([string[]]$PermissionSet.Values)
                }
            }
            $Arguments.AddRange([string[]]@(
                '--only-show-errors'
                '--output'
                'none'
            ))

            if ($PSCmdlet.ShouldProcess($VaultDetail.id, 'Grant metadata-list access to Automation identity')) {
                try {
                    Invoke-AzureCli -Arguments $Arguments.ToArray() -AllowEmptyOutput | Out-Null
                }
                catch {
                    # Skip vaults that use Azure RBAC; the Key Vault Reader role already covers them.
                    if ($_.Exception.Message -notmatch 'enable-rbac-authorization') {
                        throw
                    }
                }
            }
        }
    }
}

function Set-AutomationConfigurationVariable {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )

    $AutomationUri = Get-AutomationResourceUri -Configuration $Configuration
    $Variables = [ordered]@{
        'KeyVaultMonitor-CommunicationEndpoint'        = $Configuration.communicationEndpoint
        'KeyVaultMonitor-MonitoredSubscriptionIdsJson' = $Configuration.monitoredSubscriptionIdsJson
        'KeyVaultMonitor-NotificationRecipient'        = $Configuration.notificationRecipient
        'KeyVaultMonitor-SenderAddress'                = $Configuration.senderAddress
        'KeyVaultMonitor-StateBlobName'                = $Configuration.stateBlobName
        'KeyVaultMonitor-StateContainerName'           = $Configuration.stateContainerName
        'KeyVaultMonitor-StateStorageAccountName'      = $Configuration.storageAccountName
    }
    foreach ($Variable in $Variables.GetEnumerator()) {
        # Automation stores variable values as JSON; encode the string so Get-AutomationVariable
        # returns the original text (not a deserialized array) inside the runbook.
        $Body = [ordered]@{
            name       = $Variable.Key
            properties = [ordered]@{
                isEncrypted = $false
                value       = ([string]$Variable.Value | ConvertTo-Json)
            }
        } | ConvertTo-Json -Depth 4 -Compress
        if ($PSCmdlet.ShouldProcess($Variable.Key, 'Set Automation configuration variable')) {
            $BodyFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -LiteralPath $BodyFile -Value $Body -Encoding utf8NoBOM
                Invoke-AzureCli -Arguments @(
                    'rest'
                    '--method'
                    'put'
                    '--url'
                    (Get-AzureApiUri -BaseUri "$AutomationUri/variables/$($Variable.Key)" -ApiVersion $script:AutomationApiVersion)
                    '--headers'
                    'Content-Type=application/json'
                    '--body'
                    "@$BodyFile"
                    '--only-show-errors'
                    '--output'
                    'none'
                ) -AllowEmptyOutput | Out-Null
            }
            finally {
                Remove-Item -LiteralPath $BodyFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Set-AutomationJobSchedule {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Configuration
    )
    $AutomationUri = Get-AutomationResourceUri -Configuration $Configuration
    $JobSchedulesUri = "$AutomationUri/jobSchedules"
    $ExistingBindings = Get-AzureRestCollection `
        -InitialUri (Get-AzureApiUri -BaseUri $JobSchedulesUri -ApiVersion $script:AutomationApiVersion)
    foreach ($Binding in $ExistingBindings) {
        if ($Binding.properties.runbook.name -eq $Configuration.runbookName -and
            $Binding.properties.schedule.name -eq $Configuration.scheduleName) {
            if ($PSCmdlet.ShouldProcess($Binding.id, 'Delete Automation job schedule binding')) {
                Invoke-AzureCli -Arguments @(
                    'rest'
                    '--method'
                    'delete'
                    '--url'
                    (Get-AzureApiUri -BaseUri "https://management.azure.com$($Binding.id)" -ApiVersion $script:AutomationApiVersion)
                    '--only-show-errors'
                    '--output'
                    'none'
                ) -AllowEmptyOutput | Out-Null
            }
        }
    }

    $Body = [ordered]@{
        properties = [ordered]@{
            runbook  = @{ name = $Configuration.runbookName }
            schedule = @{ name = $Configuration.scheduleName }
        }
    } | ConvertTo-Json -Depth 6 -Compress
    $JobScheduleId = [Guid]::NewGuid().ToString()
    if ($PSCmdlet.ShouldProcess($Configuration.scheduleName, 'Create Automation job schedule binding')) {
        $BodyFile = [System.IO.Path]::GetTempFileName()
        try {
            Set-Content -LiteralPath $BodyFile -Value $Body -Encoding utf8NoBOM
            Invoke-AzureCli -Arguments @(
                'rest'
                '--method'
                'put'
                '--url'
                (Get-AzureApiUri -BaseUri "$JobSchedulesUri/$JobScheduleId" -ApiVersion $script:AutomationApiVersion)
                '--headers'
                'Content-Type=application/json'
                '--body'
                "@$BodyFile"
                '--only-show-errors'
                '--output'
                'none'
            ) -AllowEmptyOutput | Out-Null
        }
        finally {
            Remove-Item -LiteralPath $BodyFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SolutionDeployment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$BoundParameters
    )

    if ($null -eq (Get-Command -Name az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required. Install it from https://aka.ms/installazurecli.'
    }

    $Account = Invoke-AzureCliJson -Arguments @('account', 'show')
    $Subscriptions = @(Invoke-AzureCliJson -Arguments @(
        'account'
        'list'
        '--query'
        '[].{id:id,name:name,state:state,tenantId:tenantId}'
    ))
    $EnabledSubscriptions = @(
        Get-EnabledTenantSubscription -Subscriptions $Subscriptions -TenantId $Account.tenantId
    )
    if ($EnabledSubscriptions.Count -eq 0) {
        throw 'No enabled Azure subscriptions are visible. Run az login and try again.'
    }

    $ResolvedDeploymentSubscriptionId = $BoundParameters.DeploymentSubscriptionId
    if ([string]::IsNullOrWhiteSpace($ResolvedDeploymentSubscriptionId)) {
        $ResolvedDeploymentSubscriptionId = $Account.id
    }
    $ResolvedLocation = $BoundParameters.Location
    $ResolvedResourceGroupName = $BoundParameters.ResourceGroupName
    $ResolvedNotificationRecipient = $BoundParameters.NotificationRecipient

    if (-not $BoundParameters.NonInteractive) {
        $ResolvedDeploymentSubscriptionId = Read-RequiredInput `
            -Prompt 'Deployment subscription ID' `
            -DefaultValue $ResolvedDeploymentSubscriptionId
        $ResolvedResourceGroupName = Read-RequiredInput `
            -Prompt 'Solution resource group name' `
            -DefaultValue $ResolvedResourceGroupName
        $ExistingResourceGroupLocation = Get-ExistingResourceGroupLocation `
            -Name $ResolvedResourceGroupName `
            -SubscriptionId $ResolvedDeploymentSubscriptionId
        if (-not [string]::IsNullOrWhiteSpace($ExistingResourceGroupLocation)) {
            $ResolvedLocation = $ExistingResourceGroupLocation
            Write-Output (
                "Using existing resource group '$ResolvedResourceGroupName' " +
                "in '$ExistingResourceGroupLocation'; skipping the region prompt."
            )
        }
        else {
            $ResolvedLocation = Read-RequiredInput -Prompt 'Azure region' -DefaultValue $ResolvedLocation
        }
        $ResolvedNotificationRecipient = Read-RequiredInput `
            -Prompt 'Notification recipient UPN or email address' `
            -DefaultValue $ResolvedNotificationRecipient
    }

    foreach ($RequiredValue in @{
        Location              = $ResolvedLocation
        NotificationRecipient = $ResolvedNotificationRecipient
        ResourceGroupName     = $ResolvedResourceGroupName
    }.GetEnumerator()) {
        if ([string]::IsNullOrWhiteSpace([string]$RequiredValue.Value)) {
            throw "$($RequiredValue.Key) is required in noninteractive mode."
        }
    }
    Assert-EmailAddress -Address $ResolvedNotificationRecipient -ParameterName NotificationRecipient

    $ResolvedMonitoredSubscriptionIds = @(
        $BoundParameters.MonitoredSubscriptionIds |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
    if ($ResolvedMonitoredSubscriptionIds.Count -eq 0) {
        if (-not $BoundParameters.NonInteractive) {
            $SubscriptionInput = Read-Host -Prompt (
                'Monitored subscription IDs, comma-separated ' +
                "[Enter for all $($EnabledSubscriptions.Count) enabled subscriptions]"
            )
            if (-not [string]::IsNullOrWhiteSpace($SubscriptionInput)) {
                $ResolvedMonitoredSubscriptionIds = @(
                    $SubscriptionInput.Split(',') |
                        ForEach-Object { $_.Trim() } |
                        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                )
            }
        }
        if ($ResolvedMonitoredSubscriptionIds.Count -eq 0) {
            $ResolvedMonitoredSubscriptionIds = @($EnabledSubscriptions.id)
        }
    }

    $EnabledSubscriptionIdSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($EnabledSubscription in $EnabledSubscriptions) {
        [void]$EnabledSubscriptionIdSet.Add([string]$EnabledSubscription.id)
    }
    $UniqueSubscriptionIdSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $UniqueMonitoredSubscriptionIds = [System.Collections.Generic.List[string]]::new()
    foreach ($SubscriptionId in $ResolvedMonitoredSubscriptionIds) {
        $ParsedSubscriptionId = [Guid]::Empty
        if (-not [Guid]::TryParse($SubscriptionId, [ref]$ParsedSubscriptionId)) {
            throw "Monitored subscription ID '$SubscriptionId' is not a valid GUID."
        }
        $NormalizedSubscriptionId = $ParsedSubscriptionId.ToString()
        if (-not $EnabledSubscriptionIdSet.Contains($NormalizedSubscriptionId)) {
            throw "Monitored subscription '$NormalizedSubscriptionId' is not enabled in tenant '$($Account.tenantId)'."
        }
        if ($UniqueSubscriptionIdSet.Add($NormalizedSubscriptionId)) {
            $UniqueMonitoredSubscriptionIds.Add($NormalizedSubscriptionId)
        }
    }
    $ResolvedMonitoredSubscriptionIds = $UniqueMonitoredSubscriptionIds.ToArray()

    $ResolvedAutomationName = $BoundParameters.ExistingAutomationAccountName
    $ResolvedAutomationResourceGroup = $BoundParameters.ExistingAutomationAccountResourceGroupName
    $ResolvedAutomationSubscription = $BoundParameters.ExistingAutomationAccountSubscriptionId
    if (-not $BoundParameters.NonInteractive -and
        [string]::IsNullOrWhiteSpace($ResolvedAutomationName) -and
        (Test-YesResponse -Prompt 'Reuse an existing Azure Automation account?')) {
        $ResolvedAutomationSubscription = Read-RequiredInput `
            -Prompt 'Automation account subscription ID' `
            -DefaultValue $ResolvedDeploymentSubscriptionId
        $ResolvedAutomationResourceGroup = Read-RequiredInput -Prompt 'Automation account resource group'
        $ResolvedAutomationName = Read-RequiredInput -Prompt 'Automation account name'
    }

    $AutomationLocation = $null
    if (-not [string]::IsNullOrWhiteSpace($ResolvedAutomationName)) {
        if ([string]::IsNullOrWhiteSpace($ResolvedAutomationResourceGroup)) {
            throw 'ExistingAutomationAccountResourceGroupName is required when reusing an Automation account.'
        }
        if ([string]::IsNullOrWhiteSpace($ResolvedAutomationSubscription)) {
            $ResolvedAutomationSubscription = $ResolvedDeploymentSubscriptionId
        }
        $AutomationId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Automation/automationAccounts/{2}' -f (
            $ResolvedAutomationSubscription,
            $ResolvedAutomationResourceGroup,
            $ResolvedAutomationName
        )
        $AutomationAccount = Get-ExistingAzureResource `
            -ResourceId $AutomationId `
            -ApiVersion $script:AutomationApiVersion
        if ([string]::IsNullOrWhiteSpace($AutomationAccount.identity.principalId) -or
            $AutomationAccount.identity.type -notmatch 'SystemAssigned') {
            throw 'The existing Automation account must have a system-assigned managed identity.'
        }
        $AutomationLocation = $AutomationAccount.location
    }

    $ResolvedCommunicationName = $BoundParameters.ExistingCommunicationServiceName
    $ResolvedCommunicationResourceGroup = $BoundParameters.ExistingCommunicationServiceResourceGroupName
    $ResolvedCommunicationSubscription = $BoundParameters.ExistingCommunicationServiceSubscriptionId
    $ResolvedSenderAddress = $BoundParameters.ExistingCommunicationServiceSenderAddress
    if (-not $BoundParameters.NonInteractive -and
        [string]::IsNullOrWhiteSpace($ResolvedCommunicationName) -and
        (Test-YesResponse -Prompt 'Reuse an existing Azure Communication Services resource?')) {
        $ResolvedCommunicationSubscription = Read-RequiredInput `
            -Prompt 'Communication Services subscription ID' `
            -DefaultValue $ResolvedDeploymentSubscriptionId
        $ResolvedCommunicationResourceGroup = Read-RequiredInput `
            -Prompt 'Communication Services resource group'
        $ResolvedCommunicationName = Read-RequiredInput -Prompt 'Communication Services resource name'
        $ResolvedSenderAddress = Read-RequiredInput -Prompt 'Verified sender email address'
    }

    if (-not [string]::IsNullOrWhiteSpace($ResolvedCommunicationName)) {
        if ([string]::IsNullOrWhiteSpace($ResolvedCommunicationResourceGroup) -or
            [string]::IsNullOrWhiteSpace($ResolvedSenderAddress)) {
            throw ('ExistingCommunicationServiceResourceGroupName and ' +
                'ExistingCommunicationServiceSenderAddress are required when reusing Communication Services.')
        }
        if ([string]::IsNullOrWhiteSpace($ResolvedCommunicationSubscription)) {
            $ResolvedCommunicationSubscription = $ResolvedDeploymentSubscriptionId
        }
        Assert-EmailAddress -Address $ResolvedSenderAddress `
            -ParameterName ExistingCommunicationServiceSenderAddress
        $CommunicationId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.Communication/communicationServices/{2}' -f (
            $ResolvedCommunicationSubscription,
            $ResolvedCommunicationResourceGroup,
            $ResolvedCommunicationName
        )
        Get-ExistingAzureResource -ResourceId $CommunicationId -ApiVersion '2025-05-01' | Out-Null
    }

    $ProjectRoot = Split-Path $PSScriptRoot -Parent
    $TemplatePath = Join-Path $ProjectRoot 'infra/main.bicep'
    $RunbookPath = Join-Path $ProjectRoot 'runbooks/Watch-KeyVaultChanges.ps1'
    $DeploymentName = 'key-vault-change-monitor-{0}' -f [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    $ResolvedResourceGroupLocation = $ResolvedLocation
    $ExistingResourceGroupLocation = Get-ExistingResourceGroupLocation `
        -Name $ResolvedResourceGroupName `
        -SubscriptionId $ResolvedDeploymentSubscriptionId
    if (-not [string]::IsNullOrWhiteSpace($ExistingResourceGroupLocation)) {
        $ResolvedResourceGroupLocation = $ExistingResourceGroupLocation
        if ($ExistingResourceGroupLocation -ne $ResolvedLocation) {
            Write-Warning (
                "Resource group '$ResolvedResourceGroupName' already exists in " +
                "'$ExistingResourceGroupLocation'. New resources use '$ResolvedLocation'; " +
                'the resource group location cannot change.'
            )
        }
    }
    $ParameterValues = [ordered]@{
        existingAutomationAccountLocation                  = $AutomationLocation
        existingAutomationAccountName                      = $ResolvedAutomationName
        existingAutomationAccountResourceGroupName         = $ResolvedAutomationResourceGroup
        existingAutomationAccountSubscriptionId            = $ResolvedAutomationSubscription
        existingCommunicationServiceName                   = $ResolvedCommunicationName
        existingCommunicationServiceResourceGroupName      = $ResolvedCommunicationResourceGroup
        existingCommunicationServiceSenderAddress          = $ResolvedSenderAddress
        existingCommunicationServiceSubscriptionId         = $ResolvedCommunicationSubscription
        location                                           = $ResolvedLocation
        monitoredSubscriptionIds                           = $ResolvedMonitoredSubscriptionIds
        notificationRecipient                              = $ResolvedNotificationRecipient
        resourceGroupLocation                              = $ResolvedResourceGroupLocation
        resourceGroupName                                  = $ResolvedResourceGroupName
        scheduleStartTime                                  = $BoundParameters.ScheduleStartTime
    }
    $ResolvedStateStoragePolicyExemptionTags = $BoundParameters.StateStoragePolicyExemptionTags
    if ($ResolvedStateStoragePolicyExemptionTags -and $ResolvedStateStoragePolicyExemptionTags.Count -gt 0) {
        $ParameterValues.stateStoragePolicyExemptionTags = $ResolvedStateStoragePolicyExemptionTags
    }
    $ParameterDocument = ConvertTo-DeploymentParameterDocument -Values $ParameterValues
    $ParameterFile = [System.IO.Path]::GetTempFileName()

    try {
        $ParameterDocument | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ParameterFile -Encoding utf8NoBOM
        $Deployment = Invoke-AzureCliJson -Arguments @(
            'deployment'
            'sub'
            'create'
            '--name'
            $DeploymentName
            '--subscription'
            $ResolvedDeploymentSubscriptionId
            '--location'
            $ResolvedLocation
            '--template-file'
            $TemplatePath
            '--parameters'
            "@$ParameterFile"
        )
    }
    finally {
        Remove-Item -LiteralPath $ParameterFile -Force -ErrorAction SilentlyContinue
    }

    $Configuration = $Deployment.properties.outputs.automationConfiguration.value
    if ($null -eq $Configuration) {
        throw 'The deployment did not return Automation configuration output.'
    }
    $AutomationPrincipalId = $Deployment.properties.outputs.automationPrincipalId.value
    if ([string]::IsNullOrWhiteSpace($AutomationPrincipalId)) {
        throw 'The deployment did not return the Automation managed identity principal ID.'
    }

    Set-MonitoredSubscriptionAccess `
        -PrincipalId $AutomationPrincipalId `
        -SubscriptionIds $ResolvedMonitoredSubscriptionIds

    if (-not $BoundParameters.SkipLegacyAccessPolicies) {
        Set-LegacyKeyVaultAccessPolicy `
            -PrincipalId $AutomationPrincipalId `
            -SubscriptionIds $ResolvedMonitoredSubscriptionIds
    }
    Publish-AutomationRunbook -Configuration $Configuration -RunbookPath $RunbookPath
    Set-AutomationConfigurationVariable -Configuration $Configuration
    Set-AutomationJobSchedule -Configuration $Configuration

    return [pscustomobject]@{
        AutomationAccount = $Configuration.accountName
        DeploymentName     = $DeploymentName
        MonitoredCount     = $ResolvedMonitoredSubscriptionIds.Count
        RunbookName        = $Configuration.runbookName
        ScheduleName       = $Configuration.scheduleName
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-SolutionDeployment -BoundParameters $PSBoundParameters
}