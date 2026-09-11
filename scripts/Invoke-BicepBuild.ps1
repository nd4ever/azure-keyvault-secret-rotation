#!/usr/bin/env pwsh
#Requires -Version 7.2

<#
.SYNOPSIS
    Compiles the project Bicep files.
.DESCRIPTION
    Compiles the subscription template and sample parameter file, failing on
    Bicep warnings or errors.
.EXAMPLE
    ./scripts/Invoke-BicepBuild.ps1
.NOTES
    Runs via npm run build:bicep.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ($null -eq (Get-Command -Name az -ErrorAction SilentlyContinue)) {
            throw 'Azure CLI with Bicep support is required.'
        }

        $ProjectRoot = Split-Path $PSScriptRoot -Parent
        $TemplateFile = Join-Path $ProjectRoot 'infra/main.bicep'
        $ParameterFile = Join-Path $ProjectRoot 'infra/main.sample.bicepparam'

        $TemplateOutput = & az bicep build --file $TemplateFile --stdout 2>&1
        if ($LASTEXITCODE -ne 0 -or $TemplateOutput -match '(Warning|Error) BCP') {
            throw "Bicep template compilation failed: $($TemplateOutput -join [Environment]::NewLine)"
        }

        $ParameterOutput = & az bicep build-params --file $ParameterFile --stdout 2>&1
        if ($LASTEXITCODE -ne 0 -or $ParameterOutput -match '(Warning|Error) BCP') {
            throw "Bicep parameter compilation failed: $($ParameterOutput -join [Environment]::NewLine)"
        }

        Write-Output 'Bicep compilation passed without diagnostics.'
    }
    catch {
        Write-Error -ErrorAction Continue "Bicep validation failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution
