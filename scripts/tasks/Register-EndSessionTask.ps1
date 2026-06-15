#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NextGpuScheduledTaskCommon.ps1')

$repoRoot = Get-NextGpuRepoRoot
$endSessionScript = Join-Path $repoRoot 'endSession.ps1'
if (-not (Test-Path -LiteralPath $endSessionScript)) {
    $endSessionScript = 'C:\Program Files\Sunshine\scripts\endSession.ps1'
}

$endSessionAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"$endSessionScript`""

$cimTriggerClass = Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskEventTrigger'
$endSessionTrigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly
$endSessionTrigger.Subscription = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">*[System[Provider[@Name='LogoffManager'] and EventID=2002]]</Select>
  </Query>
</QueryList>
"@

$endSessionPrincipal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$endSessionSettings = New-ScheduledTaskSettingsSet `
    -Compatibility Win8 `
    -AllowStartIfOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

$existingEndSession = Get-ScheduledTask -TaskName 'EndSession' -ErrorAction SilentlyContinue
if ($existingEndSession) {
    Unregister-ScheduledTask -TaskName 'EndSession' -Confirm:$false
}

Register-ScheduledTask `
    -TaskName 'EndSession' `
    -Action $endSessionAction `
    -Trigger $endSessionTrigger `
    -Principal $endSessionPrincipal `
    -Settings $endSessionSettings `
    -Force | Out-Null
Write-Host '[*] Registered scheduled task: EndSession'

if (-not [System.Diagnostics.EventLog]::SourceExists('LogoffManager')) {
    New-EventLog -LogName 'Application' -Source 'LogoffManager'
}
