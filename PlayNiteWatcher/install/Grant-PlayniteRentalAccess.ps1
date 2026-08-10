#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Reset Playnite folder ACL to data-volume inherit (Users RX). Install shim.
#>
[CmdletBinding()]
param(
    [string]$InstallDir = ""
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$bootstrapCommon = Join-Path $scriptRoot "..\Playnite-Common.ps1"
if (-not (Test-Path -LiteralPath $bootstrapCommon)) {
    $checkPath = Split-Path -Path $scriptRoot -Parent
    while ($checkPath) {
        $candidate = Join-Path $checkPath "Playnite-Common.ps1"
        if (Test-Path -LiteralPath $candidate) { $bootstrapCommon = $candidate; break }
        $checkPath = Split-Path -Path $checkPath -Parent
    }
}
. $bootstrapCommon

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot (Split-Path -Parent $scriptRoot) -OverrideDir ""
    $InstallDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    throw "Playnite install path is not configured. Run Setup-PlayniteSteam.bat or pass -InstallDir."
}

$logAction = {
    param($Message, $Level)
    switch ($Level) {
        'ERROR' { Write-Host "[ERROR] $Message" -ForegroundColor Red }
        'WARN' { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        default { Write-Host "[*] $Message" }
    }
}

$ok = Reset-PlayniteToVolumeRentalAcl -InstallDir $InstallDir -LogAction $logAction
if (-not $ok) { exit 1 }

Write-Host "[OK] Playnite ACL reset to volume inherit (Users RX): $InstallDir" -ForegroundColor Green
Write-Host "    Register elevated logon: Register-PlayniteLogonTask.ps1" -ForegroundColor Yellow
exit 0
