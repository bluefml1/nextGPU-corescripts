#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NextGpuScheduledTaskCommon.ps1')

$repoRoot = Get-NextGpuRepoRoot
$recoverScript = Join-Path $repoRoot 'scripts\runtime\Recover-NextGpuEndSessionAtStartup.ps1'
if (-not (Test-Path -LiteralPath $recoverScript)) {
    throw "Recovery script not found: $recoverScript"
}

$taskName = 'nextGPU-EndSessionRecoveryStartup'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$recoverScript`""

$trigger = New-ScheduledTaskTrigger -AtStartup
$trigger.Delay = 'PT20S'

$principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -Compatibility Win8 `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew

$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'AtStartup: EndSession profile recovery when pending flag exists; always publishes updateStatus online after recovery or on normal boot (PT20S).' `
    -Force | Out-Null

Write-Host "[*] Registered scheduled task: $taskName"
