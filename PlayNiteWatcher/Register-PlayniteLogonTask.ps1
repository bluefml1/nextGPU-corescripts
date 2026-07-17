#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Register nextGPU-PlayniteLogon — starts Playnite DesktopApp at any user logon.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'nextGPU-PlayniteLogon',
    [string]$PlayniteInstallDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Playnite-Common.ps1')

$watcherRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
$playniteExe = Get-PlayniteDesktopExeFromConfig -RepoRoot $watcherRoot -OverrideDir $PlayniteInstallDir
$playniteRoot = Get-PlayniteInstallRootFromExe -PlayniteExe $playniteExe

$coreRepo = Get-NextGpuCoreRepoRootFromWatcher -WatcherRoot $watcherRoot
$helper = if ($coreRepo) {
    Join-Path $coreRepo 'scripts\desktop\NextGpuLogonTask.ps1'
}
else {
    Join-Path (Split-Path $scriptRoot -Parent) 'scripts\desktop\NextGpuLogonTask.ps1'
}
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Logon task helper not found: $helper"
}
. $helper

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute $playniteExe `
    -Argument '--startdesktop --hidesplashscreen' `
    -WorkingDirectory $playniteRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = Get-NextGpuLogonTaskPrincipal -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
}
catch {
    Write-Warning "Register-ScheduledTask failed for ${TaskName}: $($_.Exception.Message). Trying schtasks..."
    $tr = "`"$playniteExe`" --startdesktop --hidesplashscreen"
    $ok = $false
    foreach ($ru in @('BUILTIN\Users', 'Users')) {
        $null = schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /RU $ru /RL LIMITED /F 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
            break
        }
    }
    if (-not $ok) {
        throw "Failed to register logon task $TaskName (ScheduledTasks and schtasks)."
    }
}

Write-Host "[*] Registered scheduled task: $TaskName"
Write-Host "    Action: $playniteExe --startdesktop --hidesplashscreen"
Write-Host "    Working directory: $playniteRoot"
