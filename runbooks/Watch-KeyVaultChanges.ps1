#Requires -Version 7.2

<#
.SYNOPSIS
    Reports changes to existing Azure Key Vault secrets and certificates.
.DESCRIPTION
    Uses the Automation account managed identity and Azure REST APIs to scan
    secret and certificate metadata, compare it with a blob-based baseline,
    and send change or scan-failure notifications through Azure Communication
    Services Email. Secret values are never requested.
.PARAMETER CommunicationEndpoint
    Endpoint of the Azure Communication Services resource.
.PARAMETER MonitoredSubscriptionIdsJson
    JSON array containing the subscription IDs to scan.
.PARAMETER NotificationRecipient
    Email address that receives monitor notifications.
.PARAMETER SenderAddress
    Verified Azure Communication Services Email sender address.
.PARAMETER StateBlobName
    Name of the blob containing monitor state.
.PARAMETER StateContainerName
    Name of the blob container containing monitor state.
.PARAMETER StateStorageAccountName
    Name of the storage account containing monitor state.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$CommunicationEndpoint,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$MonitoredSubscriptionIdsJson,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$NotificationRecipient,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$SenderAddress,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StateBlobName,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StateContainerName,

    [Parameter(Mandatory = $false)]
    [AllowEmptyString()]
    [string]$StateStorageAccountName
)

$ErrorActionPreference = 'Stop'
$script:ConfigurationVariablePrefix = 'KeyVaultMonitor-'

function Get-MonitorProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) {
            return $InputObject[$Name]
        }

        return $null
    }

    $Property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}

function Get-MonitorHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Header = $Response.Headers[$Name]
    if ($Header -is [System.Collections.IEnumerable] -and $Header -isnot [string]) {
        return $Header | Select-Object -First 1
    }

    return $Header
}

function Invoke-MonitorRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('GET', 'POST', 'PUT')]
        [string]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [string]$Body,

        [Parameter(Mandatory = $false)]
        [string]$ContentType = 'application/json',

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 10)]
        [int]$MaximumAttempts = 3
    )

    $RequestParameters = @{
        ErrorAction        = 'Stop'
        Headers            = $Headers
        Method             = $Method
        SkipHttpErrorCheck = $true
        Uri                = $Uri
    }

    if ($PSBoundParameters.ContainsKey('Body')) {
        $RequestParameters.Body = $Body
        $RequestParameters.ContentType = $ContentType
    }

    for ($Attempt = 1; $Attempt -le $MaximumAttempts; $Attempt++) {
        try {
            $Response = Invoke-WebRequest @RequestParameters
            $StatusCode = [int]$Response.StatusCode
            $IsTransient = $StatusCode -eq 429 -or $StatusCode -ge 500

            if (-not $IsTransient -or $Attempt -eq $MaximumAttempts) {
                return $Response
            }

            $RetryAfter = Get-MonitorHeader -Response $Response -Name 'Retry-After'
            $DelaySeconds = if ($RetryAfter -as [int]) {
                [int]$RetryAfter
            }
            else {
                [int][Math]::Pow(2, $Attempt - 1)
            }

            Start-Sleep -Seconds $DelaySeconds
        }
        catch {
            if ($Attempt -eq $MaximumAttempts) {
                throw
            }

            Start-Sleep -Seconds ([int][Math]::Pow(2, $Attempt - 1))
        }
    }
}

function Confirm-MonitorResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Response,

        [Parameter(Mandatory = $true)]
        [int[]]$ExpectedStatusCode,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $StatusCode = [int]$Response.StatusCode
    if ($StatusCode -notin $ExpectedStatusCode) {
        throw "$Operation failed with HTTP status $StatusCode."
    }
}

function Get-ManagedIdentityToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Resource
    )

    if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT) -or
        [string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) {
        throw 'The Azure Automation managed identity endpoint is unavailable.'
    }

    $Separator = if ($env:IDENTITY_ENDPOINT.Contains('?')) { '&' } else { '?' }
    $TokenUri = '{0}{1}resource={2}' -f (
        $env:IDENTITY_ENDPOINT,
        $Separator,
        [Uri]::EscapeDataString($Resource)
    )
    $Headers = @{
        Metadata            = 'true'
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
    }
    $Response = Invoke-MonitorRequest -Method GET -Uri $TokenUri -Headers $Headers
    Confirm-MonitorResponse -Response $Response -ExpectedStatusCode 200 -Operation 'Managed identity token acquisition'
    $TokenResponse = $Response.Content | ConvertFrom-Json
    $AccessToken = Get-MonitorProperty -InputObject $TokenResponse -Name 'access_token'

    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw 'The managed identity token response did not contain an access token.'
    }

    return $AccessToken
}

