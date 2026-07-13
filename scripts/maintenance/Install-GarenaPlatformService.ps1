#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    One-time admin install of Garena platform helper (gxxapphelper) for all users.
.DESCRIPTION
    Runs during Arrange Garena as administrator. Installs/starts the platform
    service and registers a machine startup task (SYSTEM) that launches
    gxxapphelper.exe directly from Z: after reboot.

    nextGPU (non-admin) does NOT launch the helper — only Garena.exe.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ClientDir,
    [string]$BootTaskName = 'nextGPU-GarenaPlatformService',
    [string]$LegacyLogonTaskName = 'nextGPU-GarenaAppHelper'
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

function Remove-GarenaLegacyLogonTask {
    param([string]$TaskName)
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-GarenaPlatformLog "[*] Removed legacy logon task: $TaskName"
    }
}

function Register-GarenaPlatformBootTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$HelperExe
    )

    $helperExe = Resolve-GarenaPathSafe -Path $HelperExe
    if (-not $helperExe) {
        throw "Invalid helper path for boot task: $HelperExe"
    }
    $workDir = Split-Path -Parent $helperExe
    $escapedExe = [System.Security.SecurityElement]::Escape($helperExe)
    $escapedWorkDir = [System.Security.SecurityElement]::Escape($workDir)

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Start Garena gxxapphelper at machine startup (SYSTEM). nextGPU users only open Garena.exe.</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedExe</Command>
      <WorkingDirectory>$escapedWorkDir</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    $xmlPath = Join-Path $env:TEMP "nextgpu-garena-platform-$([Guid]::NewGuid().ToString('N')).xml"
    try {
        Set-Content -LiteralPath $xmlPath -Value $taskXml -Encoding Unicode -Force
        Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content -LiteralPath $xmlPath -Raw) -Force | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }

    Write-GarenaPlatformLog "[OK] Registered startup task: $TaskName -> $helperExe"
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

Save-GarenaAppHelperPath -HelperExePath $helperExe -ClientDir $clientDir
Write-GarenaPlatformLog "[*] Saved helper path to ProgramData and repo maintenance folder"

Remove-GarenaLegacyLogonTask -TaskName $LegacyLogonTaskName
Start-GarenaPlatformServiceInstall -ClientDir $clientDir -HelperExe $helperExe
Register-GarenaPlatformBootTask -TaskName $BootTaskName -HelperExe $helperExe

Write-Host ''
Write-Host '[OK] Garena platform service installed (admin one-time).' -ForegroundColor Green
Write-Host "  Helper: $helperExe" -ForegroundColor DarkGray
Write-Host "  Startup task: $BootTaskName (SYSTEM at boot)" -ForegroundColor DarkGray
Write-Host '  Renters (nextGPU): open Garena.exe only — do not launch gxxapphelper.' -ForegroundColor DarkGray
