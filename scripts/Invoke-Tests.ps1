#!/usr/bin/env pwsh
#Requires -Version 7.2

<#
.SYNOPSIS
    Runs the project's Pester unit tests.
.DESCRIPTION
    Verifies Pester 5 is available, runs the requested test path, and returns a
    nonzero exit code when any test fails.
.PARAMETER TestPath
    Test file or directory to execute.
.EXAMPLE
    ./scripts/Invoke-Tests.ps1
.NOTES
    Runs via npm run test:ps.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -LiteralPath $_ })]
    [string]$TestPath = (Join-Path $PSScriptRoot '../tests')
)

$ErrorActionPreference = 'Stop'

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $PesterModule = Get-Module -ListAvailable -Name Pester |
            Where-Object { $_.Version.Major -ge 5 } |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1

        if ($null -eq $PesterModule) {
            throw 'Pester 5 or later is required. Install it with: Install-Module Pester -Scope CurrentUser'
        }

        Import-Module $PesterModule.Path -Force
        $Configuration = New-PesterConfiguration
        $Configuration.Run.Path = $TestPath
        $Configuration.Run.PassThru = $true
        $Configuration.Output.Verbosity = 'Detailed'
        $Result = Invoke-Pester -Configuration $Configuration

        if ($Result.FailedCount -gt 0) {
            exit 1
        }
    }
    catch {
        Write-Error -ErrorAction Continue "Pester execution failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution
