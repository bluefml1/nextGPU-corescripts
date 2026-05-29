$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"Z:\launchGame.ps1`""

$cimTriggerClass = Get-CimClass -Namespace "Root/Microsoft/Windows/TaskScheduler" -ClassName "MSFT_TaskLogonTrigger"
$trigger = New-CimInstance -CimClass $cimTriggerClass -ClientOnly
$trigger.UserId = $null
$trigger.Enabled = $true

# Corrected: Remove -LogonType ServiceAccount
$principal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -Compatibility Win8 -AllowStartIfOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName "auto game launch" -Action $action -Trigger $trigger -Principal $principal -Settings $settings