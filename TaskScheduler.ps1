# Define the action: Run PowerShell with specific arguments
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"C:\Program Files\Sunshine\scripts\endSession.ps1`""

# Define the custom event trigger using CIM instance
$cimTriggerClass = Get-CimClass -Namespace "Root/Microsoft/Windows/TaskScheduler" -ClassName "MSFT_TaskEventTrigger"
$trigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly


$trigger.Subscription = @"
<QueryList>
  <Query Id="0" Path="Application">
    <Select Path="Application">*[System[Provider[@Name='LogoffManager'] and EventID=2002]]</Select>
  </Query>
</QueryList>
"@

# Define the security principal: Run as SYSTEM with highest privileges
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Define the task settings with all required options
$settings = New-ScheduledTaskSettingsSet `
    -Compatibility Win8 `
    -AllowStartIfOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

# Create and register the scheduled task
Register-ScheduledTask `
    -TaskName "EndSession" `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings 

# Create a new custom log & source
New-EventLog -LogName "Application" -Source "LogoffManager"
  