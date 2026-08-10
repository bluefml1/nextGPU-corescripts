#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Register "auto game launch" â€” at user logon, run Sunshine launchGame.ps1 as SYSTEM.

.DESCRIPTION
    Logon chain (with nextGPU-PlayniteLogon):
      1. nextGPU logs on → Playnite.DesktopApp starts elevated as NextGPU-Admin
         (NextGPU-PlayElevated → NextGPUService).
      2. This task runs as SYSTEM → Sunshine\scripts\launchGame.ps1.
      3. launchGame waits for an Active nextGPU session + Sunshine appid, then
         asks NextGPUService to launch:
           - Steam: elevated steam.exe -applaunch {appId}
           - Epic: elevated Playnite.DesktopApp.exe --start {guid}
           - Desktop: direct .exe (elevated when @ADMIN / runAsAdmin)

    Prefer C:\Program Files\Sunshine\scripts\launchGame.ps1 (deployed by
    Install-SunshineScripts). Falls back to the repo sunshine\launchGame.ps1.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'auto game launch',
    [string]$LaunchGameScript = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = if ($env:NEXTGPU_REPO_ROOT) {
    $env:NEXTGPU_REPO_ROOT
} else {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$candidates = @(
    $LaunchGameScript,
    'C:\Program Files\Sunshine\scripts\launchGame.ps1',
    (Join-Path $repoRoot 'sunshine\launchGame.ps1'),
    'Z:\launchGame.ps1'
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

$scriptPath = $null
foreach ($c in $candidates) {
    if (Test-Path -LiteralPath $c) {
        $scriptPath = [System.IO.Path]::GetFullPath($c)
        break
    }
}

if (-not $scriptPath) {
    throw @"
launchGame.ps1 not found. Tried:
  $($candidates -join "`n  ")
Run Playnite Export / Install-SunshineScripts so the Sunshine scripts folder is populated, then re-run this registrar.
"@
}

Write-Host "[*] launchGame.ps1: $scriptPath"

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$psArg = '-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File "{0}"' -f $scriptPath
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArg

# Fire on any interactive logon; launchGame.ps1 itself exits 0 unless nextGPU is Active + appid present.
$cimTriggerClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskLogonTrigger'
$trigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly
$trigger.UserId = $null
$trigger.Enabled = $true

# SYSTEM can always open \\.\pipe\NextGPUControl (service default DACL: SY + BA).
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -Compatibility Win8 `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Force | Out-Null

Enable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null

Write-Host "[*] Registered scheduled task: $TaskName"
Write-Host "    Principal: SYSTEM (Highest) - pipe access to NextGPUService"
Write-Host "    Script:    $scriptPath"
Write-Host "    Pair with: nextGPU-PlayniteLogon (elevated Playnite --startdesktop as NextGPU-Admin)"

