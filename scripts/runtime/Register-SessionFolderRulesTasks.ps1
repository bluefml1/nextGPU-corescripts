#Requires -Version 5.1
<#
.SYNOPSIS
    Register nextGPU-SessionFolderRulesLogoff and nextGPU-SessionFolderRulesLogon tasks.
#>
[CmdletBinding()]
param(
    [string]$InvokeScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'SessionFolderRules-Common.ps1')

$desktopCommon = Join-Path (Split-Path $PSScriptRoot -Parent) 'desktop\NextGpuLogonTask.ps1'
if (Test-Path -LiteralPath $desktopCommon) {
    . $desktopCommon
}

if ([string]::IsNullOrWhiteSpace($InvokeScriptPath)) {
    $InvokeScriptPath = Resolve-InvokeSessionFolderRulesScript
}
if (-not (Test-Path -LiteralPath $InvokeScriptPath)) {
    throw "Invoke-SessionFolderRules.ps1 not found: $InvokeScriptPath"
}

$localUser = Get-LocalUser -Name 'nextGPU' -ErrorAction SilentlyContinue
if (-not $localUser) {
    Write-Warning "Local user 'nextGPU' does not exist yet. Registering tasks anyway."
}

$userId = "$env:USERDOMAIN\nextGPU"
$logoffTask = 'nextGPU-SessionFolderRulesLogoff'
$logonTask = 'nextGPU-SessionFolderRulesLogon'

function Remove-SessionFolderRulesTaskIfPresent {
    param([string]$TaskName)
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function New-SessionFolderRulesTaskAction {
    param([string]$Phase)
    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Phase {1} -Quiet' -f $InvokeScriptPath, $Phase
    return New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
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
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][object]$Action,
        [Parameter(Mandatory)][object]$Settings
    )

    $escapedUser = [System.Security.SecurityElement]::Escape($UserId)
    $escapedCommand = [System.Security.SecurityElement]::Escape($Action.Execute)
    $escapedArgs = [System.Security.SecurityElement]::Escape($Action.Arguments)

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Run nextGPU session folder rules when the rental user logs off</Description>
  </RegistrationInfo>
  <Triggers>
    <LogoffTrigger>
      <Enabled>true</Enabled>
      <UserId>$escapedUser</UserId>
    </LogoffTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$escapedUser</UserId>
      <LogonType>InteractiveToken</LogonType>
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

function Register-SessionFolderRulesLogoffTask {
    Remove-SessionFolderRulesTaskIfPresent -TaskName $logoffTask
    $action = New-SessionFolderRulesTaskAction -Phase 'Logoff'
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15)

    $triggers = New-Object System.Collections.Generic.List[object]
    $triggerNotes = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]

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

    if ($triggers.Count -eq 0) {
        try {
            if (Register-SessionFolderRulesLogoffTaskViaXml -TaskName $logoffTask -UserId $userId -Action $action -Settings $settings) {
                Write-Host "[*] Registered: $logoffTask (XML LogoffTrigger for $userId, Highest)."
                return
            }
        }
        catch {
            [void]$errors.Add("XML LogoffTrigger: $($_.Exception.Message)")
        }
    }

    if ($triggers.Count -eq 0) {
        foreach ($stateName in @('RemoteDisconnect', 'ConsoleDisconnect')) {
            try {
                [void]$triggers.Add((New-SessionFolderRulesLogoffTriggerFromSessionState -StateChangeName $stateName -UserId $userId))
                [void]$triggerNotes.Add($stateName)
            }
            catch {
                [void]$errors.Add("${stateName}: $($_.Exception.Message)")
            }
        }
    }

    if ($triggers.Count -eq 0) {
        $detail = if ($errors.Count -gt 0) { $errors -join '; ' } else { 'no trigger API available' }
        throw "No logoff trigger available for session folder rules task. Tried: $detail"
    }

    Register-ScheduledTask -TaskName $logoffTask -Action $action -Trigger $triggers.ToArray() `
        -Principal $principal -Settings $settings -Force | Out-Null
    $triggerSummary = ($triggerNotes -join ', ')
    Write-Host "[*] Registered: $logoffTask ($triggerSummary for $userId, Highest)."
    if ($triggerNotes -notcontains 'AtLogOff' -and $triggerNotes -notcontains 'CIM LogoffTrigger') {
        Write-Warning 'This Windows build does not expose AtLogOff triggers. Clean session runs on session disconnect; logon fallback still covers incomplete logoff runs.'
    }
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
