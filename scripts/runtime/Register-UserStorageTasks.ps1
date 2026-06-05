#Requires -Version 5.1
<#
.SYNOPSIS
    Register nextGPU-UserStorageMount (logon) and nextGPU-UserStorageUnmount (logoff) for DOMAIN\nextGPU.
#>
[CmdletBinding()]
param(
    [string]$MountScriptPath = '',
    [string]$UnmountScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    throw "UserStorageCommon.ps1 not found: $commonPath"
}
. $commonPath

function Test-ScheduledTaskAtLogOffSupported {
    $cmd = Get-Command New-ScheduledTaskTrigger -ErrorAction SilentlyContinue
    if (-not $cmd) { return $false }
    return $cmd.Parameters.ContainsKey('AtLogOff')
}

function Remove-NextGpuUserStorageTaskIfPresent {
    param([Parameter(Mandatory)][string]$TaskName)
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

function New-NextGpuUserStorageTaskAction {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [ValidateSet('Mount', 'Unmount')]
        [string]$Operation = 'Unmount'
    )
    $extra = if ($Operation -eq 'Mount') { ' -FromScheduledTask' } else { '' }
    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet{1}' -f $ScriptPath, $extra
    return New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
}

function New-NextGpuUserStorageTaskPrincipal {
    return New-ScheduledTaskPrincipal -UserId $script:userId -LogonType Interactive -RunLevel Limited
}

function Get-NextGpuUserStorageUsersGroupTaskPrincipal {
    <#
    .SYNOPSIS
        BUILTIN\Users principal for logon mount task (recreate-safe; inlined — no scripts\desktop dependency).
    #>
    param(
        [ValidateSet('Limited', 'Highest')]
        [string]$RunLevel = 'Limited'
    )
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($def in @(
            @{ Kind = 'GroupId'; Id = 'BUILTIN\Users' }
            @{ Kind = 'GroupId'; Id = 'Users' }
            @{ Kind = 'UserId'; Id = 'S-1-5-32-545'; LogonType = 'Group' }
        )) {
        try {
            if ($def.Kind -eq 'GroupId') {
                return New-ScheduledTaskPrincipal -GroupId $def.Id -RunLevel $RunLevel
            }
            return New-ScheduledTaskPrincipal -UserId $def.Id -LogonType $def.LogonType -RunLevel $RunLevel
        } catch {
            [void]$errors.Add($_.Exception.Message)
        }
    }
    throw "Could not resolve Users-group task principal: $($errors -join '; ')"
}

function Resolve-NextGpuUserStorageMultipleInstancesPolicy {
    param(
        [ValidateSet('IgnoreNew', 'StopExisting', 'Parallel', 'Queue')]
        [string]$Preferred = 'IgnoreNew'
    )
    $cmd = Get-Command New-ScheduledTaskSettingsSet -ErrorAction Stop
    if (-not $cmd.Parameters.ContainsKey('MultipleInstances')) {
        return $null
    }
    $enumType = $cmd.Parameters['MultipleInstances'].ParameterType
    $supported = [System.Enum]::GetNames($enumType)
    if ($Preferred -in $supported) {
        return $Preferred
    }
    # StopExisting is Win11+/newer ScheduledTasks; Queue is the best fallback for remount on reconnect.
    if ($Preferred -eq 'StopExisting' -and 'Queue' -in $supported) {
        Write-Host '[*] MultipleInstances StopExisting not supported on this OS; using Queue for mount task.' -ForegroundColor DarkGray
        return 'Queue'
    }
    if ('IgnoreNew' -in $supported) { return 'IgnoreNew' }
    return $supported[0]
}

function New-NextGpuUserStorageTaskSettings {
    param(
        [ValidateSet('IgnoreNew', 'StopExisting', 'Parallel', 'Queue')]
        [string]$MultipleInstancesPolicy = 'IgnoreNew'
    )
    $params = @{
        AllowStartIfOnBatteries = $true
        DontStopIfGoingOnBatteries = $true
        StartWhenAvailable       = $true
        ExecutionTimeLimit       = (New-TimeSpan -Minutes 15)
    }
    $resolved = Resolve-NextGpuUserStorageMultipleInstancesPolicy -Preferred $MultipleInstancesPolicy
    if ($resolved) {
        $params['MultipleInstances'] = $resolved
    }
    return New-ScheduledTaskSettingsSet @params
}

function Register-NextGpuUserStorageLogonTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    Remove-NextGpuUserStorageTaskIfPresent -TaskName $TaskName

    $action = New-NextGpuUserStorageTaskAction -ScriptPath $ScriptPath -Operation Mount
    $logonDelaySec = $script:NextGpuUserStorageMountLogonDelaySeconds
    $triggerCmd = Get-Command New-ScheduledTaskTrigger -ErrorAction Stop
    $triggerParams = @{ AtLogOn = $true }
    if ($triggerCmd.Parameters.ContainsKey('Delay')) {
        $triggerParams['Delay'] = (New-TimeSpan -Seconds $logonDelaySec)
    }
    $triggers = @(New-ScheduledTaskTrigger @triggerParams)

    foreach ($stateName in @('RemoteConnect', 'ConsoleConnect')) {
        try {
            $triggers += New-NextGpuTaskSessionStateChangeTrigger -StateChangeName $stateName -DelaySeconds 20
            Write-Host "[*] Mount trigger: $stateName (+20s reconnect; mount only when USER=nextGPU)."
        } catch {
            Write-Warning "Session trigger $stateName not added: $($_.Exception.Message)"
        }
    }

    $principal = Get-NextGpuUserStorageUsersGroupTaskPrincipal -RunLevel Limited
    $settings = New-NextGpuUserStorageTaskSettings -MultipleInstancesPolicy IgnoreNew

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "[*] Registered: $TaskName (BUILTIN\Users logon +${logonDelaySec}s; recreate-safe, mounts only for nextGPU)."
        return
    } catch {
        Write-Warning "Register-ScheduledTask failed for ${TaskName}: $($_.Exception.Message). Trying schtasks..."
    }

    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet -FromScheduledTask' -f $ScriptPath
    $tr = "`"powershell.exe`" $psArgs"
    $delayArg = '/DELAY 00:{0:D2}' -f $logonDelaySec
    foreach ($ru in @('BUILTIN\Users', 'Users')) {
        $null = schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /RU $ru /RL LIMITED $delayArg /F 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[*] Registered: $TaskName via schtasks ($ru ONLOGON +${logonDelaySec}s)."
            return
        }
    }
    throw "Failed to register mount logon task $TaskName (ScheduledTasks and schtasks)."
}

function Register-NextGpuUserStorageLogoffTaskViaXml {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    $escapedUser = [System.Security.SecurityElement]::Escape($script:userId)
    $escapedPath = [System.Security.SecurityElement]::Escape($ScriptPath)
    $arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$escapedPath`" -Quiet"
    $escapedArgs = [System.Security.SecurityElement]::Escape($arguments)

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Unmount nextGPU tenant S3 drive at user logoff</Description>
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
      <RunLevel>LeastPrivilege</RunLevel>
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
      <Command>powershell.exe</Command>
      <Arguments>$escapedArgs</Arguments>
    </Exec>
  </Actions>
</Task>
"@

    $xmlPath = Join-Path $env:TEMP "nextgpu-userstorage-unmount-$([Guid]::NewGuid().ToString('N')).xml"
    try {
        Set-Content -LiteralPath $xmlPath -Value $xml -Encoding Unicode -Force
        Register-ScheduledTask -TaskName $TaskName -Xml (Get-Content -LiteralPath $xmlPath -Raw) -Force | Out-Null
        Write-Host "[*] Registered scheduled task: $TaskName (Logoff for $($script:userId) via XML LogoffTrigger)."
        return $true
    } finally {
        Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
    }
}

