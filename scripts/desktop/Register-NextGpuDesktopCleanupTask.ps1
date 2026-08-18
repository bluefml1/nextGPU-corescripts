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

$common = Join-Path $PSScriptRoot 'NextGpuLogonTask.ps1'
if (-not (Test-Path -LiteralPath $common)) {
    throw "Shared helper not found: $common"
}
. $common

if ([string]::IsNullOrWhiteSpace($ClearScriptPath)) {
    $ClearScriptPath = Join-Path $PSScriptRoot 'Clear-NextGpuUserDesktop.ps1'
}
if (-not (Test-Path -LiteralPath $ClearScriptPath)) {
    throw "Clear script not found: $ClearScriptPath"
}

$localUser = Get-LocalUser -Name 'nextGPU' -ErrorAction SilentlyContinue
if (-not $localUser) {
    Write-Warning "Local user 'nextGPU' does not exist yet. Waiting for account / SID mapping..."
}

# Local account for Task Scheduler (COMPUTER\nextGPU or SID-translated NTAccount — not USERDOMAIN)
$userId = Resolve-NextGpuLocalAccountId -UserName 'nextGPU' -WaitSeconds 45
Write-Host "[*] Using account for Desktop cleanup task: $userId"

$taskName = 'nextGPU-DesktopCleanupLogon'
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f $ClearScriptPath
$action = New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}
catch {
    Write-Warning "Register-ScheduledTask failed ($($_.Exception.Message)). Falling back to schtasks..."
    $tr = "`"$psExe`" $psArgs"
    $null = schtasks.exe /Create /TN $taskName /TR $tr /SC ONLOGON /RU $userId /RL LIMITED /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to register $taskName for $userId (ScheduledTasks and schtasks)."
    }
}

Write-Host "[*] Registered scheduled task: $taskName (clears Desktop when nextGPU logs on)."
