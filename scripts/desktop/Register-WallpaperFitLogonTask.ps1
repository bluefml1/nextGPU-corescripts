#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Register nextGPU-WallpaperFitLogon — keeps desktop wallpaper on Fit (full image) after every logon.
#>
[CmdletBinding()]
param(
    [string]$ApplyScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ApplyScriptPath)) {
    $ApplyScriptPath = Join-Path $PSScriptRoot 'Apply-WallpaperFit-Logon.ps1'
}
if (-not (Test-Path -LiteralPath $ApplyScriptPath)) {
    throw "Apply script not found: $ApplyScriptPath"
}

$taskName = 'nextGPU-WallpaperFitLogon'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ApplyScriptPath
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
# Immediate + delayed: VDD/display may not be ready at first logon on GPU hosts.
$triggerNow = New-ScheduledTaskTrigger -AtLogOn
$triggerDelayed = New-ScheduledTaskTrigger -AtLogOn
try {
    $triggerDelayed.Delay = 'PT90S'
} catch {
    Write-Warning 'Could not set 90s logon delay on wallpaper task; only immediate logon trigger registered.'
    $triggerDelayed = $null
}
$triggers = @($triggerNow)
if ($triggerDelayed) { $triggers += $triggerDelayed }
$principal = New-ScheduledTaskPrincipal -GroupId 'Users' -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "[*] Registered scheduled task: $taskName (at logon + 90s delay for display ready)."
