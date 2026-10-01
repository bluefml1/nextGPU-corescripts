#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    One-time admin install of the Garena platform service, then registers
    gxxapphelper as a NextGPUService launch companion of Garena.exe.
.DESCRIPTION
    Runs the client's 'Garena platform service.lnk' installer (or gxxapphelper
    directly if the shortcut is missing), then calls
    Register-GarenaLaunchCompanion.ps1. No SYSTEM boot task is registered:
    NextGPUService starts gxxapphelper as NextGPU-Admin before each elevated
    Garena.exe launch.

    nextGPU (non-admin) never launches the helper directly.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ClientDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GarenaAppHelper-Common.ps1')

function Write-GarenaPlatformLog {
    param([string]$Message)
    Write-Host $Message
    try {
        $logDir = Join-Path $env:ProgramData 'nextGPU\logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
        Add-Content -LiteralPath (Join-Path $logDir 'garena-platform-service.log') -Value $line -Encoding UTF8
    }
    catch { }
}

function Start-GarenaPlatformServiceInstall {
    param(
        [Parameter(Mandatory)][string]$ClientDir,
        [Parameter(Mandatory)][string]$HelperExe
    )

    $clientDir = Resolve-GarenaPathSafe -Path $ClientDir
    if (-not $clientDir) {
        throw "Invalid client directory: $ClientDir"
    }
    $serviceLink = Join-Path $clientDir 'Garena platform service.lnk'
    $started = $false

    if (Test-Path -LiteralPath $serviceLink -PathType Leaf) {
        try {
            Unblock-File -LiteralPath $serviceLink -ErrorAction SilentlyContinue
            Start-Process -FilePath $serviceLink -WorkingDirectory $clientDir -WindowStyle Hidden
            $started = $true
            Write-GarenaPlatformLog "[OK] Launched Garena platform service installer: $serviceLink"
        }
        catch {
            Write-GarenaPlatformLog "[WARN] Platform service .lnk failed: $($_.Exception.Message)"
        }
    }

    if (-not $started -and (Test-Path -LiteralPath $HelperExe)) {
        $workDir = Split-Path -Parent $HelperExe
        Start-Process -FilePath $HelperExe -WorkingDirectory $workDir -WindowStyle Hidden
        $started = $true
        Write-GarenaPlatformLog "[OK] Launched gxxapphelper (admin): $HelperExe"
    }

    if (-not $started) {
        throw 'Could not start Garena platform service or gxxapphelper.'
    }
}

$clientDir = Resolve-GarenaPathSafe -Path $ClientDir
if (-not $clientDir -or -not (Test-Path -LiteralPath $clientDir -PathType Container)) {
    throw "Garena client directory not found: $ClientDir"
}

$helperExe = Get-GarenaAppHelperExePath -SearchClientDir $clientDir -PreferClientSearch
if (-not $helperExe) {
    throw "gxxapphelper.exe not found under: $clientDir (check version subfolder or 'Garena platform service.lnk')."
}
$helperExe = Resolve-GarenaPathSafe -Path $helperExe
if (-not $helperExe) {
    throw "Resolved gxxapphelper path is invalid: $helperExe"
}

Start-GarenaPlatformServiceInstall -ClientDir $clientDir -HelperExe $helperExe

$companionScript = Join-Path $PSScriptRoot 'Register-GarenaLaunchCompanion.ps1'
& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $companionScript -ClientDir $clientDir
if ($LASTEXITCODE -ne 0) {
    throw "Register-GarenaLaunchCompanion.ps1 failed (exit $LASTEXITCODE)."
}

Write-Host ''
Write-Host '[OK] Garena platform service installed (admin one-time).' -ForegroundColor Green
Write-Host "  Helper: $helperExe" -ForegroundColor DarkGray
Write-Host '  NextGPUService starts gxxapphelper as NextGPU-Admin before each elevated Garena.exe launch.' -ForegroundColor DarkGray
