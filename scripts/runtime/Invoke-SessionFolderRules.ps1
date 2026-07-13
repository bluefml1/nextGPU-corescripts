#Requires -Version 5.1
<#
.SYNOPSIS
    Run session folder rules for logoff (primary) or logon (verify fallback).
#>
[CmdletBinding()]
param(
    [ValidateSet('Logoff', 'Logon')]
    [string]$Phase = 'Logoff',
    [switch]$Quiet,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SessionFolderRules-Common.ps1')

try {
    $stats = Invoke-SessionFolderRulesPhase -Phase $Phase -WhatIf:$WhatIf
    if (-not $Quiet) {
        Write-Host "Session folder rules ($Phase): ran=$($stats.Ran) skipped=$($stats.Skipped) failed=$($stats.Failed)"
    }
    if ($stats.Failed -gt 0) {
        exit 1
    }
    exit 0
}
catch {
    Write-SessionFolderRulesLog $_.Exception.Message -Level ERROR
    if (-not $Quiet) {
        Write-Error $_.Exception.Message
    }
    exit 1
}
