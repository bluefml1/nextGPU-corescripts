#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Grant BUILTIN\Users Modify on the portable Playnite install folder (rental ACL repair).
.DESCRIPTION
    Reads PlayniteInstall.path, breaks inherited data-volume rental ACLs on that folder only,
    and grants Modify so nextGPU can run Playnite without write access on sibling game folders.
.EXAMPLE
    .\Grant-PlayniteRentalAccess.ps1
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
    $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $scriptRoot -OverrideDir ""
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

$ok = Grant-PlayniteRentalAccess -InstallDir $InstallDir -LogAction $logAction
if (-not $ok) {
    exit 1
}

Write-Host "[OK] Rental access granted on: $InstallDir" -ForegroundColor Green
exit 0
