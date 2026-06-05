#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Install rclone + WinFsp for all users (machine paths). No reboot required.
#>
[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    throw "UserStorageCommon.ps1 not found: $commonPath"
}
. $commonPath

$ok = Ensure-UserStoragePrerequisites
if (-not $ok) {
    if (-not $Quiet) {
        Write-Host '[ERROR] rclone or WinFsp could not be installed for all users.' -ForegroundColor Red
        Write-Host '        Re-run Setup-UserStorage.bat as Administrator.' -ForegroundColor Yellow
    }
    exit 1
}

if (-not $Quiet) {
    Write-Host "[OK] rclone: $(Get-RcloneExeForUserStorage)" -ForegroundColor Green
    $wbin = Get-WinFspBinDirectory
    Write-Host "[OK] WinFsp: $wbin" -ForegroundColor Green
}
exit 0
