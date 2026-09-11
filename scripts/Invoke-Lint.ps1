#!/usr/bin/env pwsh
#Requires -Version 7.2

<#
.SYNOPSIS
    Runs PSScriptAnalyzer across the project.
.DESCRIPTION
    Requires PSScriptAnalyzer and fails when any warning or error is reported.
.EXAMPLE
    ./scripts/Invoke-Lint.ps1
.NOTES
    Runs via npm run lint:ps.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $AnalyzerModule = Get-Module -ListAvailable -Name PSScriptAnalyzer |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1

        if ($null -eq $AnalyzerModule) {
            throw 'PSScriptAnalyzer is required. Install it with: Install-Module PSScriptAnalyzer -Scope CurrentUser'
        }

        Import-Module $AnalyzerModule.Path -Force
        $ProjectRoot = Split-Path $PSScriptRoot -Parent
        $Results = @(Invoke-ScriptAnalyzer -Path $ProjectRoot -Recurse -Severity @('Warning', 'Error'))

        if ($Results.Count -gt 0) {
            $Message = $Results |
                Select-Object ScriptName, Line, RuleName, Severity, Message |
                Format-Table -AutoSize |
                Out-String
            throw "PSScriptAnalyzer reported findings:$([Environment]::NewLine)$Message"
        }

        Write-Output 'PSScriptAnalyzer passed without warnings or errors.'
    }
    catch {
        Write-Error -ErrorAction Continue "PowerShell lint failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution
