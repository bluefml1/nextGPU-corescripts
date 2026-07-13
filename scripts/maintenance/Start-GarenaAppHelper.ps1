#Requires -Version 5.1
<#
.SYNOPSIS
    Resolve or start Garena gxxapphelper.exe (admin / diagnostics only).
.DESCRIPTION
    Renters (nextGPU) must NOT use this — platform helper is installed once by admin
    during Arrange Garena (Install-GarenaPlatformService.ps1).
#>
[CmdletBinding()]
param(
    [string]$ClientDir = '',
    [string]$HelperExePath = '',
    [switch]$ResolveOnly,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GarenaAppHelper-Common.ps1')

function Write-GarenaHelperStatus {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host $Message
    }
}

$helper = Get-GarenaAppHelperExePath -SearchClientDir $ClientDir -PreferredHelperPath $HelperExePath

if ($ResolveOnly) {
    if ($helper) {
        Write-Output $helper
        exit 0
    }
    exit 1
}

if (-not $helper) {
    Write-GarenaHelperStatus '[!] gxxapphelper.exe not found. Run Arrange Garena first.'
    exit 1
}

if (Get-Process -Name 'gxxapphelper' -ErrorAction SilentlyContinue) {
    Write-GarenaHelperStatus '[*] gxxapphelper already running.'
    exit 0
}

$workDir = Split-Path -Parent $helper
try {
    Start-Process -FilePath $helper -WorkingDirectory $workDir -WindowStyle Hidden
    Write-GarenaHelperStatus "[OK] Started gxxapphelper: $helper"
    exit 0
}
catch {
    Write-GarenaHelperStatus "[FAIL] Could not start gxxapphelper: $($_.Exception.Message)"
    exit 1
}
