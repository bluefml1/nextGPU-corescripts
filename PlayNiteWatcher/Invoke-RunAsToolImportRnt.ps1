#Requires -Version 5.1
<#
.SYNOPSIS
    Import a RunAsTool .rnt backup via documented CLI.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RntPath,
    [string]$RunAsToolExe = "",
    [string]$AdminUser = "NextGPU-Admin",
    [securestring]$AdminPassword,
    [switch]$ResetList,
    [string]$RepoRoot = ""
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot "Playnite-Common.ps1")
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
}

Invoke-RunAsToolRntImport `
    -RntPath $RntPath `
    -RunAsToolExe $RunAsToolExe `
    -AdminUser $AdminUser `
    -AdminPassword $AdminPassword `
    -ResetList:$ResetList.IsPresent `
    -RepoRoot $RepoRoot `
    -LogAction { param($m, $l = 'INFO') Write-Host "[$l] $m" }

Write-Host "RunAsTool import completed: $RntPath"
