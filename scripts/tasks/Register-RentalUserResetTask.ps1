#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'

# RentalUserReset: startSession.ps1 fires LogoffManager 2003 when a new rental finds a stale
# nextGPU profile/session; resetRentalUser.ps1 recreates nextGPU and signs it back in.
$resetScript = 'C:\Program Files\Sunshine\scripts\resetRentalUser.ps1'

$resetAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$resetScript`""

$cimTriggerClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
$resetTrigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly
$resetTrigger.Subscription = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">*[System[Provider[@Name='LogoffManager'] and EventID=2003]]</Select>
  </Query>
</QueryList>
"@

$resetPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$resetSettings = New-ScheduledTaskSettingsSet `
    -Compatibility Win8 `
    -AllowStartIfOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
    -MultipleInstances IgnoreNew

$existing = Get-ScheduledTask -TaskName 'RentalUserReset' -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName 'RentalUserReset' -Confirm:$false
}

Register-ScheduledTask `
    -TaskName 'RentalUserReset' `
    -Action $resetAction `
    -Trigger $resetTrigger `
    -Principal $resetPrincipal `
    -Settings $resetSettings `
    -Force | Out-Null
Write-Host '[*] Registered scheduled task: RentalUserReset'

if (-not [System.Diagnostics.EventLog]::SourceExists('LogoffManager')) {
    New-EventLog -LogName 'Application' -Source 'LogoffManager'
}

# The reset signs in a brand-new profile; skipping the first-logon animation keeps it within the 2-minute budget.
$policyPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
if (-not (Test-Path -LiteralPath $policyPath)) {
    New-Item -Path $policyPath -Force | Out-Null
}
Set-ItemProperty -Path $policyPath -Name 'EnableFirstLogonAnimation' -Value 0 -Type DWord -Force
Write-Host '[*] EnableFirstLogonAnimation=0'