function Get-PagedMonitorValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InitialUri,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $Values = [System.Collections.Generic.List[object]]::new()
    $NextUri = $InitialUri
    $Headers = @{ Authorization = "Bearer $AccessToken" }

    while (-not [string]::IsNullOrWhiteSpace($NextUri)) {
        $Response = Invoke-MonitorRequest -Method GET -Uri $NextUri -Headers $Headers
        Confirm-MonitorResponse -Response $Response -ExpectedStatusCode 200 -Operation $Operation
        $Page = $Response.Content | ConvertFrom-Json

        foreach ($Value in @(Get-MonitorProperty -InputObject $Page -Name 'value')) {
            if ($null -ne $Value) {
                $Values.Add($Value)
            }
        }

        $NextUri = Get-MonitorProperty -InputObject $Page -Name 'nextLink'
    }

    return $Values.ToArray()
}

function Get-SubscriptionVault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    $Uri = 'https://management.azure.com/subscriptions/{0}/providers/Microsoft.KeyVault/vaults?api-version=2024-11-01' -f (
        [Uri]::EscapeDataString($SubscriptionId)
    )

    return Get-PagedMonitorValue `
        -InitialUri $Uri `
        -AccessToken $AccessToken `
        -Operation "Key Vault discovery for subscription $SubscriptionId"
}

function Get-KeyVaultMetadataItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VaultUri,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Certificate', 'Secret')]
        [string]$ObjectType,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    $CollectionName = if ($ObjectType -eq 'Secret') { 'secrets' } else { 'certificates' }
    $Uri = '{0}/{1}?api-version=7.4&maxresults=25' -f $VaultUri.TrimEnd('/'), $CollectionName

    return Get-PagedMonitorValue `
        -InitialUri $Uri `
        -AccessToken $AccessToken `
        -Operation "$ObjectType metadata scan for $VaultUri"
}

function ConvertTo-MonitorItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Item,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$VaultName,

        [Parameter(Mandatory = $true)]
        [string]$VaultResourceId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Certificate', 'Secret')]
        [string]$ObjectType
    )

    $Identifier = [string](Get-MonitorProperty -InputObject $Item -Name 'id')
    if ([string]::IsNullOrWhiteSpace($Identifier)) {
        throw "$ObjectType metadata from vault $VaultName did not contain an identifier."
    }

    $Attributes = Get-MonitorProperty -InputObject $Item -Name 'attributes'
    $UpdatedAtEpoch = Get-MonitorProperty -InputObject $Attributes -Name 'updated'
    $Enabled = Get-MonitorProperty -InputObject $Attributes -Name 'enabled'
    $ExpiresAtEpoch = Get-MonitorProperty -InputObject $Attributes -Name 'exp'
    $NotBeforeEpoch = Get-MonitorProperty -InputObject $Attributes -Name 'nbf'
    $Thumbprint = Get-MonitorProperty -InputObject $Item -Name 'x5t'
    $PathSegments = ([Uri]$Identifier).AbsolutePath.Trim('/').Split('/')
    $ObjectName = [Uri]::UnescapeDataString($PathSegments[-1])
    $Fingerprint = @(
        [string]$UpdatedAtEpoch
        [string]$Enabled
        [string]$ExpiresAtEpoch
        [string]$NotBeforeEpoch
        [string]$Thumbprint
    ) -join '|'

    return [ordered]@{
        enabled          = $Enabled
        expiresAtEpoch   = $ExpiresAtEpoch
        fingerprint      = $Fingerprint
        identifier       = $Identifier
        name             = $ObjectName
        objectType       = $ObjectType
        subscriptionId   = $SubscriptionId
        thumbprint       = $Thumbprint
        updatedAtEpoch   = $UpdatedAtEpoch
        vaultName        = $VaultName
        vaultResourceId  = $VaultResourceId
    }
}

function Get-EmptyMonitorState {
    [CmdletBinding()]
    param()

    return [ordered]@{
        schemaVersion  = 1
        generatedAtUtc = $null
        items          = @{}
    }
}

