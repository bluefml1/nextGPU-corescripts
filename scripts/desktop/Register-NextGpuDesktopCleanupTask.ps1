#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Register nextGPU-DesktopCleanupLogon — clears nextGPU Desktop at every logon.
#>
[CmdletBinding()]
param(
    [string]$ClearScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ClearScriptPath)) {
    $ClearScriptPath = Join-Path $PSScriptRoot 'Clear-NextGpuUserDesktop.ps1'
}
if (-not (Test-Path -LiteralPath $ClearScriptPath)) {
    throw "Clear script not found: $ClearScriptPath"
}

$localUser = Get-LocalUser -Name 'nextGPU' -ErrorAction SilentlyContinue
if (-not $localUser) {
    Write-Warning "Local user 'nextGPU' does not exist yet. Registering task anyway (create user before first rental logon)."
}

$taskName = 'nextGPU-DesktopCleanupLogon'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# Run as nextGPU at logon so Desktop path and permissions match the rental session.
$userId = "$env:USERDOMAIN\nextGPU"
$psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f $ClearScriptPath
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Write-Host "[*] Registered scheduled task: $taskName (clears Desktop when nextGPU logs on)."
