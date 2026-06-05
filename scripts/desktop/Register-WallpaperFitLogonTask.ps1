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

. (Join-Path $PSScriptRoot 'NextGpuLogonTask.ps1')

$psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $ApplyScriptPath
# Immediate + delayed: VDD/display may not be ready at first logon on GPU hosts.
$triggerDelayed = New-ScheduledTaskTrigger -AtLogOn
try {
    $triggerDelayed.Delay = 'PT90S'
} catch {
    Write-Warning 'Could not set 90s logon delay on wallpaper task; only immediate logon trigger registered.'
    $triggerDelayed = $null
}
$extraTriggers = @()
if ($triggerDelayed) { $extraTriggers = @($triggerDelayed) }

Register-NextGpuAtLogonTask -TaskName $taskName -Argument $psArgs -ExtraTriggers $extraTriggers `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Write-Host "[*] Registered scheduled task: $taskName (at logon + 90s delay for display ready)."