function Register-NextGpuUserStorageLogoffTaskViaEvent4647 {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    $action = New-NextGpuUserStorageTaskAction -ScriptPath $ScriptPath -Operation Unmount
    $subscription = @"
<QueryList>
  <Query Id="0" Path="Security">
    <Select Path="Security">*[System[(EventID=4647)]] and *[EventData[Data[@Name='TargetUserName'] and (Data='$accountName')]]</Select>
  </Query>
</QueryList>
"@

    try {
        $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger `
            -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
        $eventTrigger = New-CimInstance -CimClass $triggerClass -ClientOnly -Property @{
            Enabled      = $true
            Subscription = $subscription
        }
    } catch {
        Write-Warning "MSFT_TaskEventTrigger not available: $($_.Exception.Message)"
        return $false
    }

    $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-NextGpuUserStorageTaskSettings

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $eventTrigger `
        -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "[*] Registered scheduled task: $TaskName (Security 4647 logoff for $accountName, runs as SYSTEM)."
    Write-Warning 'Audit Policy may need Success for Logoff events (4647) in Security log for this trigger to fire.'
    return $true
}

function Register-NextGpuUserStorageLogoffTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath
    )

    Remove-NextGpuUserStorageTaskIfPresent -TaskName $TaskName

    $action = New-NextGpuUserStorageTaskAction -ScriptPath $ScriptPath -Operation Unmount
    $principal = New-NextGpuUserStorageTaskPrincipal
    $settings = New-NextGpuUserStorageTaskSettings -MultipleInstancesPolicy IgnoreNew
    $triggers = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]

    $logoffTriggerAdded = $false
    if (Test-ScheduledTaskAtLogOffSupported) {
        try {
            [void]$triggers.Add((New-ScheduledTaskTrigger -AtLogOff -User $script:userId))
            $logoffTriggerAdded = $true
        } catch {
            [void]$errors.Add("AtLogOff: $($_.Exception.Message)")
        }
    }

    if (-not $logoffTriggerAdded) {
        try {
            $triggerClass = Get-CimClass -ClassName MSFT_TaskLogoffTrigger `
                -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
            [void]$triggers.Add((New-CimInstance -CimClass $triggerClass -ClientOnly -Property @{
                    Enabled = $true
                    UserId  = $script:userId
                }))
            $logoffTriggerAdded = $true
        } catch {
            [void]$errors.Add("CIM LogoffTrigger: $($_.Exception.Message)")
        }
    }

    foreach ($stateName in @('RemoteDisconnect')) {
        try {
            [void]$triggers.Add((New-NextGpuTaskSessionStateChangeTrigger -StateChangeName $stateName -UserId $script:userId))
            Write-Host "[*] Unmount trigger: $stateName for $($script:userId) (Moonlight / RDP disconnect)."
        } catch {
            [void]$errors.Add("${stateName}: $($_.Exception.Message)")
        }
    }

    if ($triggers.Count -gt 0) {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers.ToArray() `
            -Principal $principal -Settings $settings -Force | Out-Null
        Write-Host "[*] Registered: $TaskName ($($triggers.Count) unmount triggers for $($script:userId))."
        return
    }

    try {
        if (Register-NextGpuUserStorageLogoffTaskViaXml -TaskName $TaskName -ScriptPath $ScriptPath) {
            return
        }
    } catch {
        [void]$errors.Add("XML LogoffTrigger: $($_.Exception.Message)")
    }

    try {
        if (Register-NextGpuUserStorageLogoffTaskViaEvent4647 -TaskName $TaskName -ScriptPath $ScriptPath) {
            Write-Warning 'Unmount uses Security 4647 only. Moonlight disconnect may not unmount U: until next mount runs (mount clears stale state).'
            return
        }
    } catch {
        [void]$errors.Add("Event 4647: $($_.Exception.Message)")
    }

    Write-Warning @"
Could not register unmount task. Mount task clears stale U: on each rental start.
Tried: $($errors -join '; ')
Manual: powershell -File "$ScriptPath"
"@

    Write-Host '[!] Unmount task not registered. Each new mount still clears prior state.' -ForegroundColor Yellow
}

function Register-AllNextGpuUserStorageTasks {
    $null = Publish-NextGpuUserStorageRuntimeScripts -SourceDir $PSScriptRoot
    $MountScriptPath = Get-NextGpuUserStoragePublishedScriptPath -ScriptName 'Mount-UserStorage.ps1'
    $UnmountScriptPath = Get-NextGpuUserStoragePublishedScriptPath -ScriptName 'Unmount-UserStorage.ps1'
    Write-Host "[*] Task scripts (nextGPU-readable): $MountScriptPath"

    foreach ($p in @($MountScriptPath, $UnmountScriptPath)) {
        if (-not (Test-Path -LiteralPath $p)) {
            throw "Published script not found: $p"
        }
    }

    $accountName = Get-NextGpuRentalAccountName
    $script:userId = Get-NextGpuRentalUserPrincipal
    $localUser = Get-NextGpuRentalLocalUser
    if (-not $localUser) {
        Write-Warning "Local user '$accountName' not present; mount task uses BUILTIN\Users (any logon; script runs mount only as nextGPU)."
    }

    # Mount: BUILTIN\Users logon +22s (recreate-safe). Ensure: SYSTEM repairs scripts/ACLs at logon +0s.
    Register-NextGpuUserStorageEnsureBindingsTask
    Register-NextGpuUserStorageLogonTask -TaskName $script:NextGpuUserStorageMountTaskName -ScriptPath $MountScriptPath
    Register-NextGpuUserStorageLogoffTask -TaskName $script:NextGpuUserStorageUnmountTaskName -ScriptPath $UnmountScriptPath

    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageLogDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageLogDir -Force | Out-Null
    }
    Write-UserStorageLog -Message "Register-UserStorageTasks.ps1 completed on $env:COMPUTERNAME" -Level OK

    try {
        $repoRoot = Get-NextGpuRepoRoot -StartPath $PSScriptRoot
        Set-NextGpuRepoRootMarker -RepoRoot $repoRoot
        Write-Host "[*] Repo root for domain.txt: $repoRoot"
        $null = Grant-NextGpuRepoRootReadAccess -RepoRoot $repoRoot
    } catch {
        Write-Warning "Could not save repo-root marker: $($_.Exception.Message)"
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not (Test-NextGpuUserStorageRepairPrincipal)) {
        Write-Error 'Register-UserStorageTasks.ps1 requires Administrator or SYSTEM.'
        exit 1
    }
    Register-AllNextGpuUserStorageTasks
}
