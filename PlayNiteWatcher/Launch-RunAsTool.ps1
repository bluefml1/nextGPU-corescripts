#Requires -Version 5.1
<#
.SYNOPSIS
    Auto-download RunAsTool (if missing) and launch it.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot "Playnite-Common.ps1")
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
}

$installArgs = @{
    RepoRoot = $RepoRoot
    Launch   = $true
}
if ($SkipDownload.IsPresent) {
    $installArgs['SkipDownload'] = $true
}

$result = & (Join-Path $scriptRoot "Install-RunAsTool.ps1") @installArgs
Write-Host "RunAsTool: $($result.Path)"
if ($result.Launched) {
    Write-Host "RunAsTool is running."
}

return $result