function Read-MonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlobUri,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken
    )

    $Headers = @{
        Authorization  = "Bearer $AccessToken"
        'x-ms-date'     = [DateTime]::UtcNow.ToString('R')
        'x-ms-version'  = '2023-11-03'
    }
    $Response = Invoke-MonitorRequest -Method GET -Uri $BlobUri -Headers $Headers

    if ([int]$Response.StatusCode -eq 404) {
        return [pscustomobject]@{
            ETag   = $null
            Exists = $false
            State  = Get-EmptyMonitorState
        }
    }

    Confirm-MonitorResponse -Response $Response -ExpectedStatusCode 200 -Operation 'Monitor state read'
    $State = $Response.Content | ConvertFrom-Json -AsHashtable

    if ((Get-MonitorProperty -InputObject $State -Name 'schemaVersion') -ne 1 -or
        $null -eq (Get-MonitorProperty -InputObject $State -Name 'items')) {
        throw 'The monitor state blob has an unsupported or invalid schema.'
    }

    return [pscustomobject]@{
        ETag   = Get-MonitorHeader -Response $Response -Name 'ETag'
        Exists = $true
        State  = $State
    }
}

function Write-MonitorState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BlobUri,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$State,

        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [string]$ETag
    )

    $State.generatedAtUtc = [DateTime]::UtcNow.ToString('O')
    $Body = $State | ConvertTo-Json -Depth 8 -Compress
    $Headers = @{
        Authorization     = "Bearer $AccessToken"
        'x-ms-blob-type'  = 'BlockBlob'
        'x-ms-date'       = [DateTime]::UtcNow.ToString('R')
        'x-ms-version'    = '2023-11-03'
    }

    if ([string]::IsNullOrWhiteSpace($ETag)) {
        $Headers['If-None-Match'] = '*'
    }
    else {
        $Headers['If-Match'] = $ETag
    }

    $Response = Invoke-MonitorRequest `
        -Method PUT `
        -Uri $BlobUri `
        -Headers $Headers `
        -Body $Body `
        -ContentType 'application/json; charset=utf-8'
    Confirm-MonitorResponse -Response $Response -ExpectedStatusCode 201 -Operation 'Monitor state write'
}

function Copy-SubscriptionMonitorItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$PreviousItems,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$CurrentItems,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId
    )

    foreach ($Key in $PreviousItems.Keys) {
        $Item = $PreviousItems[$Key]
        if ((Get-MonitorProperty -InputObject $Item -Name 'subscriptionId') -eq $SubscriptionId) {
            $CurrentItems[$Key] = $Item
        }
    }
}

function Copy-VaultTypeMonitorItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$PreviousItems,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$CurrentItems,

        [Parameter(Mandatory = $true)]
        [string]$VaultResourceId,

        [Parameter(Mandatory = $true)]
        [string]$ObjectType
    )

    foreach ($Key in $PreviousItems.Keys) {
        $Item = $PreviousItems[$Key]
        if ((Get-MonitorProperty -InputObject $Item -Name 'vaultResourceId') -eq $VaultResourceId -and
            (Get-MonitorProperty -InputObject $Item -Name 'objectType') -eq $ObjectType) {
            $CurrentItems[$Key] = $Item
        }
    }
}

function Compare-MonitorItem {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$PreviousItems,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$CurrentItems
    )

    $Changes = [System.Collections.Generic.List[object]]::new()

    foreach ($Key in $CurrentItems.Keys) {
        if (-not $PreviousItems.Contains($Key)) {
            continue
        }

        $PreviousItem = $PreviousItems[$Key]
        $CurrentItem = $CurrentItems[$Key]
        $PreviousFingerprint = Get-MonitorProperty -InputObject $PreviousItem -Name 'fingerprint'
        $CurrentFingerprint = Get-MonitorProperty -InputObject $CurrentItem -Name 'fingerprint'

        if ($PreviousFingerprint -ne $CurrentFingerprint) {
            $Changes.Add([pscustomobject]@{
                CurrentUpdatedAtEpoch  = Get-MonitorProperty -InputObject $CurrentItem -Name 'updatedAtEpoch'
                Name                   = Get-MonitorProperty -InputObject $CurrentItem -Name 'name'
                ObjectType             = Get-MonitorProperty -InputObject $CurrentItem -Name 'objectType'
                PreviousUpdatedAtEpoch = Get-MonitorProperty -InputObject $PreviousItem -Name 'updatedAtEpoch'
                SubscriptionId         = Get-MonitorProperty -InputObject $CurrentItem -Name 'subscriptionId'
                VaultName              = Get-MonitorProperty -InputObject $CurrentItem -Name 'vaultName'
            })
        }
    }

    return $Changes.ToArray()
}

function Get-MonitorUtcTimestamp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$EpochSeconds
    )

    if ($null -eq $EpochSeconds -or [string]::IsNullOrWhiteSpace([string]$EpochSeconds)) {
        return 'Unknown'
    }

    return [DateTimeOffset]::FromUnixTimeSeconds([long]$EpochSeconds).UtcDateTime.ToString('u')
}

function ConvertTo-MonitorEmailContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Changes,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Failures,

        [Parameter(Mandatory = $true)]
        [int]$VaultCount,

        [Parameter(Mandatory = $true)]
        [bool]$IsFirstRun
    )

    $SubjectParts = [System.Collections.Generic.List[string]]::new()
    if ($Changes.Count -gt 0) {
        $SubjectParts.Add("$($Changes.Count) change(s)")
    }
    if ($Failures.Count -gt 0) {
        $SubjectParts.Add("$($Failures.Count) scan failure(s)")
    }
    $Subject = 'Key Vault monitor: {0}' -f ($SubjectParts -join ', ')

    $PlainText = [System.Text.StringBuilder]::new()
    [void]$PlainText.AppendLine('Azure Key Vault change monitor')
    [void]$PlainText.AppendLine("Vaults discovered: $VaultCount")
    [void]$PlainText.AppendLine("Changes detected: $($Changes.Count)")
    [void]$PlainText.AppendLine("Scan failures: $($Failures.Count)")
    if ($IsFirstRun) {
        [void]$PlainText.AppendLine('This run established the initial baseline; new items were not reported as changes.')
    }

    if ($Changes.Count -gt 0) {
        [void]$PlainText.AppendLine()
        [void]$PlainText.AppendLine('Changes')
        foreach ($Change in $Changes) {
            $PreviousTime = Get-MonitorUtcTimestamp -EpochSeconds $Change.PreviousUpdatedAtEpoch
            $CurrentTime = Get-MonitorUtcTimestamp -EpochSeconds $Change.CurrentUpdatedAtEpoch
            [void]$PlainText.AppendLine(
                "- $($Change.ObjectType) $($Change.VaultName)/$($Change.Name): $PreviousTime -> $CurrentTime"
            )
        }
    }

    if ($Failures.Count -gt 0) {
        [void]$PlainText.AppendLine()
        [void]$PlainText.AppendLine('Scan failures')
        foreach ($Failure in $Failures) {
            [void]$PlainText.AppendLine("- $($Failure.Scope): $($Failure.Message)")
        }
    }

    $Encode = [System.Net.WebUtility]::HtmlEncode
    $Html = [System.Text.StringBuilder]::new()
    [void]$Html.Append('<html><body style="font-family:Segoe UI,Arial,sans-serif;color:#242424">')
    [void]$Html.Append('<h2>Azure Key Vault change monitor</h2>')
    [void]$Html.Append("<p>Vaults discovered: $VaultCount<br>")
    [void]$Html.Append("Changes detected: $($Changes.Count)<br>")
    [void]$Html.Append("Scan failures: $($Failures.Count)</p>")
    if ($IsFirstRun) {
        [void]$Html.Append('<p>This run established the initial baseline; new items were not reported as changes.</p>')
    }

    if ($Changes.Count -gt 0) {
        [void]$Html.Append('<h3>Changes</h3><table style="border-collapse:collapse">')
        [void]$Html.Append('<tr><th>Subscription</th><th>Vault</th><th>Type</th><th>Name</th><th>Previous update</th><th>Current update</th></tr>')
        foreach ($Change in $Changes) {
            $Cells = @(
                $Change.SubscriptionId
                $Change.VaultName
                $Change.ObjectType
                $Change.Name
                (Get-MonitorUtcTimestamp -EpochSeconds $Change.PreviousUpdatedAtEpoch)
                (Get-MonitorUtcTimestamp -EpochSeconds $Change.CurrentUpdatedAtEpoch)
            )
            [void]$Html.Append('<tr>')
            foreach ($Cell in $Cells) {
                [void]$Html.Append('<td style="border:1px solid #d1d1d1;padding:6px">')
                [void]$Html.Append($Encode.Invoke([string]$Cell))
                [void]$Html.Append('</td>')
            }
            [void]$Html.Append('</tr>')
        }
        [void]$Html.Append('</table>')
    }

    if ($Failures.Count -gt 0) {
        [void]$Html.Append('<h3>Scan failures</h3><ul>')
        foreach ($Failure in $Failures) {
            [void]$Html.Append('<li>')
            [void]$Html.Append($Encode.Invoke("$($Failure.Scope): $($Failure.Message)"))
            [void]$Html.Append('</li>')
        }
        [void]$Html.Append('</ul>')
    }
    [void]$Html.Append('</body></html>')

    return [pscustomobject]@{
        Html      = $Html.ToString()
        PlainText = $PlainText.ToString()
        Subject   = $Subject
    }
}

function Send-MonitorEmail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommunicationEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [Parameter(Mandatory = $true)]
        [string]$SenderAddress,

        [Parameter(Mandatory = $true)]
        [string]$RecipientAddress,

        [Parameter(Mandatory = $true)]
        [object]$Content
    )

    $OperationId = [Guid]::NewGuid().ToString()
    $Uri = '{0}/emails:send?api-version=2023-03-31' -f $CommunicationEndpoint.TrimEnd('/')
    $Headers = @{
        Authorization            = "Bearer $AccessToken"
        'Operation-Id'           = $OperationId
        'x-ms-client-request-id' = [Guid]::NewGuid().ToString()
    }
    $Body = @{
        content = @{
            html      = $Content.Html
            plainText = $Content.PlainText
            subject   = $Content.Subject
        }
        recipients = @{
            to = @(
                @{ address = $RecipientAddress }
            )
        }
        senderAddress = $SenderAddress
    } | ConvertTo-Json -Depth 8 -Compress

    $Response = Invoke-MonitorRequest -Method POST -Uri $Uri -Headers $Headers -Body $Body
    Confirm-MonitorResponse -Response $Response -ExpectedStatusCode 202 -Operation 'Email submission'

    return $OperationId
}

function Invoke-KeyVaultChangeMonitor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommunicationEndpoint,

        [Parameter(Mandatory = $true)]
        [string]$MonitoredSubscriptionIdsJson,

        [Parameter(Mandatory = $true)]
        [string]$NotificationRecipient,

        [Parameter(Mandatory = $true)]
        [string]$SenderAddress,

        [Parameter(Mandatory = $true)]
        [string]$StateBlobName,

        [Parameter(Mandatory = $true)]
        [string]$StateContainerName,

        [Parameter(Mandatory = $true)]
        [string]$StateStorageAccountName
    )

    $SubscriptionIds = @($MonitoredSubscriptionIdsJson | ConvertFrom-Json)
    if ($SubscriptionIds.Count -eq 0) {
        throw 'At least one monitored subscription ID is required.'
    }

    $ManagementToken = Get-ManagedIdentityToken -Resource 'https://management.azure.com/'
    $KeyVaultToken = Get-ManagedIdentityToken -Resource 'https://vault.azure.net'
    $StorageToken = Get-ManagedIdentityToken -Resource 'https://storage.azure.com/'
    $CommunicationToken = Get-ManagedIdentityToken -Resource 'https://communication.azure.com/'
    $BlobUri = 'https://{0}.blob.core.windows.net/{1}/{2}' -f (
        $StateStorageAccountName,
        [Uri]::EscapeDataString($StateContainerName),
        [Uri]::EscapeDataString($StateBlobName)
    )
    $StateResult = Read-MonitorState -BlobUri $BlobUri -AccessToken $StorageToken
    $PreviousItems = Get-MonitorProperty -InputObject $StateResult.State -Name 'items'
    $CurrentItems = @{}
    $Failures = [System.Collections.Generic.List[object]]::new()
    $VaultCount = 0

    foreach ($SubscriptionId in $SubscriptionIds) {
        try {
            $Vaults = @(Get-SubscriptionVault -SubscriptionId $SubscriptionId -AccessToken $ManagementToken)
            $VaultCount += $Vaults.Count
        }
        catch {
            $Failures.Add([pscustomobject]@{
                Message = $_.Exception.Message
                Scope   = "Subscription $SubscriptionId"
            })
            Copy-SubscriptionMonitorItem `
                -PreviousItems $PreviousItems `
                -CurrentItems $CurrentItems `
                -SubscriptionId $SubscriptionId
            continue
        }

        foreach ($Vault in $Vaults) {
            $VaultName = [string](Get-MonitorProperty -InputObject $Vault -Name 'name')
            $VaultResourceId = [string](Get-MonitorProperty -InputObject $Vault -Name 'id')
            $VaultProperties = Get-MonitorProperty -InputObject $Vault -Name 'properties'
            $VaultUri = [string](Get-MonitorProperty -InputObject $VaultProperties -Name 'vaultUri')
            if ([string]::IsNullOrWhiteSpace($VaultUri)) {
                $VaultUri = "https://$VaultName.vault.azure.net"
            }

            foreach ($ObjectType in @('Secret', 'Certificate')) {
                try {
                    $MetadataItems = @(Get-KeyVaultMetadataItem `
                        -VaultUri $VaultUri `
                        -ObjectType $ObjectType `
                        -AccessToken $KeyVaultToken)

                    foreach ($MetadataItem in $MetadataItems) {
                        $MonitorItem = ConvertTo-MonitorItem `
                            -Item $MetadataItem `
                            -SubscriptionId $SubscriptionId `
                            -VaultName $VaultName `
                            -VaultResourceId $VaultResourceId `
                            -ObjectType $ObjectType
                        $Key = ([string]$MonitorItem.identifier).ToLowerInvariant()
                        $CurrentItems[$Key] = $MonitorItem
                    }
                }
                catch {
                    $Failures.Add([pscustomobject]@{
                        Message = $_.Exception.Message
                        Scope   = "$ObjectType metadata in vault $VaultName"
                    })
                    Copy-VaultTypeMonitorItem `
                        -PreviousItems $PreviousItems `
                        -CurrentItems $CurrentItems `
                        -VaultResourceId $VaultResourceId `
                        -ObjectType $ObjectType
                }
            }
        }
    }

    $CurrentState = [ordered]@{
        schemaVersion  = 1
        generatedAtUtc = $null
        items          = $CurrentItems
    }
    # Wrap the whole conditional in @() so an empty result stays an array instead of unrolling to $null.
    $Changes = @(
        if ($StateResult.Exists) {
            Compare-MonitorItem -PreviousItems $PreviousItems -CurrentItems $CurrentItems
        }
    )

    $EmailOperationId = $null
    if ($Changes.Count -gt 0) {
        $EmailContent = ConvertTo-MonitorEmailContent `
            -Changes $Changes `
            -Failures $Failures.ToArray() `
            -VaultCount $VaultCount `
            -IsFirstRun (-not $StateResult.Exists)
        $EmailOperationId = Send-MonitorEmail `
            -CommunicationEndpoint $CommunicationEndpoint `
            -AccessToken $CommunicationToken `
            -SenderAddress $SenderAddress `
            -RecipientAddress $NotificationRecipient `
            -Content $EmailContent
    }

    Write-MonitorState `
        -BlobUri $BlobUri `
        -AccessToken $StorageToken `
        -State $CurrentState `
        -ETag $StateResult.ETag

    return [pscustomobject]@{
        Changes          = $Changes.Count
        EmailOperationId = $EmailOperationId
        Failures         = $Failures.Count
        Items            = $CurrentItems.Count
        Vaults           = $VaultCount
    }
}

function Get-MonitorConfigurationValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Value
    )

    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }

    # Fall back to the Automation variable written at deployment time.
    return Get-AutomationVariable -Name "$script:ConfigurationVariablePrefix$Name"
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-KeyVaultChangeMonitor `
        -CommunicationEndpoint (Get-MonitorConfigurationValue -Name 'CommunicationEndpoint' -Value $CommunicationEndpoint) `
        -MonitoredSubscriptionIdsJson (Get-MonitorConfigurationValue -Name 'MonitoredSubscriptionIdsJson' -Value $MonitoredSubscriptionIdsJson) `
        -NotificationRecipient (Get-MonitorConfigurationValue -Name 'NotificationRecipient' -Value $NotificationRecipient) `
        -SenderAddress (Get-MonitorConfigurationValue -Name 'SenderAddress' -Value $SenderAddress) `
        -StateBlobName (Get-MonitorConfigurationValue -Name 'StateBlobName' -Value $StateBlobName) `
        -StateContainerName (Get-MonitorConfigurationValue -Name 'StateContainerName' -Value $StateContainerName) `
        -StateStorageAccountName (Get-MonitorConfigurationValue -Name 'StateStorageAccountName' -Value $StateStorageAccountName)
}