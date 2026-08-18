#Requires -Version 5.1
<#
.SYNOPSIS
    Register nextGPU-SessionFolderRulesLogoff and nextGPU-SessionFolderRulesLogon tasks.

.NOTES
    Logoff task runs as SYSTEM so it can start when nextGPU signs out (InteractiveToken
    cannot run at logoff).

    Many Windows builds omit Task Scheduler "At log off" / LogoffTrigger. On those hosts
    registration uses Security event 4647 (user-initiated logoff for account nextGPU).
#>
[CmdletBinding()]
param(
    [string]$InvokeScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SessionFolderRules-Common.ps1')

$desktopCommon = Join-Path (Split-Path $PSScriptRoot -Parent) 'desktop\NextGpuLogonTask.ps1'
if (-not (Test-Path -LiteralPath $desktopCommon)) {
    throw "Shared helper not found: $desktopCommon"
}
. $desktopCommon

if ([string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
    $InvokeScriptPath = Resolve-InvokeSessionFolderRulesScript
}
if (-not (Test-Path -LiteralPath $InvokeScriptPath)) {
    throw "Invoke-SessionFolderRules.ps1 not found: $InvokeScriptPath"
}

$localUser = Get-LocalUser -Name 'nextGPU' -ErrorAction SilentlyContinue
if (-not $localUser) {
    Write-Warning "Local user 'nextGPU' does not exist yet. Waiting for account / SID mapping..."
}

if (-not (Get-Command Resolve-NextGpuLocalAccountId -ErrorAction SilentlyContinue)) {
    throw "Resolve-NextGpuLocalAccountId not found. Expected $desktopCommon"
}
$userId = Resolve-NextGpuLocalAccountId -UserName 'nextGPU' -WaitSeconds 45
$accountName = 'nextGPU'
Write-Host "[*] Using account for session folder rules tasks: $userId"
$logoffTask = 'nextGPU-SessionFolderRulesLogoff'
$logonTask = 'nextGPU-SessionFolderRulesLogon'
$systemPrincipalId = 'NT AUTHORITY\SYSTEM'

function Remove-SessionFolderRulesTaskIfPresent {
    param([string]$TaskName)
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function New-SessionFolderRulesTaskAction {
    param([string]$Phase)
    $psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Phase {1} -Quiet' -f $InvokeScriptPath, $Phase
    return New-ScheduledTaskAction -Execute $psExe -Argument $psArgs
}

function New-SessionFolderRulesSystemPrincipal {
    return New-ScheduledTaskPrincipal -UserId $systemPrincipalId -LogonType ServiceAccount -RunLevel Highest
}

function New-SessionFolderRulesTaskSettings {
    return New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -Hidden
}

function New-SessionFolderRulesLogoffTriggerFromSessionState {
    param(
        [Parameter(Mandatory)][string]$StateChangeName,
        [Parameter(Mandatory)][string]$UserId
    )

    $stateMap = @{
        ConsoleConnect    = 1
        ConsoleDisconnect = 2
        RemoteConnect     = 3
        RemoteDisconnect  = 4
        SessionLock       = 7
        SessionUnlock     = 8
    }
    if (-not $stateMap.ContainsKey($StateChangeName)) {
        throw "Unknown session state change: $StateChangeName"
    }

    $triggerClass = Get-CimClass -ClassName MSFT_TaskSessionStateChangeTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
    return New-CimInstance -CimClass $triggerClass -ClientOnly -Property @{
        Enabled     = $true
        StateChange = $stateMap[$StateChangeName]
        UserId      = $UserId
    }
}

function Register-SessionFolderRulesLogoffTaskViaXml {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$WatchUserId,
        [Parameter(Mandatory)][object]$Action
    )

    $escapedUser = [System.Security.SecurityElement]::Escape($WatchUserId)
    $escapedCommand = [System.Security.SecurityElement]::Escape($Action.Execute)
    $escapedArgs = [System.Security.SecurityElement]::Escape($Action.Arguments)

    # LogoffTrigger is missing on some Windows builds (UI and XML). Callers must catch failure.
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Run nextGPU session folder rules when the rental user logs off (SYSTEM)</Description>
  </RegistrationInfo>
  <Triggers>
    <LogoffTrigger>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogoffTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT15M</ExecutionTimeLimit>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$escapedCommand</Command>
      <Arguments>$escapedArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $xmlPath = Join-Path $env:TEMP "nextgpu-session-folder-logoff-$([Guid]::NewGuid().ToString('N')).xml"
    try {
        Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode -Force
        Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content -LiteralPath $xmlPath -Raw) -Force | Out-Null
        return $true
    }
    finally {
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

function Register-SessionFolderRulesLogoffTaskViaEvent4647 {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Principal,
        [Parameter(Mandatory)][object]$Settings
    )

    $subscription = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*[System[(EventID=4647)]] and *[EventData[Data[@Name='TargetUserName'] and (Data='$accountName')]]</Select>
  </Query>
</QueryList>
"@

    $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
    $eventTrigger = New-CimInstance -CimClass $triggerClass -ClientOnly -Property @{
        Enabled      = $true
        Subscription = $subscription
    }

    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $eventTrigger `
        -Principal $Principal -Settings $Settings -Force | Out-Null
    return $true
}

function Register-SessionFolderRulesLogoffTask {
    Remove-SessionFolderRulesTaskIfPresent -TaskName $logoffTask
    $action = New-SessionFolderRulesTaskAction -Phase 'Logoff'
    $principal = New-SessionFolderRulesSystemPrincipal
    $settings = New-SessionFolderRulesTaskSettings

    $errors = New-Object System.Collections.Generic.List[string]

    # 1) Native LogoffTrigger (servers / builds that still expose it)
    try {
        if (Register-SessionFolderRulesLogoffTaskViaXml -TaskName $logoffTask -WatchUserId $userId -Action $action) {
            Write-Host "[*] Registered: $logoffTask (XML LogoffTrigger for $userId, runs as SYSTEM)."
            return
        }
    }
    catch {
        [void]$errors.Add("XML LogoffTrigger: $($_.Exception.Message)")
    }

    $triggers = New-Object System.Collections.Generic.List[object]
    $triggerNotes = New-Object System.Collections.Generic.List[string]

    $cmd = Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Parameters.ContainsKey('AtLogOff')) {
        try {
            [void]$triggers.Add((New-ScheduledTaskTrigger -AtLogOff -User $userId))
            [void]$triggerNotes.Add('AtLogOff')
        }
        catch {
            [void]$errors.Add("AtLogOff: $($_.Exception.Message)")
        }
    }

    if ($triggers.Count -eq 0) {
        try {
            $triggerClass = Get-CimClass -ClassName MSFT_TaskLogoffTrigger `
                -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
            [void]$triggers.Add((New-CimInstance -CimClass $triggerClass -ClientOnly -Property @{
                    Enabled = $true
                    UserId  = $userId
                }))
            [void]$triggerNotes.Add('CIM LogoffTrigger')
        }
        catch {
            [void]$errors.Add("CIM LogoffTrigger: $($_.Exception.Message)")
        }
    }

    if ($triggers.Count -gt 0) {
        Register-ScheduledTask -TaskName $logoffTask -Action $action -Trigger $triggers.ToArray() `
            -Principal $principal -Settings $settings -Force | Out-Null
        $triggerSummary = ($triggerNotes -join ', ')
        Write-Host "[*] Registered: $logoffTask ($triggerSummary for $userId, runs as SYSTEM)."
        return
    }

    # 2) Security 4647 — primary path on Windows builds without LogoffTrigger (incl. this host)
    try {
        if (Register-SessionFolderRulesLogoffTaskViaEvent4647 -TaskName $logoffTask -Action $action `
                -Principal $principal -Settings $settings) {
            Write-Host "[*] Registered: $logoffTask (Security event 4647 logoff for $accountName, runs as SYSTEM)."
            Write-Host "[*] Note: Task Scheduler UI has no At log off on this Windows build; event 4647 is the logoff trigger."
            return
        }
    }
    catch {
        [void]$errors.Add("Event 4647: $($_.Exception.Message)")
    }

    # 3) Session disconnect fallback (not the same as Sign out)
    foreach ($stateName in @('RemoteDisconnect', 'ConsoleDisconnect')) {
        try {
            [void]$triggers.Add((New-SessionFolderRulesLogoffTriggerFromSessionState -StateChangeName $stateName -UserId $userId))
            [void]$triggerNotes.Add($stateName)
        }
        catch {
            [void]$errors.Add("${stateName}: $($_.Exception.Message)")
        }
    }

    if ($triggers.Count -eq 0) {
        $detail = if ($errors.Count -gt 0) { $errors -join '; ' } else { 'no trigger API available' }
        throw "No logoff trigger available for session folder rules task. Tried: $detail"
    }

    Register-ScheduledTask -TaskName $logoffTask -Action $action -Trigger $triggers.ToArray() `
        -Principal $principal -Settings $settings -Force | Out-Null
    $triggerSummary = ($triggerNotes -join ', ')
    Write-Host "[*] Registered: $logoffTask ($triggerSummary for $userId, runs as SYSTEM)."
    Write-Warning 'True logoff trigger was unavailable. Using session disconnect; logon fallback still covers incomplete runs.'
}

function Register-SessionFolderRulesLogonTask {
    Remove-SessionFolderRulesTaskIfPresent -TaskName $logonTask
    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Phase Logon -Quiet' -f $InvokeScriptPath
    if (Get-Command Register-NextGpuAtLogonTask -ErrorAction SilentlyContinue) {
        Register-NextGpuAtLogonTask -TaskName $logonTask -Argument $psArgs -RunLevel Highest `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
        Write-Host "[*] Registered: $logonTask (AtLogOn via Register-NextGpuAtLogonTask, Highest)."
        return
    }

    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'BUILTIN\Users' -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)
    Register-ScheduledTask -TaskName $logonTask -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "[*] Registered: $logonTask (AtLogOn, Highest)."
}

Ensure-NextGpuSessionFolders | Out-Null
Register-SessionFolderRulesLogoffTask
Register-SessionFolderRulesLogonTask
Write-Host '[*] Session folder rules tasks registered.'
