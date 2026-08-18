# Shared helpers for per-user S3 storage mount (nextGPU logon).
# Dot-source from Mount-UserStorage.ps1, Unmount-UserStorage.ps1, Install-UserStorageRcloneConfig.ps1

Set-StrictMode -Version Latest

$script:NextGpuUserStorageProgramData = Join-Path $env:ProgramData 'nextGPU'
$script:NextGpuUserStorageLogDir = Join-Path $script:NextGpuUserStorageProgramData 'logs'
$script:NextGpuUserStorageRcloneDir = Join-Path $script:NextGpuUserStorageProgramData 'rclone'
$script:NextGpuUserStorageSecretsDir = Join-Path $script:NextGpuUserStorageProgramData 'secrets'
$script:NextGpuUserStorageStatePath = Join-Path $script:NextGpuUserStorageProgramData 'user-storage.json'
$script:NextGpuUserStorageMountLockPath = Join-Path $script:NextGpuUserStorageProgramData 'user-storage-mount.lock'
$script:NextGpuRepoRootMarkerPath = Join-Path $script:NextGpuUserStorageProgramData 'repo-root.txt'
$script:NextGpuUserStorageDomainCopyPath = Join-Path $script:NextGpuUserStorageProgramData 'domain.txt'
$script:NextGpuUserStorageRcloneConfigPath = Join-Path $script:NextGpuUserStorageRcloneDir 'rclone.conf'
$script:NextGpuUserStorageRemoteName = 'nextgpu-user'
$script:NextGpuUserStorageMountTaskName = 'nextGPU-UserStorageMount'
$script:NextGpuUserStorageUnmountTaskName = 'nextGPU-UserStorageUnmount'
$script:NextGpuUserStorageEnsureTaskName = 'nextGPU-UserStorageEnsureBindings'
$script:NextGpuUserStorageEnsureLogonDelaySeconds = 0
$script:NextGpuUserStorageEnsureStartupDelaySeconds = 30
$script:NextGpuUserStorageMountLogonDelaySeconds = 22
$script:NextGpuUserStorageEnsureMountWaitSeconds = 60
$script:NextGpuUserStorageMountReadyTimeoutSeconds = 60
$script:NextGpuUserStorageCheckDomainRetryCount = 3
$script:NextGpuUserStorageBoundSidPath = Join-Path $script:NextGpuUserStorageProgramData 'user-storage-nextgpu-sid.txt'
$script:NextGpuUserStorageRuntimeDir = Join-Path $script:NextGpuUserStorageProgramData 'scripts\runtime'
$script:NextGpuUserStoragePublishedScriptNames = @(
    'UserStorageCommon.ps1',
    'Mount-UserStorage.ps1',
    'Unmount-UserStorage.ps1',
    'Register-UserStorageTasks.ps1',
    'Ensure-NextGpuUserStorageBindings.ps1',
    'Sync-NextGpuUserStorageForLocalUser.ps1',
    'Repair-UserStorageBindingsIfNeeded.ps1',
    'User-Storage.ps1',
    'Install-UserStoragePrerequisites.ps1',
    'Install-UserStorageRcloneConfig.ps1',
    'Test-UserStorageMount.ps1',
    'Debug-UserStorageMount.ps1',
    'Troubleshoot-UserStorage.ps1'
)
$script:NextGpuCheckDomainUrl = 'https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/checkDomain'
$script:NextGpuUserStorageBucket = 'next-gpu-storage'
$script:NextGpuUserStorageRegion = 'ap-southeast-1'
$script:NextGpuRentalLocalAccountName = 'nextGPU'
# Survives nextGPU delete/recreate: any new local account in Users keeps these ACLs.
$script:NextGpuRentalAccessGroup = 'BUILTIN\Users'

function Get-NextGpuRentalAccountName {
    return $script:NextGpuRentalLocalAccountName
}

function Get-NextGpuRentalUserPrincipal {
    <#
    .SYNOPSIS
        Local account principal for scheduled tasks and ACLs (COMPUTERNAME\nextGPU, not the admin running setup).
    #>
    $computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { '.' }
    return "$computer\$($script:NextGpuRentalLocalAccountName)"
}

function Get-NextGpuRentalLocalUser {
    return Get-LocalUser -Name $script:NextGpuRentalLocalAccountName -ErrorAction SilentlyContinue
}

function Get-NextGpuRentalLocalUserSid {
    <#
    .SYNOPSIS
        Current nextGPU SID without Get-LocalUser (standard users often get Access denied).
    #>
    if ($env:USERNAME -ieq $script:NextGpuRentalLocalAccountName) {
        try {
            return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        } catch { }
    }
    $user = Get-NextGpuRentalLocalUser
    if ($user) { return $user.SID.Value }
    return ''
}

function Invoke-SchtasksQuiet {
    <#
    .SYNOPSIS
        Run schtasks without native stderr terminating under $ErrorActionPreference Stop.
    #>
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & schtasks.exe @ArgumentList 2>&1
        return @{
            ExitCode = $LASTEXITCODE
            Output   = ($out | Out-String).Trim()
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Get-NextGpuUserStorageBoundSid {
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageBoundSidPath)) {
        return ''
    }
    return (Get-Content -LiteralPath $script:NextGpuUserStorageBoundSidPath -Raw -ErrorAction SilentlyContinue).Trim()
}

function Set-NextGpuUserStorageBoundSid {
    $user = Get-NextGpuRentalLocalUser
    if (-not $user) { return }
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageProgramData)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageProgramData -Force | Out-Null
    }
    Set-Content -LiteralPath $script:NextGpuUserStorageBoundSidPath -Value $user.SID.Value -Encoding UTF8 -Force
}

function Test-NextGpuUserStorageBindingsCurrent {
    <#
    .SYNOPSIS
        True when nextGPU SID matches last bind (ACLs/tasks aligned). False after delete/recreate until Ensure/Sync runs.
    #>
    if (-not (Test-UserStorageRcloneConfigReady)) { return $true }
    $currentSid = Get-NextGpuRentalLocalUserSid
    if ([string]::IsNullOrWhiteSpace($currentSid)) { return $true }
    if (-not (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageMountTaskName)) { return $false }
    $published = Test-UserStoragePublishedScriptsForNextGpu
    if (-not $published.Ok) { return $false }
    if (-not (Test-NextGpuUserStoragePublishedScriptsCurrent)) { return $false }
    if (-not (Test-NextGpuRentalUserStorageAccess -Quiet)) { return $false }
    $storedSid = Get-NextGpuUserStorageBoundSid
    if ([string]::IsNullOrWhiteSpace($storedSid)) { return $false }
    return ($storedSid -eq $currentSid)
}

function New-NextGpuTaskSessionStateChangeTrigger {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('ConsoleConnect', 'ConsoleDisconnect', 'RemoteConnect', 'RemoteDisconnect', 'SessionLock', 'SessionUnlock')]
        [string]$StateChangeName,
        [string]$UserId = '',
        [int]$DelaySeconds = 0
    )
    $stateMap = @{
        ConsoleConnect    = 1
        ConsoleDisconnect = 2
        RemoteConnect     = 3
        RemoteDisconnect  = 4
        SessionLock       = 7
        SessionUnlock     = 8
    }
    $triggerClass = Get-CimClass -ClassName MSFT_TaskSessionStateChangeTrigger `
        -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
    $props = @{
        Enabled     = $true
        StateChange = $stateMap[$StateChangeName]
    }
    if (-not [string]::IsNullOrWhiteSpace($UserId)) {
        $props['UserId'] = $UserId
    }
    if ($DelaySeconds -gt 0) {
        $props['Delay'] = "PT${DelaySeconds}S"
    }
    return New-CimInstance -CimClass $triggerClass -ClientOnly -Property $props
}

function Test-NextGpuUserStorageRepairPrincipal {
    if ($env:USERNAME -ieq 'SYSTEM') { return $true }
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($id)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

function Get-NextGpuUserStorageRepairSourceDir {
    return Get-NextGpuUserStorageSyncSourceDir
}

function Get-NextGpuUserStorageSyncSourceDir {
    <#
    .SYNOPSIS
        Best directory for Sync/Publish: repo scripts\runtime when repo-root marker exists, else caller/published ProgramData.
    #>
    param([string]$FallbackDir = '')

    $candidates = [System.Collections.Generic.List[string]]::new()
    try {
        $start = if ([string]::IsNullOrWhiteSpace($FallbackDir)) { $PSScriptRoot } else { $FallbackDir }
        $repo = Get-NextGpuRepoRoot -StartPath $start
        if ($repo) {
            $repoRuntime = Join-Path $repo.TrimEnd('\') 'scripts\runtime'
            if (Test-Path -LiteralPath (Join-Path $repoRuntime 'UserStorageCommon.ps1')) {
                [void]$candidates.Add($repoRuntime)
            }
        }
    } catch { }

    if (-not [string]::IsNullOrWhiteSpace($FallbackDir)) {
        $fb = $FallbackDir.TrimEnd('\')
        if ($fb -notin $candidates) { [void]$candidates.Add($fb) }
    }
    if ($PSScriptRoot) {
        $ps = $PSScriptRoot.TrimEnd('\')
        if ($ps -notin $candidates -and (Test-Path -LiteralPath (Join-Path $ps 'UserStorageCommon.ps1'))) {
            [void]$candidates.Add($ps)
        }
    }

    $published = $script:NextGpuUserStorageRuntimeDir
    if ((Test-Path -LiteralPath (Join-Path $published 'UserStorageCommon.ps1')) -and ($published -notin $candidates)) {
        [void]$candidates.Add($published)
    }

    foreach ($dir in $candidates) {
        $register = Join-Path $dir 'Register-UserStorageTasks.ps1'
        if (Test-Path -LiteralPath $register) {
            return $dir
        }
    }
    if ($candidates.Count -gt 0) { return $candidates[0] }
    return $published
}

function Test-NextGpuUserStoragePublishedScriptsCurrent {
    <#
    .SYNOPSIS
        False when ProgramData copy is missing helpers from the current repo (admin must Sync from repo).
    #>
    foreach ($name in @('UserStorageCommon.ps1', 'Mount-UserStorage.ps1', 'User-Storage.ps1')) {
        if (-not (Test-Path -LiteralPath (Join-Path $script:NextGpuUserStorageRuntimeDir $name))) {
            return $false
        }
    }
    $publishedCommon = Join-Path $script:NextGpuUserStorageRuntimeDir 'UserStorageCommon.ps1'
    $text = Get-Content -LiteralPath $publishedCommon -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) { return $false }
    return ($text -match 'Test-NextGpuUserStorageMountTaskUsesUsersGroup')
}

function Get-NextGpuRentalUserProfileRoot {
    $user = Get-NextGpuRentalLocalUser
    if (-not $user) { return '' }
    try {
        $cim = Get-CimInstance -ClassName Win32_UserProfile -Filter "LocalPath LIKE '%\\$($script:NextGpuRentalLocalAccountName)'" `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cim -and $cim.LocalPath) {
            return $cim.LocalPath.TrimEnd('\')
        }
    } catch { }
    $guess = Join-Path (Join-Path $env:SystemDrive 'Users') $script:NextGpuRentalLocalAccountName
    if (Test-Path -LiteralPath $guess) { return $guess }
    return ''
}

function Grant-NextGpuUserStorageGroupAccess {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Rights,
        [switch]$Recurse
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $icaclsArgs = @($Path, '/grant', "$($script:NextGpuRentalAccessGroup):${Rights}")
    if ($Recurse) { $icaclsArgs += '/T' }
    & icacls.exe @icaclsArgs 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-NextGpuRentalUserStorageAccess {
    <#
    .SYNOPSIS
        Grant BUILTIN\Users access to ProgramData storage paths (recreate-safe; nextGPU always in Users).
    #>
    param([string]$RentalUser = '')

    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageProgramData)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageProgramData -Force | Out-Null
    }

    if (Test-UserStorageRcloneConfigReady) {
        Set-UserStorageRcloneConfigAcl
    } else {
        $null = Set-UserStorageLogDirAcl
    }

    if (Test-Path -LiteralPath $script:NextGpuUserStorageRuntimeDir) {
        Set-UserStorageRuntimeScriptsAcl
    }

    Grant-NextGpuUserStorageGroupAccess -Path $script:NextGpuUserStorageProgramData -Rights '(OI)(CI)(RX)'
    Grant-NextGpuUserStorageGroupAccess -Path $script:NextGpuUserStorageRuntimeDir -Rights '(OI)(CI)RX' -Recurse
    Grant-NextGpuUserStorageGroupAccess -Path $script:NextGpuRepoRootMarkerPath -Rights 'R'
    Grant-NextGpuUserStorageGroupAccess -Path $script:NextGpuUserStorageDomainCopyPath -Rights 'R'

    $profileRoot = Get-NextGpuRentalUserProfileRoot
    if ($profileRoot) {
        $fallbackLogs = Join-Path $profileRoot 'AppData\Local\nextGPU\logs'
        if (-not (Test-Path -LiteralPath $fallbackLogs)) {
            New-Item -ItemType Directory -Path $fallbackLogs -Force | Out-Null
        }
        Grant-NextGpuUserStorageGroupAccess -Path $fallbackLogs -Rights '(OI)(CI)M' -Recurse
    }

    Write-UserStorageLog "Applied storage ACLs for $($script:NextGpuRentalAccessGroup) (recreate-safe)" -Level OK
    return $true
}

function Test-NextGpuRentalUserStorageAccess {
    <#
    .SYNOPSIS
        True when the rental account can read config/scripts and write logs (live probe as nextGPU, icacls check otherwise).
    #>
    param([switch]$Quiet)

    $requiredRead = @(
        (Join-Path $script:NextGpuUserStorageRuntimeDir 'User-Storage.ps1')
        (Join-Path $script:NextGpuUserStorageRuntimeDir 'Mount-UserStorage.ps1')
        $script:NextGpuUserStorageRcloneConfigPath
        $script:NextGpuUserStorageDomainCopyPath
    )

    foreach ($path in $requiredRead) {
        if (-not (Test-Path -LiteralPath $path)) {
            if (-not $Quiet) {
                $hint = if ($path -eq $script:NextGpuUserStorageDomainCopyPath) {
                    'Administrator: User-Storage.bat Sync (publishes domain.txt to ProgramData).'
                } else {
                    'Administrator: User-Storage.bat Setup or Sync.'
                }
                Write-Warning "Missing for mount: $path $hint"
            }
            return $false
        }
    }

    if ($env:USERNAME -ieq $script:NextGpuRentalLocalAccountName) {
        foreach ($path in $requiredRead) {
            try {
                $null = Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction Stop
            } catch {
                if (-not $Quiet) { Write-Warning "nextGPU cannot read: $path" }
                return $false
            }
        }
        if (-not (Test-UserStorageRcloneLogDestinationWritable)) {
            if (-not $Quiet) { Write-Warning 'nextGPU cannot write mount logs (ProgramData or LocalAppData).' }
            return $false
        }
        return $true
    }

    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageRcloneConfigPath)) {
        return $false
    }

    # Admin/SYSTEM (or nextGPU missing): verify Users group appears on ACLs (recreate-safe).
    $icaclsOut = (& icacls.exe $script:NextGpuUserStorageRcloneConfigPath 2>&1 | Out-String)
    if ($icaclsOut -notmatch '(?i)BUILTIN\\Users' -and $icaclsOut -notmatch '(?i);\\Users:') {
        if (-not $Quiet) { Write-Warning "rclone.conf ACL may not include $($script:NextGpuRentalAccessGroup)" }
        return $false
    }
    return $true
}

function Start-NextGpuUserStorageEnsureTask {
    $taskName = $script:NextGpuUserStorageEnsureTaskName
    if (-not (Test-NextGpuUserStorageScheduledTaskExists -TaskName $taskName)) {
        return $false
    }
    try {
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop | Out-Null
        return $true
    } catch {
        $run = Invoke-SchtasksQuiet -ArgumentList @('/Run', '/TN', $taskName)
        if ($run.Output -match '(?i)access is denied|ERROR:') {
            return $false
        }
        return ($run.ExitCode -eq 0)
    }
}

function Invoke-NextGpuUserStorageBindingsRepairInline {
    <#
    .SYNOPSIS
        SYSTEM/Admin: register ensure task if missing, then Sync (re-bind SID, tasks, ACLs).
    #>
    param([string]$LogFile = '')

    function Write-InlineLog {
        param([string]$Message, [string]$Level = 'INFO')
        Write-UserStorageLog -Message $Message -Level $Level -LogFile $LogFile
    }

    if (-not (Test-UserStorageRcloneConfigReady)) {
        Write-InlineLog 'Inline repair skipped: rclone.conf not ready.' -Level WARN
        return $false
    }

    if (-not (Get-ScheduledTask -TaskName $script:NextGpuUserStorageEnsureTaskName -ErrorAction SilentlyContinue)) {
        Write-InlineLog 'Ensure task missing; registering SYSTEM repair task (elevated repair).' -Level WARN
        try {
            Register-NextGpuUserStorageEnsureBindingsTask
        } catch {
            Write-InlineLog "Register ensure task failed: $($_.Exception.Message)" -Level WARN
        }
    }

    $sourceDir = Get-NextGpuUserStorageSyncSourceDir -FallbackDir $PSScriptRoot
    Write-InlineLog "Inline repair: Sync-NextGpuUserStorageForLocalUser from $sourceDir"
    try {
        $null = Sync-NextGpuUserStorageForLocalUser -SourceDir $sourceDir
    } catch {
        Write-InlineLog "Sync failed: $($_.Exception.Message)" -Level ERROR
        return $false
    }

    return (Test-NextGpuUserStorageBindingsCurrent)
}

function Invoke-NextGpuUserStorageBindingsAutoRepair {
    <#
    .SYNOPSIS
        Auto-remediate stale bindings after nextGPU recreate: trigger ensure task, inline Sync when SYSTEM/Admin, poll until ready.
    #>
    param(
        [int]$MaxWaitSeconds = $script:NextGpuUserStorageEnsureMountWaitSeconds,
        [string]$LogFile = '',
        [switch]$TriggerTasks,
        [switch]$TriggerEnsureOnly
    )

    function Write-RepairLog {
        param([string]$Message, [string]$Level = 'INFO')
        if ([string]::IsNullOrWhiteSpace($LogFile)) {
            Write-UserStorageLog -Message $Message -Level $Level
        } else {
            Write-UserStorageLog -Message $Message -Level $Level -LogFile $LogFile
        }
    }

    if (Test-NextGpuUserStorageBindingsCurrent) {
        return $true
    }
    if (-not (Test-UserStorageRcloneConfigReady)) {
        Write-RepairLog 'Auto-repair skipped: user storage not installed (no rclone.conf).' -Level WARN
        return $false
    }

    Write-RepairLog 'Bindings stale (e.g. recreated nextGPU); starting auto-repair.' -Level WARN

    if (Test-NextGpuUserStorageRepairPrincipal) {
        $inlineOk = Invoke-NextGpuUserStorageBindingsRepairInline -LogFile $LogFile
        if ($inlineOk) {
            Write-RepairLog 'Auto-repair: inline Sync completed; bindings current.' -Level OK
            return $true
        }
        Write-RepairLog 'Auto-repair: inline Sync finished but bindings still stale.' -Level WARN
    }

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    $triggered = $false
    $waitStarted = Get-Date
    $lastProgressSec = -1
    while ((Get-Date) -lt $deadline) {
        if (Test-NextGpuUserStorageBindingsCurrent) {
            Write-RepairLog 'Auto-repair: bindings current.' -Level OK
            return $true
        }

        $elapsed = [int](((Get-Date) - $waitStarted).TotalSeconds)
        if ($elapsed -ge 5 -and ($elapsed - $lastProgressSec) -ge 5) {
            $lastProgressSec = $elapsed
            Write-RepairLog "Auto-repair: waiting for SYSTEM ensure/Sync (${elapsed}s / ${MaxWaitSeconds}s)..." -Level INFO
        }

        if ($TriggerTasks -and -not $triggered) {
            $triggered = $true
            $taskNames = [System.Collections.Generic.List[string]]::new()
            [void]$taskNames.Add($script:NextGpuUserStorageEnsureTaskName)
            if (-not $TriggerEnsureOnly) {
                [void]$taskNames.Add($script:NextGpuUserStorageMountTaskName)
            }
            foreach ($taskName in $taskNames) {
                if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
                    Write-RepairLog "Task $taskName not registered; waiting for logon ensure or Admin Sync." -Level WARN
                    continue
                }
                $runOut = (& schtasks.exe /Run /TN $taskName 2>&1 | Out-String).Trim()
                if ($runOut -match '(?i)access is denied|ERROR:') {
                    Write-RepairLog "schtasks /Run $taskName skipped ($runOut)" -Level WARN
                } elseif ($runOut) {
                    Write-RepairLog "Triggered $taskName : $runOut"
                }
            }
        }

        if (Test-NextGpuUserStorageRepairPrincipal) {
            $null = Invoke-NextGpuUserStorageBindingsRepairInline -LogFile $LogFile
            if (Test-NextGpuUserStorageBindingsCurrent) {
                Write-RepairLog 'Auto-repair: inline Sync succeeded during wait.' -Level OK
                return $true
            }
        }

        Start-Sleep -Seconds 2
    }

    return (Test-NextGpuUserStorageBindingsCurrent)
}

function Repair-NextGpuUserStorageBindingsBeforeMount {
    param(
        [int]$MaxWaitSeconds = $script:NextGpuUserStorageEnsureMountWaitSeconds,
        [string]$LogFile = '',
        [switch]$TriggerEnsureOnly
    )
    return Wait-NextGpuUserStorageBindingsForMount -MaxWaitSeconds $MaxWaitSeconds -LogFile $LogFile
}

function Wait-NextGpuUserStorageBindingsForMount {
    <#
    .SYNOPSIS
        Wait until nextGPU-UserStorageEnsureBindings (SYSTEM Sync) re-binds tasks after recreate. Used by mount, not auto-repair.
    #>
    param(
        [int]$MaxWaitSeconds = $script:NextGpuUserStorageEnsureMountWaitSeconds,
        [string]$LogFile = '',
        [switch]$Quiet
    )

    function Write-WaitLog {
        param([string]$Message, [string]$Level = 'INFO')
        if ($Quiet) {
            if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
                $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
                Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
            }
            return
        }
        Write-UserStorageLog -Message $Message -Level $Level -LogFile $LogFile
    }

    if (Test-NextGpuUserStorageBindingsCurrent) {
        return $true
    }
    if (-not (Test-UserStorageRcloneConfigReady)) {
        Write-WaitLog 'Cannot mount: user storage not installed (no rclone.conf).' -Level WARN
        return $false
    }

    $ensureName = $script:NextGpuUserStorageEnsureTaskName
    if (-not (Test-NextGpuUserStorageScheduledTaskExists -TaskName $ensureName)) {
        Write-WaitLog 'Ensure task missing. Administrator: run Setup-UserStorage.bat once, then Sync-NextGpuUserStorageForLocalUser.bat.' -Level ERROR
        return $false
    }

    Write-WaitLog 'Bindings stale (recreated nextGPU). Starting SYSTEM ensure (re-register tasks for new SID)...' -Level WARN
    if (-not (Start-NextGpuUserStorageEnsureTask)) {
        Write-WaitLog "Could not start $ensureName (logon ensure may still run). Waiting..." -Level WARN
    }

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    $waitStarted = Get-Date
    $lastProgressSec = -1
    $retriedEnsure = $false

    while ((Get-Date) -lt $deadline) {
        if (Test-NextGpuUserStorageBindingsCurrent) {
            Write-WaitLog 'Bindings ready; continuing mount.' -Level OK
            return $true
        }

        $elapsed = [int](((Get-Date) - $waitStarted).TotalSeconds)
        if ($elapsed -ge 2 -and ($elapsed - $lastProgressSec) -ge 3) {
            $lastProgressSec = $elapsed
            $state = 'unknown'
            try {
                $state = (Get-ScheduledTask -TaskName $ensureName -ErrorAction Stop).State
            } catch { }
            Write-WaitLog "Waiting for ensure repair... ${elapsed}s / ${MaxWaitSeconds}s (task: $state)" -Level INFO
        }

        if (-not $retriedEnsure -and $elapsed -ge 12) {
            $running = $false
            try { $running = ((Get-ScheduledTask -TaskName $ensureName).State -eq 'Running') } catch { }
            if (-not $running -and -not (Test-NextGpuUserStorageBindingsCurrent)) {
                $retriedEnsure = $true
                Write-WaitLog 'Ensure not finished; triggering ensure again.' -Level WARN
                $null = Start-NextGpuUserStorageEnsureTask
            }
        }

        Start-Sleep -Seconds 1
    }

    if (Test-NextGpuUserStorageBindingsCurrent) {
        return $true
    }
    Write-WaitLog "Ensure did not finish within ${MaxWaitSeconds}s. Administrator: Sync-NextGpuUserStorageForLocalUser.bat then log in as nextGPU again." -Level ERROR
    return $false
}

function Test-NextGpuUserStorageTaskPrincipalCurrent {
    <#
    .SYNOPSIS
        True when mount uses BUILTIN\Users and unmount is bound to current nextGPU account.
    #>
    if (-not (Test-NextGpuUserStorageRepairPrincipal)) { return $true }
    if (-not (Test-NextGpuUserStorageMountTaskUsesUsersGroup)) { return $false }
    $user = Get-NextGpuRentalLocalUser
    if (-not $user) { return $true }
    $expected = Get-NextGpuRentalUserPrincipal
    $unmount = Get-ScheduledTask -TaskName $script:NextGpuUserStorageUnmountTaskName -ErrorAction SilentlyContinue
    if (-not $unmount) { return $false }
    $principal = $unmount.Principal
    if (-not $principal) { return $false }
    $taskUser = $principal.UserId
    if ([string]::IsNullOrWhiteSpace($taskUser)) { return $false }
    if ($taskUser -ieq $expected) { return $true }
    if ($taskUser -match '\\nextGPU$' -or $taskUser -ieq 'nextGPU') { return $true }
    return $false
}

function Test-NextGpuUserStorageMountTaskUsesUsersGroup {
    if (-not (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageMountTaskName)) {
        return $false
    }
    if (-not (Test-NextGpuUserStorageRepairPrincipal)) {
        return $true
    }
    try {
        $task = Get-ScheduledTask -TaskName $script:NextGpuUserStorageMountTaskName -ErrorAction Stop
        $principal = $task.Principal
        if (-not $principal) { return $false }
        if ($principal.GroupId -match '(?i)Users') { return $true }
        if ($principal.UserId -match '(?i)S-1-5-32-545|^Users$|BUILTIN\\Users') { return $true }
        return $false
    } catch {
        return $false
    }
}

function Test-NextGpuUserStorageLogonAutomationNeedRepair {
    <#
    .SYNOPSIS
        True when logon auto-mount tasks or published files need repair (not per-user SID; mount uses BUILTIN\Users).
    #>
    if (-not (Test-UserStorageRcloneConfigReady)) { return $false }
    if (-not (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageMountTaskName)) {
        return $true
    }
    if (-not (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageEnsureTaskName)) {
        return $true
    }
    if (-not (Test-NextGpuUserStorageMountTaskUsesUsersGroup)) { return $true }
    if (-not (Test-NextGpuUserStoragePublishedScriptsCurrent)) { return $true }
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath)) { return $true }
    return $false
}

function Test-NextGpuUserStorageLogonAutomationReady {
    <#
    .SYNOPSIS
        True when nextGPU logon should auto-mount U: (~22s) without manual User-Storage.bat Mount.
    #>
    [CmdletBinding()]
    param([switch]$Quiet)

    $fileReady = Test-UserStorageMountFileReady -Quiet
    $checks = [ordered]@{
        mount_task       = (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageMountTaskName)
        mount_users_group = (Test-NextGpuUserStorageMountTaskUsesUsersGroup)
        ensure_task      = (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageEnsureTaskName)
        file_ready       = $fileReady.Ok
    }

    $failed = @($checks.Keys | Where-Object { -not $checks[$_] })
    if (-not $Quiet) {
        foreach ($key in $checks.Keys) {
            $label = ($key -replace '_', ' ')
            if ($checks[$key]) {
                Write-Host "[OK]   $label" -ForegroundColor Green
            } else {
                Write-Host "[FAIL] $label" -ForegroundColor Red
            }
        }
    }

    return [pscustomobject]@{
        Ok     = ($failed.Count -eq 0)
        Failed = $failed
        Checks = $checks
    }
}

function Repair-NextGpuUserStorageLogonAutomation {
    <#
    .SYNOPSIS
        Re-register logon mount/ensure tasks for current nextGPU (SYSTEM/Admin). ACLs use BUILTIN\Users.
    #>
    param(
        [string]$SourceDir = '',
        [switch]$Quiet
    )

    if (-not (Test-NextGpuUserStorageRepairPrincipal)) {
        throw 'Logon automation repair requires Administrator or SYSTEM.'
    }
    if (-not (Test-UserStorageRcloneConfigReady)) {
        Write-Warning 'User storage not installed. Run Setup-UserStorage.bat first.'
        return $false
    }
    if (-not (Get-NextGpuRentalLocalUser)) {
        Write-Warning "Local user '$($script:NextGpuRentalLocalAccountName)' missing; registering BUILTIN\Users mount task anyway."
    }

    if ([string]::IsNullOrWhiteSpace($SourceDir)) {
        $SourceDir = Get-NextGpuUserStorageSyncSourceDir -FallbackDir $script:NextGpuUserStorageRuntimeDir
    }

    if (-not (Test-NextGpuUserStoragePublishedScriptsCurrent)) {
        $null = Publish-NextGpuUserStorageRuntimeScripts -SourceDir $SourceDir
    }
    $null = Set-NextGpuRentalUserStorageAccess

    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath)) {
        try {
            $repoRoot = Get-NextGpuRepoRoot -StartPath $SourceDir
            $null = Publish-NextGpuDomainForRentalUser -RepoRoot $repoRoot
        } catch {
            Write-Warning "domain.txt publish: $($_.Exception.Message)"
        }
    }

    $registerScript = Join-Path $SourceDir 'Register-UserStorageTasks.ps1'
    if (-not (Test-Path -LiteralPath $registerScript)) {
        throw "Register-UserStorageTasks.ps1 not found: $registerScript"
    }
    . $registerScript
    if (-not (Get-Command -Name 'Register-AllNextGpuUserStorageTasks' -ErrorAction SilentlyContinue)) {
        throw 'Register-UserStorageTasks.ps1 is outdated (missing Register-AllNextGpuUserStorageTasks).'
    }
    Register-AllNextGpuUserStorageTasks
    Set-NextGpuUserStorageBoundSid

    $ready = Test-NextGpuUserStorageLogonAutomationReady -Quiet
    if ($ready.Ok -and -not $Quiet) {
        Write-Host '[OK]   Logon auto-mount: BUILTIN\Users task +22s (nextGPU sign-in mounts U:; recreate-safe).' -ForegroundColor Green
    }
    return $ready.Ok
}

function Sync-NextGpuUserStorageForLocalUser {
    <#
    .SYNOPSIS
        Re-bind tasks and ACLs to the current nextGPU local account (safe after delete/recreate with same name).
    #>
    param(
        [string]$SourceDir = '',
        [switch]$SkipTaskRegistration
    )
    if ([string]::IsNullOrWhiteSpace($SourceDir)) {
        $SourceDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    }

    $user = Get-NextGpuRentalLocalUser
    if (-not $user) {
        Write-Warning "Local user '$($script:NextGpuRentalLocalAccountName)' missing; publishing scripts and Users-group ACLs only."
    }
    if (-not (Test-UserStorageRcloneConfigReady)) {
        Write-Warning 'User storage not installed. Run Setup-UserStorage.bat as Administrator first.'
        return $false
    }

    if ($user) {
        Write-Host "[*] Binding user storage to $($user.Name) (SID $($user.SID))." -ForegroundColor Cyan
    } else {
        Write-Host '[*] Applying recreate-safe Users-group ACLs (no local nextGPU account yet).' -ForegroundColor Cyan
    }

    $null = Publish-NextGpuUserStorageRuntimeScripts -SourceDir $SourceDir
    $null = Set-NextGpuRentalUserStorageAccess

    $repoGrantOk = $false
    try {
        $repoRoot = Get-NextGpuRepoRoot -StartPath $SourceDir
        Set-NextGpuRepoRootMarker -RepoRoot $repoRoot
        $repoGrantOk = [bool](Grant-NextGpuRepoRootReadAccess -RepoRoot $repoRoot)
        $null = Publish-NextGpuDomainForRentalUser -RepoRoot $repoRoot
    } catch {
        Write-Warning "Repo marker/ACL: $($_.Exception.Message)"
    }

    if (-not $SkipTaskRegistration -and $user) {
        $registerScript = Join-Path $SourceDir 'Register-UserStorageTasks.ps1'
        if (-not (Test-Path -LiteralPath $registerScript)) {
            throw "Register-UserStorageTasks.ps1 not found: $registerScript"
        }
        if (-not (Test-NextGpuUserStorageRepairPrincipal)) {
            throw 'Task registration requires Administrator or SYSTEM (run Sync-NextGpuUserStorageForLocalUser.bat elevated).'
        }
        . $registerScript
        if (-not (Get-Command -Name 'Register-AllNextGpuUserStorageTasks' -ErrorAction SilentlyContinue)) {
            throw 'Register-UserStorageTasks.ps1 is outdated (missing Register-AllNextGpuUserStorageTasks). Run Sync from the repo scripts\runtime folder.'
        }
        Register-AllNextGpuUserStorageTasks
        Set-NextGpuUserStorageBoundSid
    } elseif (-not $user) {
        Write-Warning 'Skipped task registration (nextGPU account not present).'
    }
    if (-not $repoGrantOk) {
        Write-Warning 'domain.txt ACLs were not confirmed. Run Sync from the repo folder (where domain.txt lives) or fix repo-root.txt.'
    }

    if (Test-NextGpuUserStorageTaskPrincipalCurrent) {
        Write-Host '[OK]   Mount task: BUILTIN\Users; unmount task: nextGPU.' -ForegroundColor Green
    } else {
        Write-Warning 'Task principal check failed; re-run User-Storage.bat Sync.'
    }

    $autoReady = Test-NextGpuUserStorageLogonAutomationReady -Quiet
    if ($autoReady.Ok) {
        Write-Host '[OK]   Logon auto-mount: nextGPU sign-in -> U: within ~22s (no manual Mount).' -ForegroundColor Green
    } elseif ($user) {
        Write-Warning "Logon auto-mount not ready: $($autoReady.Failed -join ', ')"
    }
    $fileReady = Test-UserStorageMountFileReady -Quiet
    if ($fileReady.Ok -and -not $autoReady.Ok) {
        Write-Host '[OK]   Mount file access ready (manual User-Storage.bat Mount still works).' -ForegroundColor Green
    }
    if ($user) {
        return $autoReady.Ok
    }
    return $fileReady.Ok
}

function Test-UserStorageMountFileReady {
    <#
    .SYNOPSIS
        Minimum for Mount-UserStorage.ps1: config, ProgramData domain copy, scripts, Users-group file access.
        Does not require SID binding or scheduled tasks (recreate-safe after one-time Setup/Sync).
    #>
    [CmdletBinding()]
    param([switch]$Quiet)

    $checks = [ordered]@{
        rclone_config     = (Test-UserStorageRcloneConfigReady)
        rclone_readable   = (Test-UserStorageRcloneConfigReadable)
        rclone_exe        = [bool](Get-RcloneExeForUserStorage)
        winfsp            = (Test-WinFspInstalled)
        published_scripts = (Test-NextGpuUserStoragePublishedScriptsCurrent)
        domain_copy       = (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath)
        rental_access     = (Test-NextGpuRentalUserStorageAccess -Quiet)
    }

    try {
        $null = Get-NextGpuDomainFromFile
        $checks['domain_txt'] = $true
    } catch {
        $checks['domain_txt'] = $false
    }

    $failed = @($checks.Keys | Where-Object { -not $checks[$_] })
    if (-not $Quiet) {
        foreach ($key in $checks.Keys) {
            $label = ($key -replace '_', ' ')
            if ($checks[$key]) {
                Write-Host "[OK]   $label" -ForegroundColor Green
            } else {
                Write-Host "[FAIL] $label" -ForegroundColor Red
            }
        }
    }

    return [pscustomobject]@{
        Ok     = ($failed.Count -eq 0)
        Failed = $failed
        Checks = $checks
    }
}

function Test-UserStorageLogonMountReady {
    <#
    .SYNOPSIS
        Full logon automation: mount file ready plus scheduled tasks and SID binding.
    #>
    [CmdletBinding()]
    param([switch]$Quiet)

    $checks = [ordered]@{
        nextGPU_user        = [bool](Get-NextGpuRentalLocalUser)
        rclone_config       = (Test-UserStorageRcloneConfigReady)
        rclone_exe          = [bool](Get-RcloneExeForUserStorage)
        winfsp              = (Test-WinFspInstalled)
        published_scripts   = (Test-NextGpuUserStoragePublishedScriptsCurrent)
        ensure_task         = (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageEnsureTaskName)
        mount_task          = (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageMountTaskName)
        bindings_current    = (Test-NextGpuUserStorageBindingsCurrent)
        rental_access       = (Test-NextGpuRentalUserStorageAccess -Quiet)
        user_storage_launcher = (Test-Path -LiteralPath (Join-Path $script:NextGpuUserStorageRuntimeDir 'User-Storage.ps1'))
    }

    try {
        $null = Get-NextGpuDomainFromFile
        $checks['domain_txt'] = $true
        $checks['domain_copy'] = (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath)
    } catch {
        $checks['domain_txt'] = $false
        $checks['domain_copy'] = $false
    }

    $failed = @($checks.Keys | Where-Object { -not $checks[$_] })
    if (-not $Quiet) {
        foreach ($key in $checks.Keys) {
            $label = ($key -replace '_', ' ')
            if ($checks[$key]) {
                Write-Host "[OK]   $label" -ForegroundColor Green
            } else {
                Write-Host "[FAIL] $label" -ForegroundColor Red
            }
        }
    }

    return [pscustomobject]@{
        Ok     = ($failed.Count -eq 0)
        Failed = $failed
        Checks = $checks
    }
}

function Register-NextGpuUserStorageEnsureBindingsTask {
    <#
    .SYNOPSIS
        SYSTEM task: re-bind ACLs/tasks when nextGPU is recreated (same name, new SID). No repeat of Setup-UserStorage.bat.
    #>
    $ensureScript = Get-NextGpuUserStoragePublishedScriptPath -ScriptName 'Ensure-NextGpuUserStorageBindings.ps1'
    if (-not (Test-Path -LiteralPath $ensureScript)) {
        throw "Published ensure script missing: $ensureScript (re-run Setup-UserStorage.bat once)."
    }

    $taskName = $script:NextGpuUserStorageEnsureTaskName
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f $ensureScript
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $settingsCmd = Get-Command New-ScheduledTaskSettingsSet -ErrorAction Stop
    $settingsParams = @{
        AllowStartIfOnBatteries = $true
        DontStopIfGoingOnBatteries = $true
        StartWhenAvailable       = $true
    }
    if ($settingsCmd.Parameters.ContainsKey('MultipleInstances')) {
        $enumType = $settingsCmd.Parameters['MultipleInstances'].ParameterType
        if ('IgnoreNew' -in [System.Enum]::GetNames($enumType)) {
            $settingsParams['MultipleInstances'] = [Enum]::Parse($enumType, 'IgnoreNew')
        }
    }
    $settings = New-ScheduledTaskSettingsSet @settingsParams

    $triggerCmd = Get-Command New-ScheduledTaskTrigger -ErrorAction Stop
    $useDelay = $triggerCmd.Parameters.ContainsKey('Delay')

    $triggers = New-Object System.Collections.Generic.List[object]
    $startupParams = @{ AtStartup = $true }
    if ($useDelay) {
        $startupParams['Delay'] = (New-TimeSpan -Seconds $script:NextGpuUserStorageEnsureStartupDelaySeconds)
    }
    [void]$triggers.Add((New-ScheduledTaskTrigger @startupParams))

    $userId = Get-NextGpuRentalUserPrincipal
    try {
        # Before mount logon (~22s). Mount waits on this task if bindings are still stale.
        $logonParams = @{ AtLogOn = $true; User = $userId }
        if ($useDelay) {
            $logonParams['Delay'] = (New-TimeSpan -Seconds $script:NextGpuUserStorageEnsureLogonDelaySeconds)
        }
        [void]$triggers.Add((New-ScheduledTaskTrigger @logonParams))
    } catch {
        Write-Warning "Ensure-bindings task: no AtLogOn trigger for $userId ($($_.Exception.Message)). Startup trigger only."
    }

    $reconnectDelaySec = 10
    foreach ($stateName in @('RemoteConnect', 'ConsoleConnect')) {
        try {
            [void]$triggers.Add((New-NextGpuTaskSessionStateChangeTrigger -StateChangeName $stateName -UserId $userId -DelaySeconds $reconnectDelaySec))
        } catch {
            Write-Warning "Ensure-bindings: session trigger $stateName not added: $($_.Exception.Message)"
        }
    }

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers.ToArray() `
        -Principal $principal -Settings $settings -Force | Out-Null
    $logonSec = $script:NextGpuUserStorageEnsureLogonDelaySeconds
    $bootSec = $script:NextGpuUserStorageEnsureStartupDelaySeconds
    $mountSec = $script:NextGpuUserStorageMountLogonDelaySeconds
    Write-Host "[*] Registered: $taskName (SYSTEM; startup +${bootSec}s, logon +${logonSec}s, reconnect +${reconnectDelaySec}s - mount logon +${mountSec}s)." -ForegroundColor DarkGray
    Write-UserStorageLog -Message "Registered $taskName -> $ensureScript" -Level OK `
        -LogFile (Join-Path $script:NextGpuUserStorageLogDir 'user-storage-ensure.log')
}

function Set-NextGpuRepoRootMarker {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $root = $RepoRoot.TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $root 'domain.txt'))) {
        throw "domain.txt not found under repo root: $root"
    }
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageProgramData)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageProgramData -Force | Out-Null
    }
    Set-Content -LiteralPath $script:NextGpuRepoRootMarkerPath -Value $root -Encoding UTF8 -Force
    try {
        $markerAcl = Get-Acl -LiteralPath $script:NextGpuRepoRootMarkerPath
        $markerAcl.SetAccessRuleProtection($true, $false)
        $markerAcl.Access | ForEach-Object { $null = $markerAcl.RemoveAccessRule($_) }
        foreach ($rule in @(
                @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-32-545'; Rights = 'Read' }
            )) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($rule.Sid)
            $markerAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, $rule.Rights, 'Allow')))
        }
        Set-Acl -LiteralPath $script:NextGpuRepoRootMarkerPath -AclObject $markerAcl
    } catch {
        Write-Warning "Could not set ACL on repo-root.txt: $($_.Exception.Message)"
    }
    Write-UserStorageLog "Saved repo root marker: $root" -Level OK
}

function Test-NextGpuUserStorageScheduledTaskExists {
    <#
    .SYNOPSIS
        Works for nextGPU (unlike Get-ScheduledTask, which often requires admin).
    #>
    param([Parameter(Mandatory)][string]$TaskName)
    $result = Invoke-SchtasksQuiet -ArgumentList @('/Query', '/TN', $TaskName, '/FO', 'LIST')
    return ($result.ExitCode -eq 0)
}

function Test-UserStorageDriveLetterMounted {
    param([string]$DriveLetter = 'U')
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $root = "${letter}:\"
    if (Test-Path -LiteralPath $root) { return $true }
    if (Get-PSDrive -Name $letter -PSProvider FileSystem -ErrorAction SilentlyContinue) { return $true }
    try {
        $null = [System.IO.Directory]::GetDirectories($root)
        return $true
    } catch { }
    return $false
}

function Get-UserStorageLiveMountStatus {
    <#
    .SYNOPSIS
        Whether U: is live right now (rclone PID running + path reachable), not just a past log line.
    #>
    param([string]$DriveLetter = 'U')

    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $drivePath = "${letter}:\"
    $state = Get-UserStorageState
    $pidAlive = $false
    $mountPid = 0
    if ($state -and $state.mountPid) {
        $mountPid = [int]$state.mountPid
        $pidAlive = $mountPid -gt 0 -and [bool](Get-Process -Id $mountPid -ErrorAction SilentlyContinue)
    }
    $pathOk = Test-UserStorageDriveLetterMounted -DriveLetter $letter
    $sessionId = [int](Get-Process -Id $PID).SessionId
    $stateSession = if ($state -and $state.sessionId) { [int]$state.sessionId } else { -1 }

    return [pscustomobject]@{
        DriveLetter    = $letter
        DrivePath      = $drivePath
        PathReachable  = $pathOk
        MountPid       = $mountPid
        RcloneRunning  = $pidAlive
        LiveMount      = ($pidAlive -and $pathOk)
        StateUserId    = if ($state) { [string]$state.userId } else { '' }
        StateSessionId = $stateSession
        CurrentSession = $sessionId
        SameSession    = ($stateSession -lt 0) -or ($stateSession -eq $sessionId)
    }
}

function Show-UserStorageDriveInExplorer {
    param([string]$DriveLetter = 'U')
    $drivePath = "$(($DriveLetter.TrimEnd(':')).ToUpperInvariant()):\"
    if (-not (Test-UserStorageDriveLetterMounted -DriveLetter $DriveLetter)) {
        Write-Warning "Drive $drivePath is not reachable; mount first (User-Storage.bat Mount)."
        return $false
    }
    Start-Process -FilePath 'explorer.exe' -ArgumentList $drivePath -ErrorAction SilentlyContinue
    return $true
}

function Publish-NextGpuDomainForRentalUser {
    <#
    .SYNOPSIS
        Copy domain.txt to ProgramData so nextGPU can read it (repo may live under Administrator profile).
    #>
    param([string]$RepoRoot = '')

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-NextGpuRepoRoot -StartPath $script:NextGpuUserStorageRuntimeDir
    }
    $src = Join-Path $RepoRoot.TrimEnd('\') 'domain.txt'
    if (-not (Test-Path -LiteralPath $src)) {
        Write-Warning "domain.txt not found at $src - skip ProgramData copy."
        return $false
    }
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageProgramData)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageProgramData -Force | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination $script:NextGpuUserStorageDomainCopyPath -Force
    Grant-NextGpuUserStorageGroupAccess -Path $script:NextGpuUserStorageDomainCopyPath -Rights 'R'
    Write-UserStorageLog "Published domain.txt for $($script:NextGpuRentalAccessGroup): $($script:NextGpuUserStorageDomainCopyPath)" -Level OK
    return $true
}

function Get-NextGpuRepoRoot {
    param([string]$StartPath = '')
    if (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath) {
        if (Test-Path -LiteralPath $script:NextGpuRepoRootMarkerPath) {
            try {
                $marked = (Get-Content -LiteralPath $script:NextGpuRepoRootMarkerPath -Raw -ErrorAction Stop).Trim()
                if ($marked) { return $marked.TrimEnd('\') }
            } catch { }
        }
        return $script:NextGpuUserStorageProgramData.TrimEnd('\')
    }
    if (Test-Path -LiteralPath $script:NextGpuRepoRootMarkerPath) {
        try {
            $marked = (Get-Content -LiteralPath $script:NextGpuRepoRootMarkerPath -Raw -ErrorAction Stop).Trim()
            if ($marked -and (Test-Path -LiteralPath (Join-Path $marked 'domain.txt'))) {
                return $marked.TrimEnd('\')
            }
        } catch { }
    }
    if ($env:NEXTGPU_REPO_ROOT) {
        $envRoot = $env:NEXTGPU_REPO_ROOT.TrimEnd('\')
        if (Test-Path -LiteralPath (Join-Path $envRoot 'domain.txt')) {
            return $envRoot
        }
    }
    if ([string]::IsNullOrWhiteSpace($StartPath)) {
        if ($PSScriptRoot) {
            $StartPath = $PSScriptRoot
        } else {
            $StartPath = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($StartPath)) {
        $dir = $StartPath.TrimEnd('\')
        try {
            $dir = (Resolve-Path -LiteralPath $StartPath -ErrorAction Stop).Path
        } catch { }
        for ($i = 0; $i -lt 10; $i++) {
            $domainFile = Join-Path $dir 'domain.txt'
            if (Test-Path -LiteralPath $domainFile) {
                return $dir.TrimEnd('\')
            }
            $parent = Split-Path -Parent $dir
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) {
                break
            }
            $dir = $parent
        }
    }
    throw @"
Could not find domain.txt. Expected it at the repo root (same folder as RegisterMachine_Beta.bat).
Set NEXTGPU_REPO_ROOT, or re-run Setup-UserStorage.bat as Administrator from your scripts folder.
Searched upward from: $StartPath
"@
}

function Write-UserStorageLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO',
        [string]$LogFile = ''
    )
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageLogDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageLogDir -Force | Out-Null
    }
    if ([string]::IsNullOrWhiteSpace($LogFile)) {
        $LogFile = Join-Path $script:NextGpuUserStorageLogDir 'user-storage.log'
    }
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    try {
        $repoRoot = $null
        if (Test-Path -LiteralPath $script:NextGpuRepoRootMarkerPath) {
            $repoRoot = (Get-Content -LiteralPath $script:NextGpuRepoRootMarkerPath -Raw).Trim()
        } elseif ($env:NEXTGPU_REPO_ROOT) {
            $repoRoot = $env:NEXTGPU_REPO_ROOT.TrimEnd('\')
        }
        if ($repoRoot) {
            $repoLogDir = Join-Path $repoRoot 'logs'
            if (-not (Test-Path -LiteralPath $repoLogDir)) {
                New-Item -ItemType Directory -Path $repoLogDir -Force | Out-Null
            }
            $mirrorName = Split-Path -Leaf $LogFile
            Add-Content -LiteralPath (Join-Path $repoLogDir $mirrorName) -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch { }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Get-NextGpuDomainFromFile {
    param([string]$RepoRoot = '')
    $path = ''
    if (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath) {
        $path = $script:NextGpuUserStorageDomainCopyPath
    } elseif ($env:USERNAME -ieq $script:NextGpuRentalLocalAccountName) {
        throw "domain.txt not in ProgramData ($($script:NextGpuUserStorageDomainCopyPath)). Administrator: User-Storage.bat Sync."
    } else {
        if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
            $RepoRoot = Get-NextGpuRepoRoot
        }
        $path = Join-Path $RepoRoot 'domain.txt'
    }
    if (-not (Test-Path -LiteralPath $path)) {
        throw ('domain.txt not found: {0}' -f $path)
    }
    foreach ($line in Get-Content -LiteralPath $path -ErrorAction Stop) {
        if ($line -match '^\s*DOMAIN\s*=\s*(.+)\s*$') {
            $domain = $matches[1].Trim().Trim([char]0xFEFF, [char]0x200B)
            if ($domain) { return $domain }
        }
    }
    throw 'DOMAIN= missing in domain.txt'
}

function Get-CheckDomainJsonProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )
    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $prop = $Object.PSObject.Properties[$name]
        if ($null -eq $prop) { continue }
        $val = [string]$prop.Value
        if (-not [string]::IsNullOrWhiteSpace($val)) {
            return $val.Trim()
        }
    }
    return $null
}

function Get-CheckDomainRequestBody {
    param([Parameter(Mandatory)][string]$Domain)
    # API expects GET with JSON body containing domain.
    return (@{ domain = $Domain.Trim() } | ConvertTo-Json -Compress)
}

function Get-CheckDomainApiErrorFromBody {
    param([Parameter(Mandatory)][string]$RawText)
    if ([string]::IsNullOrWhiteSpace($RawText)) { return $null }
    try {
        $parsed = $RawText | ConvertFrom-Json
    } catch {
        return $null
    }
    $successProp = $parsed.PSObject.Properties['success']
    if ($successProp -and $successProp.Value -eq $false) {
        $err = Get-CheckDomainJsonProperty -Object $parsed -Names @('error', 'message')
        $hint = Get-CheckDomainJsonProperty -Object $parsed -Names @('hint')
        if ($err -and $hint) { return "$err - $hint" }
        if ($err) { return $err }
    }
    $msgOnly = Get-CheckDomainJsonProperty -Object $parsed -Names @('message')
    if ($msgOnly -and $msgOnly -notmatch 'Not Found') { return $msgOnly }
    return $null
}

function Test-CheckDomainApiResponseSuccess {
    param([Parameter(Mandatory)][string]$RawText)
    if ([string]::IsNullOrWhiteSpace($RawText)) { return $false }

    $parsed = $null
    try { $parsed = $RawText | ConvertFrom-Json } catch { }

    if ($parsed) {
        $successProp = $parsed.PSObject.Properties['success']
        if ($successProp -and $successProp.Value -eq $false) { return $false }
        $errProp = $parsed.PSObject.Properties['error']
        if ($errProp -and -not [string]::IsNullOrWhiteSpace([string]$errProp.Value)) {
            if (-not ($RawText -match '"(?:userID|userId)"\s*:')) { return $false }
        }
    }

    return ($RawText -match '"(?:userID|userId|user_id)"\s*:')
}

function ConvertFrom-CheckDomainResponse {
    param([Parameter(Mandatory)][string]$RawText)
    $parsed = $null
    try {
        $parsed = $RawText | ConvertFrom-Json
    } catch {
        # keep parsed null; regex fallback below
    }

    if ($parsed) {
        $successProp = $parsed.PSObject.Properties['success']
        if ($successProp -and $successProp.Value -eq $false) {
            $err = Get-CheckDomainJsonProperty -Object $parsed -Names @('error', 'message')
            throw "checkDomain API error: $(if ($err) { $err } else { $RawText })"
        }
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    if ($parsed) {
        [void]$candidates.Add($parsed)
        foreach ($wrap in @('body', 'data', 'result', 'payload', 'item')) {
            $inner = Get-CheckDomainJsonProperty -Object $parsed -Names @($wrap)
            if ($inner) {
                try {
                    [void]$candidates.Add(($inner | ConvertFrom-Json))
                } catch { }
            }
            $nested = $parsed.PSObject.Properties[$wrap]
            if ($nested -and $nested.Value -is [psobject]) {
                [void]$candidates.Add($nested.Value)
            }
        }
    }

    $userId = $null
    $lastName = $null
    $firstName = $null
    $displayName = $null
    $fullName = $null
    $genericName = $null
    foreach ($obj in $candidates) {
        if (-not $userId) {
            $userId = Get-CheckDomainJsonProperty -Object $obj -Names @(
                'userID', 'userId', 'UserID', 'UserId', 'user_id', 'userid')
        }
        if (-not $lastName) {
            $lastName = Get-CheckDomainJsonProperty -Object $obj -Names @(
                'lastName', 'LastName', 'last_name', 'lastname')
        }
        if (-not $firstName) {
            $firstName = Get-CheckDomainJsonProperty -Object $obj -Names @(
                'firstName', 'FirstName', 'first_name')
        }
        if (-not $displayName) {
            $displayName = Get-CheckDomainJsonProperty -Object $obj -Names @(
                'displayName', 'DisplayName', 'display_name')
        }
        if (-not $fullName) {
            $fullName = Get-CheckDomainJsonProperty -Object $obj -Names @(
                'fullName', 'FullName', 'full_name')
        }
        if (-not $genericName) {
            $genericName = Get-CheckDomainJsonProperty -Object $obj -Names @('name', 'Name')
        }
        if ($userId -and $lastName) { break }
    }

    if (-not $userId -and $RawText -match '"(?:userID|userId|user_id)"\s*:\s*"([^"]+)"') {
        $userId = $Matches[1].Trim()
    }
    if (-not $lastName -and $RawText -match '"lastName"\s*:\s*"([^"]+)"') {
        $lastName = $Matches[1]
    }

    # Explorer label prefers lastName (e.g. Viet Storage); other fields only when lastName is absent.
    $labelName = $null
    foreach ($candidate in @($lastName, $firstName, $displayName, $fullName, $genericName)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $labelName = $candidate.Trim()
            break
        }
    }

    if (-not $userId) {
        $preview = if ($RawText.Length -gt 400) { $RawText.Substring(0, 400) + '...' } else { $RawText }
        throw "checkDomain response missing userID. Raw: $preview"
    }

    # Single property name: PowerShell hash/pscustomobject keys are case-insensitive (userID == userId).
    return [pscustomobject]@{
        userID    = $userId
        lastName  = $lastName
        labelName = $labelName
    }
}

function Invoke-CheckDomainApiViaCurl {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$ApiUrl,
        [ValidateSet('GET', 'POST')]
        [string]$Method = 'GET',
        [int]$TimeoutSec = 30
    )
    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        return $null
    }

    $body = Get-CheckDomainRequestBody -Domain $Domain
    $bodyFile = Join-Path $env:TEMP ("nextgpu-checkdomain-$([Guid]::NewGuid().ToString('N')).json")
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($bodyFile, $body, $utf8NoBom)
        $out = & curl.exe -sS --max-time $TimeoutSec -X $Method $ApiUrl `
            -H 'Content-Type: application/json' `
            --data-binary "@$bodyFile" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "curl exit $LASTEXITCODE : $out"
        }
        $text = ($out | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw 'curl returned empty body'
        }
        return $text
    } finally {
        Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-CheckDomainApiViaHttpClient {
    <#
    .SYNOPSIS
        GET with JSON body (HttpWebRequest cannot send a body on GET in .NET).
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$ApiUrl,
        [ValidateSet('GET', 'POST')]
        [string]$Method = 'GET',
        [int]$TimeoutSec = 30
    )
    $null = [System.Reflection.Assembly]::LoadWithPartialName('System.Net.Http')
    $handler = New-Object System.Net.Http.HttpClientHandler
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    try {
        $body = Get-CheckDomainRequestBody -Domain $Domain
        $content = New-Object System.Net.Http.StringContent($body, [System.Text.Encoding]::UTF8, 'application/json')
        if ($Method -eq 'GET') {
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $ApiUrl)
            $request.Content = $content
            $response = $client.SendAsync($request).ConfigureAwait($false).GetAwaiter().GetResult()
        } else {
            $response = $client.PostAsync($ApiUrl, $content).ConfigureAwait($false).GetAwaiter().GetResult()
        }
        $text = $response.Content.ReadAsStringAsync().ConfigureAwait($false).GetAwaiter().GetResult()
        if (-not $response.IsSuccessStatusCode) {
            throw "HTTP $([int]$response.StatusCode): $text"
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            throw 'empty response body'
        }
        return $text
    } finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-CheckDomainApiTryMethod {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action,
        [System.Collections.Generic.List[string]]$Errors,
        [ref]$LastApiError
    )
    try {
        $text = & $Action
        if ($null -eq $text) {
            [void]$Errors.Add("${Name}: not available (curl missing or skipped)")
            return $null
        }
        if (Test-CheckDomainApiResponseSuccess -RawText $text) {
            return $text
        }
        $apiErr = Get-CheckDomainApiErrorFromBody -RawText $text
        if ($apiErr) {
            $LastApiError.Value = $apiErr
            [void]$Errors.Add("${Name}: $apiErr")
        } else {
            $preview = if ($text.Length -gt 160) { $text.Substring(0, 160) + '...' } else { $text }
            [void]$Errors.Add("${Name}: $preview")
        }
    } catch {
        [void]$Errors.Add("${Name}: $($_.Exception.Message)")
    }
    return $null
}

function Invoke-CheckDomainApi {
    param(
        [Parameter(Mandatory)][string]$Domain,
        [string]$ApiUrl = $script:NextGpuCheckDomainUrl,
        [int]$TimeoutSec = 30
    )
    if ($env:NEXTGPU_CHECK_DOMAIN_URL) {
        $ApiUrl = $env:NEXTGPU_CHECK_DOMAIN_URL.Trim()
    }

    $errors = New-Object System.Collections.Generic.List[string]
    $lastApiError = ''
    $queryUrl = '{0}?domain={1}' -f $ApiUrl, [Uri]::EscapeDataString($Domain.Trim())

    # Live API: GET + JSON body only (POST /checkDomain returns 404). Needs active machine session in backend.
    $attempts = @(
        @{
            Name = 'curl GET+JSON body'
            Action = { Invoke-CheckDomainApiViaCurl -Domain $Domain -ApiUrl $ApiUrl -Method GET -TimeoutSec $TimeoutSec }
        }
        @{
            Name = 'HttpClient GET+JSON body'
            Action = { Invoke-CheckDomainApiViaHttpClient -Domain $Domain -ApiUrl $ApiUrl -Method GET -TimeoutSec $TimeoutSec }
        }
        @{
            Name = 'GET querystring'
            Action = {
                $response = Invoke-WebRequest -Uri $queryUrl -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing
                return $response.Content
            }
        }
    )

    $rawText = $null
    $apiErrRef = [ref]$lastApiError
    foreach ($attempt in $attempts) {
        $rawText = Invoke-CheckDomainApiTryMethod -Name $attempt.Name -Action $attempt.Action -Errors $errors -LastApiError $apiErrRef
        if ($rawText) { break }
    }

    if ([string]::IsNullOrWhiteSpace($rawText)) {
        $detail = if ($lastApiError) { $lastApiError } else { $errors -join '; ' }
        throw "checkDomain failed for domain '$Domain': $detail"
    }

    return ConvertFrom-CheckDomainResponse -RawText $rawText
}

function Invoke-CheckDomainApiWithRetry {
    <#
    .SYNOPSIS
        Retry wrapper for transient checkDomain/API network failures.
    #>
    param(
        [Parameter(Mandatory)][string]$Domain,
        [int]$RetryCount = $script:NextGpuUserStorageCheckDomainRetryCount,
        [int]$TimeoutSec = 30,
        [string]$LogFile = ''
    )

    if ($RetryCount -lt 1) { $RetryCount = 1 }
    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            return Invoke-CheckDomainApi -Domain $Domain -TimeoutSec $TimeoutSec
        } catch {
            $lastError = $_
            Write-UserStorageLog -Message "checkDomain attempt $attempt/$RetryCount failed: $($_.Exception.Message)" `
                -Level WARN -LogFile $LogFile
            if ($attempt -lt $RetryCount) {
                Start-Sleep -Seconds ([Math]::Min(8, 2 * $attempt))
            }
        }
    }
    if ($lastError) {
        throw $lastError
    }
    throw "checkDomain failed for domain '$Domain'"
}

function Get-UserStorageRcloneMountExtraArgs {
    <#
    .SYNOPSIS
        S3 mount: prefer --skip-links (symlink at prefix root otherwise kills mount on newer rclone). No --poll-interval.
    #>
    param(
        [Parameter(Mandatory)][string]$RcloneExe,
        [string]$VolumeLabel = ''
    )
    $help = ''
    try {
        $help = (& $RcloneExe mount --help 2>&1 | Out-String)
    } catch {
        return @('--allow-non-empty')
    }

    $extra = New-Object System.Collections.Generic.List[string]
    if ($help -match '(?m)--skip-links\b') {
        [void]$extra.Add('--skip-links')
    } elseif ($help -match '(?m)--links\b') {
        [void]$extra.Add('--links')
    }
    if ($help -match '(?m)--allow-non-empty\b') {
        [void]$extra.Add('--allow-non-empty')
    }
    if (-not [string]::IsNullOrWhiteSpace($VolumeLabel) -and ($help -match '(?m)--volname\b')) {
        # One argv only. Two-arg form (--volname + value) breaks under cmd/Start-Process when label has spaces/apostrophe
        # (rclone then sees a 3rd positional arg "Storage" from "Viet's Storage").
        $name = $VolumeLabel.Trim().Replace('"', '')
        [void]$extra.Add('--volname="' + $name + '"')
    }
    return $extra.ToArray()
}

function Get-UserStorageMountFailureDetails {
    param(
        [string]$MountLog = '',
        [string]$StderrLog = '',
        [int]$TailLines = 20
    )
    $parts = New-Object System.Collections.Generic.List[string]
    if ($StderrLog -and (Test-Path -LiteralPath $StderrLog)) {
        $errTail = @(Get-Content -LiteralPath $StderrLog -Tail $TailLines -ErrorAction SilentlyContinue)
        if ($errTail.Count) {
            [void]$parts.Add('rclone stderr:')
            $errTail | ForEach-Object { [void]$parts.Add($_) }
        }
    }
    if ($MountLog -and (Test-Path -LiteralPath $MountLog)) {
        $all = @(Get-Content -LiteralPath $MountLog -Tail 80 -ErrorAction SilentlyContinue)
        $today = (Get-Date).ToString('yyyy/MM/dd')
        $today2 = (Get-Date).ToString('yyyy-MM-dd')
        $recent = @($all | Where-Object { $_ -match [regex]::Escape($today) -or $_ -match [regex]::Escape($today2) })
        if ($recent.Count -gt $TailLines) {
            $recent = @($recent | Select-Object -Last $TailLines)
        }
        if ($recent.Count) {
            [void]$parts.Add('mount log (today):')
            $recent | ForEach-Object { [void]$parts.Add($_) }
        } else {
            $old = @($all | Select-Object -Last $TailLines)
            if ($old.Count) {
                [void]$parts.Add('mount log (tail; may be older run - Sync scripts from repo):')
                $old | ForEach-Object { [void]$parts.Add($_) }
            }
        }
    }
    if ($parts.Count -eq 0) { return '(no rclone output captured)' }
    return ($parts -join [Environment]::NewLine)
}

function Test-NextGpuUserIdFormat {
    param([Parameter(Mandatory)][string]$UserId)
    return ($UserId -match '^user_[A-Za-z0-9]+$')
}

function Get-UserStorageS3ConsoleUrl {
    param([Parameter(Mandatory)][string]$UserId)
    $key = $UserId.Trim().TrimEnd('/') + '/'
    return "https://$($script:NextGpuUserStorageBucket).s3.$($script:NextGpuUserStorageRegion).amazonaws.com/$key"
}

function Get-UserStorageRemotePathCandidatesForUserId {
    param([Parameter(Mandatory)][string]$UserId)
    $remote = $script:NextGpuUserStorageRemoteName
    $bucket = $script:NextGpuUserStorageBucket
    $userPart = $UserId.Trim().TrimEnd('/')
    return @(
        ('{0}:{1}/{2}/' -f $remote, $bucket, $userPart)
        ('{0}:{1}/' -f $remote, $userPart)
    )
}

function Get-UserStorageRemotePathForUserId {
    param(
        [Parameter(Mandatory)][string]$UserId,
        [string]$RcloneExe = '',
        [string]$ConfigPath = $script:NextGpuUserStorageRcloneConfigPath
    )
    $candidates = Get-UserStorageRemotePathCandidatesForUserId -UserId $UserId
    if ([string]::IsNullOrWhiteSpace($RcloneExe)) {
        $RcloneExe = Get-RcloneExeForUserStorage
    }
    if (-not $RcloneExe -or -not (Test-Path -LiteralPath $ConfigPath)) {
        return $candidates[0]
    }

    $cfg = @('--config', $ConfigPath)
    foreach ($path in $candidates) {
        $test = Invoke-UserStorageRcloneQuiet -RcloneExe $RcloneExe -ArgumentList ($cfg + @('lsf', $path, '--max-depth', '1'))
        if ($test.ExitCode -eq 0) {
            return $path
        }
    }
    return $candidates[0]
}

function Test-UserStorageRemotePathReachable {
    param(
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string]$RemotePath,
        [string]$ConfigPath = $script:NextGpuUserStorageRcloneConfigPath
    )
    if (-not $RcloneExe -or -not (Test-Path -LiteralPath $ConfigPath)) {
        return $false
    }
    $probe = Invoke-UserStorageRcloneQuiet -RcloneExe $RcloneExe -ArgumentList @(
        '--config', $ConfigPath, 'lsf', $RemotePath, '--max-depth', '1'
    )
    return ($probe.ExitCode -eq 0)
}

function Test-UserStorageRcloneListsMultipleBuckets {
    param(
        [Parameter(Mandatory)][string]$RcloneExe,
        [string]$ConfigPath = $script:NextGpuUserStorageRcloneConfigPath
    )
    $remote = $script:NextGpuUserStorageRemoteName
    $bucket = $script:NextGpuUserStorageBucket
    $cfg = @('--config', $ConfigPath)
    $rootDirs = Invoke-UserStorageRcloneQuiet -RcloneExe $RcloneExe -ArgumentList ($cfg + @(
            'lsf', "${remote}:", '--dirs-only', '--max-depth', '1'
        ))
    if ($rootDirs.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($rootDirs.Output)) {
        return $false
    }
    $names = @($rootDirs.Output -split "[\r\n]+" | ForEach-Object { $_.Trim().TrimEnd('/') } | Where-Object { $_ })
    return ($names -contains $bucket)
}

function Invoke-UserStorageRcloneQuiet {
    param(
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $RcloneExe @ArgumentList 2>&1
        return @{
            ExitCode = $LASTEXITCODE
            Output   = ($out | Out-String).Trim()
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Test-UserStorageS3Access {
    param(
        [Parameter(Mandatory)][string]$RcloneExe,
        [Parameter(Mandatory)][string]$UserId,
        [string]$ConfigPath = $script:NextGpuUserStorageRcloneConfigPath
    )
    $remote = $script:NextGpuUserStorageRemoteName
    $bucket = $script:NextGpuUserStorageBucket
    $region = $script:NextGpuUserStorageRegion
    $rclonePath = Get-UserStorageRemotePathForUserId -UserId $UserId -RcloneExe $RcloneExe -ConfigPath $ConfigPath

    $result = [ordered]@{
        Ok               = $false
        Summary          = ''
        ExpectedUrl      = Get-UserStorageS3ConsoleUrl -UserId $UserId
        RclonePath       = $rclonePath
        Bucket           = $bucket
        Region           = $region
        MultiBucketRoot  = $false
        PrefixReachable  = $false
        PrefixEmpty      = $false
        Lines            = New-Object System.Collections.Generic.List[string]
    }

    $cfg = @('--config', $ConfigPath)
    $multiBucket = Test-UserStorageRcloneListsMultipleBuckets -RcloneExe $RcloneExe -ConfigPath $ConfigPath
    $result.MultiBucketRoot = $multiBucket
    if ($multiBucket) {
        [void]$result.Lines.Add("remote root lists AWS buckets (not inside $bucket); using path $rclonePath")
    }

    $lsfPrefix = Invoke-UserStorageRcloneQuiet -RcloneExe $RcloneExe -ArgumentList ($cfg + @('lsf', $rclonePath, '--max-depth', '1'))
    if ($lsfPrefix.ExitCode -eq 0) {
        $result.PrefixReachable = $true
        if ([string]::IsNullOrWhiteSpace($lsfPrefix.Output)) {
            $result.PrefixEmpty = $true
            [void]$result.Lines.Add("lsf $rclonePath : OK (empty prefix - mount still works)")
        } else {
            $sample = ($lsfPrefix.Output -split '\r?\n' | Select-Object -First 3) -join ', '
            [void]$result.Lines.Add("lsf $rclonePath : OK - $sample")
        }
        $result.Ok = $true
        $result.Summary = if ($result.PrefixEmpty) {
            'Prefix reachable (empty).'
        } else {
            'S3 prefix reachable.'
        }
        return [pscustomobject]$result
    }

    [void]$result.Lines.Add("lsf $rclonePath : $($lsfPrefix.Output)")
    $shortPath = "{0}:{1}/" -f $remote, $UserId.Trim().TrimEnd('/')
    if ($rclonePath -ne $shortPath) {
        $tryShort = Invoke-UserStorageRcloneQuiet -RcloneExe $RcloneExe -ArgumentList ($cfg + @('lsf', $shortPath, '--max-depth', '1'))
        [void]$result.Lines.Add("lsf $shortPath : $(if ($tryShort.ExitCode -eq 0) { 'OK' } else { $tryShort.Output })")
    }

    $result.Summary = @(
        "Use rclone path $rclonePath (bucket $bucket + user folder)."
        "Wrong: $shortPath when remote lists multiple buckets at root."
        "S3 object URL: $($result.ExpectedUrl)"
    ) -join ' '
    return [pscustomobject]$result
}

function Get-UserStorageVolumeLabel {
    param([Parameter(Mandatory)][string]$LastName)
    $base = if ([string]::IsNullOrWhiteSpace($LastName)) { 'User' } else { $LastName.Trim() }
    $base = $base.Trim([char]0x2018, [char]0x2019, [char]0x0027, '"')
    $label = ('{0}''s Storage' -f $base)
    $invalid = @('\', '/', ':', '*', '?', '"', '<', '>', '|')
    foreach ($c in $invalid) {
        $label = $label.Replace([string]$c, '')
    }
    if ($label.Length -gt 32) {
        $label = $label.Substring(0, 32)
    }
    return $label.Trim()
}

function Get-UserStorageCurrentVolumeLabel {
    param([string]$DriveLetter = 'U')
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    if (Get-Command Get-Volume -ErrorAction SilentlyContinue) {
        try {
            $vol = Get-Volume -DriveLetter $letter -ErrorAction Stop
            if ($vol.FileSystemLabel) { return [string]$vol.FileSystemLabel }
        } catch { }
    }
    try {
        $wmi = Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='${letter}:'" -ErrorAction Stop
        if ($wmi -and $wmi.Label) { return [string]$wmi.Label }
    } catch { }
    return ''
}

function Test-UserStorageMountLockHeld {
    param([int]$MaxAgeSeconds = 180)
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageMountLockPath)) {
        return $false
    }
    $age = ((Get-Date) - (Get-Item -LiteralPath $script:NextGpuUserStorageMountLockPath).LastWriteTime).TotalSeconds
    if ($age -gt $MaxAgeSeconds) {
        Remove-UserStorageMountLock -Force
        return $false
    }
    return $true
}

function Set-UserStorageMountLock {
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageProgramData)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageProgramData -Force | Out-Null
    }
    Set-Content -LiteralPath $script:NextGpuUserStorageMountLockPath -Value (Get-Date).ToString('o') -Encoding UTF8 -Force
}

function Remove-UserStorageMountLock {
    param([switch]$Force)
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageMountLockPath)) { return }
    if ($Force) {
        Remove-Item -LiteralPath $script:NextGpuUserStorageMountLockPath -Force -ErrorAction SilentlyContinue
        return
    }
    Remove-Item -LiteralPath $script:NextGpuUserStorageMountLockPath -Force -ErrorAction SilentlyContinue
}

function Test-UserStorageHealthyMount {
    param([string]$DriveLetter = 'U')
    if (-not (Test-UserStorageAlreadyMounted -DriveLetter $DriveLetter)) {
        return $false
    }
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $label = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
    return (-not [string]::IsNullOrWhiteSpace($label))
}

function Test-UserStorageMountMatchesTenant {
    <#
    .SYNOPSIS
        True when U: is mounted for the current checkDomain tenant (userID + optional label).
    #>
    param(
        [string]$DriveLetter = 'U',
        [Parameter(Mandatory)][string]$ExpectedUserId,
        [string]$ExpectedLabel = ''
    )
    if (-not (Test-UserStorageHealthyMount -DriveLetter $DriveLetter)) {
        return $false
    }
    $state = Get-UserStorageState
    if (-not $state -or -not $state.userId) {
        return $false
    }
    if ([string]$state.userId -ne $ExpectedUserId) {
        return $false
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLabel)) {
        $actualLabel = Get-UserStorageCurrentVolumeLabel -DriveLetter $DriveLetter
        if ($actualLabel -ne $ExpectedLabel) {
            return $false
        }
    }
    return $true
}

function Prepare-UserStorageForNewMount {
    <#
    .SYNOPSIS
        Clear only stale/broken U: mounts. Keeps a healthy live mount (avoids trigger races killing rclone).
    #>
    param(
        [string]$DriveLetter = 'U',
        [string]$UnmountScriptPath = '',
        [string]$LogFile = '',
        [switch]$ForceRemount
    )
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $drivePath = "${letter}:"

    if ((-not $ForceRemount) -and (Test-UserStorageHealthyMount -DriveLetter $letter)) {
        $label = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
        $mountedUser = ''
        $st = Get-UserStorageState
        if ($st -and $st.userId) { $mountedUser = [string]$st.userId }
        Write-UserStorageLog "Drive ${letter}: healthy mount in place (label: '$label', userId: $mountedUser); skip cleanup." -Level OK -LogFile $LogFile
        return
    }
    if ($ForceRemount) {
        Write-UserStorageLog "Force remount: clearing U: for new tenant or stale mount." -Level WARN -LogFile $LogFile
    }

    $beforeLabel = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
    if ($beforeLabel) {
        Write-UserStorageLog "Drive ${letter}: label before cleanup: '$beforeLabel'" -Level INFO -LogFile $LogFile
    }

    if ([string]::IsNullOrWhiteSpace($UnmountScriptPath)) {
        $UnmountScriptPath = Join-Path $PSScriptRoot 'Unmount-UserStorage.ps1'
        if (-not (Test-Path -LiteralPath $UnmountScriptPath)) {
            $UnmountScriptPath = Get-NextGpuUserStoragePublishedScriptPath -ScriptName 'Unmount-UserStorage.ps1'
        }
    }
    if (Test-Path -LiteralPath $UnmountScriptPath) {
        Write-UserStorageLog 'Preparing session: clearing stale user-storage mount...' -Level INFO -LogFile $LogFile
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $UnmountScriptPath -Quiet
    } else {
        Stop-UserStorageMountProcess -DriveLetter $letter
        Clear-UserStorageState
    }
    Remove-UserStorageMountLock -Force

    if (Test-Path -LiteralPath $drivePath) {
        Write-UserStorageLog "Drive ${letter}: still present after cleanup; mount will retry." -Level WARN -LogFile $LogFile
    }
}

function Get-UserStorageState {
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageStatePath)) {
        return $null
    }
    try {
        return (Get-Content -LiteralPath $script:NextGpuUserStorageStatePath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-UserStorageLog "Could not parse state file: $($_.Exception.Message)" -Level WARN
        return $null
    }
}

function Set-UserStorageState {
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][int]$MountPid,
        [int]$SessionId = -1
    )
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageProgramData)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageProgramData -Force | Out-Null
    }
    if ($SessionId -lt 0) {
        $SessionId = [int](Get-Process -Id $PID).SessionId
    }
    $state = [ordered]@{
        driveLetter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
        userId      = $UserId
        mountPid    = $MountPid
        sessionId   = $SessionId
        mountedAt   = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:NextGpuUserStorageStatePath -Encoding UTF8 -Force
}

function Set-UserStorageStateSafe {
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][int]$MountPid,
        [string]$LogFile = ''
    )
    try {
        Set-UserStorageState -DriveLetter $DriveLetter -UserId $UserId -MountPid $MountPid
        return $true
    } catch {
        Write-UserStorageLog -Message "State write failed under ProgramData: $($_.Exception.Message)" -Level WARN -LogFile $LogFile
        try {
            $null = Set-NextGpuRentalUserStorageAccess
            Set-UserStorageState -DriveLetter $DriveLetter -UserId $UserId -MountPid $MountPid
            Write-UserStorageLog -Message 'State write succeeded after ACL refresh.' -Level OK -LogFile $LogFile
            return $true
        } catch {
            Write-UserStorageLog -Message "State write still failing after ACL refresh: $($_.Exception.Message)" -Level WARN -LogFile $LogFile
            return $false
        }
    }
}

function Clear-UserStorageState {
    if (Test-Path -LiteralPath $script:NextGpuUserStorageStatePath) {
        Remove-Item -LiteralPath $script:NextGpuUserStorageStatePath -Force -ErrorAction SilentlyContinue
    }
}

function Get-NextGpuUserStorageProgramFilesRclone {
    return Join-Path $env:ProgramFiles 'rclone\rclone.exe'
}

function Find-RcloneExeOnSystem {
    $found = New-Object System.Collections.Generic.List[string]
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { [void]$found.Add($cmd.Source) }

    foreach ($candidate in @(
            (Get-NextGpuUserStorageProgramFilesRclone)
            "${env:ProgramFiles}\Rclone\rclone.exe"
            "${env:ProgramFiles(x86)}\rclone\rclone.exe"
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\rclone.exe')
            'C:\ProgramData\chocolatey\bin\rclone.exe'
        )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            [void]$found.Add($candidate)
        }
    }

    foreach ($packagesRoot in @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
            (Join-Path $env:ProgramData 'Microsoft\WinGet\Packages')
        )) {
        if (-not (Test-Path -LiteralPath $packagesRoot)) { continue }
        Get-ChildItem -Path $packagesRoot -Filter 'Rclone.Rclone*' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                Get-ChildItem -Path $_.FullName -Filter 'rclone.exe' -Recurse -File -ErrorAction SilentlyContinue |
                    ForEach-Object { [void]$found.Add($_.FullName) }
            }
    }

    return ($found | Select-Object -Unique)
}

function Get-RcloneExeForUserStorage {
    $all = Find-RcloneExeOnSystem
    if (-not $all -or $all.Count -eq 0) { return $null }

    $machine = Get-NextGpuUserStorageProgramFilesRclone
    foreach ($path in $all) {
        if ($path -ieq $machine) { return $path }
    }
    foreach ($path in $all) {
        if ($path -like '*\Program Files\*') { return $path }
    }
    return $all[0]
}

function Install-RcloneForAllUsers {
    $targetExe = Get-NextGpuUserStorageProgramFilesRclone
    if (Test-Path -LiteralPath $targetExe) {
        return $targetExe
    }

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Host '[*] Installing rclone (machine scope)...'
        winget.exe install --id Rclone.Rclone -e --scope machine `
            --accept-source-agreements --accept-package-agreements 2>&1 |
            ForEach-Object { Write-Host $_ }
    } else {
        Write-Warning 'winget.exe not found. Install "App Installer" from Microsoft Store, or rclone will be downloaded from GitHub.'
    }

    $source = Get-RcloneExeForUserStorage
    if (-not $source) {
        $candidates = Find-RcloneExeOnSystem
        if ($candidates -and $candidates.Count -gt 0) {
            $source = $candidates[0]
        }
    }
    if (-not $source) {
        try {
            $source = Install-RcloneFromGitHubRelease
        } catch {
            Write-Warning "rclone GitHub download install: $($_.Exception.Message)"
        }
    }
    if (-not $source) {
        return $null
    }

    if ($source -ieq $targetExe) {
        return $targetExe
    }

    $targetDir = Split-Path -Parent $targetExe
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Write-Host "[*] Publishing rclone for all users: $targetExe"
    Copy-Item -LiteralPath $source -Destination $targetExe -Force
    return $targetExe
}

function Find-WinFspMsiOnSystem {
    foreach ($packagesRoot in @(
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages')
            (Join-Path $env:ProgramData 'Microsoft\WinGet\Packages')
        )) {
        if (-not (Test-Path -LiteralPath $packagesRoot)) { continue }
        Get-ChildItem -Path $packagesRoot -Filter 'WinFsp.WinFsp*' -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $msi = Get-ChildItem -Path $_.FullName -Filter 'winfsp*.msi' -Recurse -File -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if ($msi) { return $msi.FullName }
            }
    }
    return $null
}

function Get-WinFspBinDirectory {
    foreach ($binDir in @(
            (Join-Path ${env:ProgramFiles} 'WinFsp\bin')
            (Join-Path ${env:ProgramFiles(x86)} 'WinFsp\bin')
        )) {
        if (Test-Path -LiteralPath (Join-Path $binDir 'winfsp-x64.dll')) { return $binDir }
        if (Test-Path -LiteralPath (Join-Path $binDir 'winfsp-x86.dll')) { return $binDir }
    }

    foreach ($root in @(
            (Join-Path ${env:ProgramFiles} 'WinFsp')
            (Join-Path ${env:ProgramFiles(x86)} 'WinFsp')
        )) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dll = Get-ChildItem -Path $root -Filter 'winfsp-x64.dll' -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($dll) { return $dll.DirectoryName }
        $dll86 = Get-ChildItem -Path $root -Filter 'winfsp-x86.dll' -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($dll86) { return $dll86.DirectoryName }
    }

    $fsptool = Get-Command fsptool.exe -ErrorAction SilentlyContinue
    if ($fsptool) { return (Split-Path -Parent $fsptool.Source) }
    return $null
}

function Test-WinFspInstalled {
    return [bool](Get-WinFspBinDirectory)
}

function Test-WinFspMsiExitSuccess {
    param([int]$ExitCode)
    # 0=ok, 3010=success restart not invoked, 1638=already installed, 1641=restart initiated
    return $ExitCode -eq 0 -or $ExitCode -eq 3010 -or $ExitCode -eq 1638 -or $ExitCode -eq 1641
}

function Install-WinFspFromMsi {
    param([Parameter(Mandatory)][string]$MsiPath)
    if (-not (Test-Path -LiteralPath $MsiPath)) {
        throw "WinFsp MSI not found: $MsiPath"
    }

    if (Test-WinFspInstalled) { return }

    $logPath = Join-Path $env:TEMP 'nextgpu-winfsp-install.log'
    Write-Host "[*] Running WinFsp MSI (no reboot): $MsiPath"
    Write-Host "    Log: $logPath"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @(
        '/i', $MsiPath, '/qn', '/norestart', '/l*v', $logPath
    ) -Wait -PassThru -WindowStyle Hidden

    Write-Host "    msiexec exit code: $($proc.ExitCode)"
    if (Test-WinFspInstalled) { return }
    if (Test-WinFspMsiExitSuccess -ExitCode $proc.ExitCode) {
        Start-Sleep -Seconds 2
        if (Test-WinFspInstalled) { return }
    }

    throw "WinFsp MSI exit code $($proc.ExitCode). See $logPath"
}

function Install-WinFspIfMissing {
    if (Test-WinFspInstalled) { return $true }

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        Write-Host '[*] Installing WinFsp (machine scope, no reboot)...'
        winget.exe install --id WinFsp.WinFsp -e --scope machine `
            --accept-source-agreements --accept-package-agreements 2>&1 |
            ForEach-Object { Write-Host $_ }
    }

    if (Test-WinFspInstalled) { return $true }

    $msi = Find-WinFspMsiOnSystem
    if ($msi) {
        try {
            Install-WinFspFromMsi -MsiPath $msi
        } catch {
            Write-Warning $_.Exception.Message
        }
    }

    if (Test-WinFspInstalled) { return $true }

    try {
        Install-WinFspFromGitHubRelease
    } catch {
        Write-Warning "WinFsp download install: $($_.Exception.Message)"
    }

    if (Test-WinFspInstalled) { return $true }

    $bin = Get-WinFspBinDirectory
    if ($bin) {
        Write-Host "[OK] WinFsp binaries: $bin" -ForegroundColor Green
        return $true
    }

    Write-Warning 'WinFsp not detected under Program Files or Program Files (x86).'
    Write-Warning "Check %TEMP%\nextgpu-winfsp-install.log then re-run Setup-UserStorage.bat as Administrator."
    return $false
}

function Install-WinFspFromGitHubRelease {
    $headers = @{ 'User-Agent' = 'nextGPU-user-storage-setup' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/winfsp/winfsp/releases/latest' -Headers $headers
    $asset = $release.assets | Where-Object { $_.name -match '\.msi$' } | Select-Object -First 1
    if (-not $asset) {
        throw 'No .msi asset on latest WinFsp GitHub release'
    }
    $msiPath = Join-Path $env:TEMP $asset.name
    Write-Host "[*] Downloading WinFsp: $($asset.browser_download_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $msiPath -UseBasicParsing
    Install-WinFspFromMsi -MsiPath $msiPath
}

function Install-RcloneFromGitHubRelease {
    $targetExe = Get-NextGpuUserStorageProgramFilesRclone
    if (Test-Path -LiteralPath $targetExe) {
        return $targetExe
    }

    $headers = @{ 'User-Agent' = 'nextGPU-user-storage-setup' }
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/rclone/rclone/releases/latest' -Headers $headers
    $asset = $release.assets | Where-Object { $_.name -match 'windows-amd64\.zip$' } | Select-Object -First 1
    if (-not $asset) {
        throw 'No windows-amd64.zip asset on latest rclone GitHub release'
    }

    $zipPath = Join-Path $env:TEMP $asset.name
    Write-Host "[*] Downloading rclone: $($asset.browser_download_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zipPath -UseBasicParsing

    $extractDir = Join-Path $env:TEMP 'nextgpu-rclone-extract'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $exe = Get-ChildItem -Path $extractDir -Filter 'rclone.exe' -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $exe) {
        throw 'rclone.exe not found inside release zip'
    }

    $targetDir = Split-Path -Parent $targetExe
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    Write-Host "[*] Publishing rclone for all users: $targetExe"
    Copy-Item -LiteralPath $exe.FullName -Destination $targetExe -Force
    return $targetExe
}

function Install-RcloneIfMissing {
    $exe = Install-RcloneForAllUsers
    return [bool]$exe
}

function Ensure-UserStoragePrerequisites {
    $rcloneOk = Install-RcloneIfMissing
    $winFspOk = Install-WinFspIfMissing
    if (-not $rcloneOk) {
        Write-Host '[ERROR] rclone is missing and could not be installed.' -ForegroundColor Red
        Write-Host '        Manual: winget install Rclone.Rclone -e --scope machine' -ForegroundColor Yellow
        Write-Host '        Need outbound HTTPS to winget CDN or github.com.' -ForegroundColor Yellow
    }
    if (-not $winFspOk) {
        Write-Host '[ERROR] WinFsp is missing and could not be installed.' -ForegroundColor Red
        Write-Host '        Manual: winget install WinFsp.WinFsp -e --scope machine' -ForegroundColor Yellow
        Write-Host "        Log: $env:TEMP\nextgpu-winfsp-install.log" -ForegroundColor Yellow
    }
    return ($rcloneOk -and $winFspOk)
}

function Test-IsCurrentUserAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-UserStoragePrerequisitesIfAdmin {
    if (-not (Test-IsCurrentUserAdministrator)) {
        return $false
    }
    return Ensure-UserStoragePrerequisites
}

function Get-UserStorageS3Credentials {
    $access = $env:NEXTGPU_USER_S3_ACCESS_KEY
    $secret = $env:NEXTGPU_USER_S3_SECRET_KEY
    if ($access -and $secret) {
        return @{ AccessKeyId = $access; SecretAccessKey = $secret; Source = 'environment' }
    }

    $secretsFile = Join-Path $script:NextGpuUserStorageSecretsDir 'user-s3.env'
    if (-not (Test-Path -LiteralPath $secretsFile)) {
        return $null
    }
    $vars = @{}
    foreach ($line in Get-Content -LiteralPath $secretsFile) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $idx = $line.IndexOf('=')
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $vars[$key] = $val
    }
    $fileAccess = $vars['NEXTGPU_USER_S3_ACCESS_KEY']
    $fileSecret = $vars['NEXTGPU_USER_S3_SECRET_KEY']
    if ($fileAccess -and $fileSecret) {
        return @{ AccessKeyId = $fileAccess; SecretAccessKey = $fileSecret; Source = $secretsFile }
    }
    return $null
}

function Save-UserStorageS3SecretsFile {
    param(
        [Parameter(Mandatory)][string]$AccessKeyId,
        [Parameter(Mandatory)][string]$SecretAccessKey
    )
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageSecretsDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageSecretsDir -Force | Out-Null
    }
    $secretsFile = Join-Path $script:NextGpuUserStorageSecretsDir 'user-s3.env'
    $content = @(
        '# Created by Install-UserStorageRcloneConfig.ps1 - do not commit to git.'
        "NEXTGPU_USER_S3_ACCESS_KEY=$AccessKeyId"
        "NEXTGPU_USER_S3_SECRET_KEY=$SecretAccessKey"
    )
    Set-Content -LiteralPath $secretsFile -Value $content -Encoding UTF8 -Force
    try {
        $acl = Get-Acl -LiteralPath $secretsFile
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $null = $acl.RemoveAccessRule($_) }
        $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $system, 'FullControl', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $admins, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $secretsFile -AclObject $acl
    } catch {
        Write-Warning "Could not tighten ACL on user-s3.env: $($_.Exception.Message)"
    }
    return $secretsFile
}

function Set-UserStorageS3MachineEnvironment {
    param(
        [Parameter(Mandatory)][string]$AccessKeyId,
        [Parameter(Mandatory)][string]$SecretAccessKey
    )
    [Environment]::SetEnvironmentVariable('NEXTGPU_USER_S3_ACCESS_KEY', $AccessKeyId, 'Machine')
    [Environment]::SetEnvironmentVariable('NEXTGPU_USER_S3_SECRET_KEY', $SecretAccessKey, 'Machine')
    $env:NEXTGPU_USER_S3_ACCESS_KEY = $AccessKeyId
    $env:NEXTGPU_USER_S3_SECRET_KEY = $SecretAccessKey
}

function Request-UserStorageS3Credentials {
    <#
    .SYNOPSIS
        Prompt for AWS keys when env/secrets file are missing. Returns hashtable or $null if cancelled.
    #>
    param([switch]$AllowSave)

    Write-Host ''
    Write-Host 'AWS credentials for per-user S3 storage (bucket next-gpu-storage).' -ForegroundColor Cyan
    Write-Host 'Keys are stored only on this machine - never commit them to git.' -ForegroundColor DarkGray
    Write-Host ''

    $access = (Read-Host 'AWS Access Key ID (NEXTGPU_USER_S3_ACCESS_KEY)').Trim()
    if ([string]::IsNullOrWhiteSpace($access)) {
        Write-Host '[!] Setup cancelled: Access Key ID is required.' -ForegroundColor Yellow
        return $null
    }

    $secretSecure = Read-Host 'AWS Secret Access Key (input hidden)' -AsSecureString
    $secretPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secretSecure)
    try {
        $secret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPtr)
    } finally {
        if ($secretPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPtr)
        }
    }
    if ([string]::IsNullOrWhiteSpace($secret)) {
        Write-Host '[!] Setup cancelled: Secret Access Key is required.' -ForegroundColor Yellow
        return $null
    }

    $result = @{
        AccessKeyId     = $access
        SecretAccessKey = $secret
        Source          = 'prompt'
    }

    if ($AllowSave) {
        Write-Host ''
        $saveChoice = (Read-Host 'Save credentials on this machine? [Y/n]').Trim()
        if ($saveChoice -eq '' -or $saveChoice -match '^[Yy]') {
            $savedPath = Save-UserStorageS3SecretsFile -AccessKeyId $access -SecretAccessKey $secret
            Write-Host "[*] Saved: $savedPath" -ForegroundColor Green
            $result.Source = $savedPath

            $envChoice = (Read-Host 'Also set machine environment variables (recommended for logon tasks)? [Y/n]').Trim()
            if ($envChoice -eq '' -or $envChoice -match '^[Yy]') {
                Set-UserStorageS3MachineEnvironment -AccessKeyId $access -SecretAccessKey $secret
                Write-Host '[*] Machine env vars NEXTGPU_USER_S3_* updated (new processes will see them).' -ForegroundColor Green
            }
        } else {
            Write-Host '[*] Credentials used for this run only (not saved).' -ForegroundColor DarkGray
        }
    }

    return $result
}

function Test-UserStorageRcloneConfigReady {
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageRcloneConfigPath)) {
        return $false
    }
    $text = Get-Content -LiteralPath $script:NextGpuUserStorageRcloneConfigPath -Raw
    return ($text -match "\[$([regex]::Escape($script:NextGpuUserStorageRemoteName))\]")
}

function Set-UserStorageLogDirAcl {
    <#
    .SYNOPSIS
        Users group must write logs (rclone --log-file). rclone.conf ACL is read-only; logs need Modify.
    #>
    param([string]$ExtraWriteUser = '')
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageLogDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageLogDir -Force | Out-Null
    }

    $group = $script:NextGpuRentalAccessGroup
    $ok = $true
    & icacls.exe $script:NextGpuUserStorageLogDir /grant "${group}:(OI)(CI)M" /T 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    # Existing log files may have been created by SYSTEM/Admin; grant append on known names.
    foreach ($name in @(
            'user-storage-mount.log', 'user-storage-rclone-stderr.log', 'user-storage-ensure.log',
            'user-storage.log', 'user-storage-session.log', 'user-storage-unmount.log', 'user-storage-setup.log'
        )) {
        $f = Join-Path $script:NextGpuUserStorageLogDir $name
        if (Test-Path -LiteralPath $f) {
            & icacls.exe $f /grant "${group}:M" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $ok = $false }
        }
    }

    foreach ($rel in @('user-storage.json', 'user-storage-mount.lock')) {
        $f = Join-Path $script:NextGpuUserStorageProgramData $rel
        if (Test-Path -LiteralPath $f) {
            & icacls.exe $f /grant "${group}:M" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { $ok = $false }
        }
    }
    # Create new state/lock files in ProgramData\nextGPU (not under locked-down rclone\).
    & icacls.exe $script:NextGpuUserStorageProgramData /grant "${group}:(M)" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    if (-not $ok) {
        Write-Warning "Log/state ACL grant failed for $group under $($script:NextGpuUserStorageProgramData)"
    }
    return $ok
}

function Test-UserStorageLogDirWritable {
    param([string]$UserName = $env:USERNAME)
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageLogDir)) {
        return $false
    }
    $probe = Join-Path $script:NextGpuUserStorageLogDir (".write-test-$UserName-$PID.txt")
    try {
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding UTF8 -Force -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Test-UserStorageRcloneLogDestinationWritable {
    if (Test-UserStorageLogDirWritable) { return $true }
    $fallbackDir = Join-Path $env:LOCALAPPDATA 'nextGPU\logs'
    try {
        if (-not (Test-Path -LiteralPath $fallbackDir)) {
            New-Item -ItemType Directory -Path $fallbackDir -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $fallbackDir (".write-test-$env:USERNAME-$PID.txt")
        Set-Content -LiteralPath $probe -Value 'ok' -Encoding UTF8 -Force -ErrorAction Stop
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Get-UserStorageRcloneProcessLogFile {
    <#
    .SYNOPSIS
        rclone --log-file must be writable by nextGPU or mount exits with CRITICAL Access denied.
    #>
    $preferred = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-mount.log'
    if (Test-UserStorageLogDirWritable) {
        return $preferred
    }

    $fallbackDir = Join-Path $env:LOCALAPPDATA 'nextGPU\logs'
    if (-not (Test-Path -LiteralPath $fallbackDir)) {
        New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
    }
    $fallback = Join-Path $fallbackDir 'user-storage-mount-rclone.log'
    Write-UserStorageLog -Message "Using fallback rclone log (ProgramData logs not writable): $fallback" -Level WARN `
        -LogFile (Join-Path $fallbackDir 'user-storage-mount.log')
    return $fallback
}

function Set-UserStorageRcloneConfigAcl {
    <#
    .SYNOPSIS
        Lock down rclone.conf but allow BUILTIN\Users to read it for mount (recreate-safe).
    #>
    param(
        [string]$ExtraReadUser = ''
    )
    foreach ($dir in @($script:NextGpuUserStorageRcloneDir, $script:NextGpuUserStorageLogDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
    $null = Set-UserStorageLogDirAcl
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageRcloneConfigPath)) {
        throw "rclone.conf not found: $script:NextGpuUserStorageRcloneConfigPath"
    }

    foreach ($target in @($script:NextGpuUserStorageRcloneDir, $script:NextGpuUserStorageRcloneConfigPath)) {
        $acl = Get-Acl -LiteralPath $target
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $null = $acl.RemoveAccessRule($_) }

        $rules = @(
            @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
            @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
            @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' }
        )
        foreach ($rule in $rules) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($rule.Sid)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, $rule.Rights, 'Allow')))
        }
        if (-not [string]::IsNullOrWhiteSpace($ExtraReadUser)) {
            try {
                $nt = New-Object System.Security.Principal.NTAccount($ExtraReadUser)
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $nt, 'ReadAndExecute', 'Allow')))
            } catch {
                Write-Warning "Could not add ACL for ${ExtraReadUser}: $($_.Exception.Message)"
            }
        }
        Set-Acl -LiteralPath $target -AclObject $acl
    }
}

function Test-UserStorageRcloneConfigReadable {
    try {
        $null = Get-Content -LiteralPath $script:NextGpuUserStorageRcloneConfigPath -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-NextGpuUserStoragePublishedScriptPath {
    param([Parameter(Mandatory)][string]$ScriptName)
    return Join-Path $script:NextGpuUserStorageRuntimeDir $ScriptName
}

function Set-UserStorageRuntimeScriptsAcl {
    param([string]$ExtraReadUser = '')
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageRuntimeDir)) {
        return
    }
    foreach ($target in @($script:NextGpuUserStorageRuntimeDir)) {
        Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $acl = Get-Acl -LiteralPath $_.FullName
            $acl.SetAccessRuleProtection($true, $false)
            $acl.Access | ForEach-Object { $null = $acl.RemoveAccessRule($_) }
            foreach ($rule in @(
                    @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
                    @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
                    @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' }
                )) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($rule.Sid)
                $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sid, $rule.Rights, 'Allow')))
            }
            if (-not [string]::IsNullOrWhiteSpace($ExtraReadUser)) {
                try {
                    $nt = New-Object System.Security.Principal.NTAccount($ExtraReadUser)
                    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                        $nt, 'ReadAndExecute', 'Allow')))
                } catch {
                    Write-Warning "Could not add script ACL for ${ExtraReadUser}: $($_.Exception.Message)"
                }
            }
            Set-Acl -LiteralPath $_.FullName -AclObject $acl
        }
        $dirAcl = Get-Acl -LiteralPath $target
        $dirAcl.SetAccessRuleProtection($true, $false)
        $dirAcl.Access | ForEach-Object { $null = $dirAcl.RemoveAccessRule($_) }
        foreach ($rule in @(
                @{ Sid = 'S-1-5-18'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-32-544'; Rights = 'FullControl' }
                @{ Sid = 'S-1-5-32-545'; Rights = 'ReadAndExecute' }
            )) {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($rule.Sid)
            $dirAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sid, $rule.Rights, 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        }
        if (-not [string]::IsNullOrWhiteSpace($ExtraReadUser)) {
            try {
                $nt = New-Object System.Security.Principal.NTAccount($ExtraReadUser)
                $dirAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $nt, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            } catch { }
        }
        Set-Acl -LiteralPath $target -AclObject $dirAcl
    }
}

function Publish-NextGpuUserStorageRuntimeScripts {
    <#
    .SYNOPSIS
        Copy mount scripts to ProgramData so nextGPU scheduled tasks do not depend on Administrator profile paths.
    #>
    param([Parameter(Mandatory)][string]$SourceDir)
    $source = $SourceDir.TrimEnd('\')
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source directory not found: $source"
    }
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageRuntimeDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageRuntimeDir -Force | Out-Null
    }
    foreach ($name in $script:NextGpuUserStoragePublishedScriptNames) {
        $src = Join-Path $source $name
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Required script missing in source repo: $src"
        }
        Copy-Item -LiteralPath $src -Destination (Join-Path $script:NextGpuUserStorageRuntimeDir $name) -Force
    }
    $launcherBat = Join-Path $source 'User-Storage.bat'
    if (Test-Path -LiteralPath $launcherBat) {
        Copy-Item -LiteralPath $launcherBat -Destination (Join-Path $script:NextGpuUserStorageRuntimeDir 'User-Storage.bat') -Force
    }
    Set-UserStorageRuntimeScriptsAcl
    Write-UserStorageLog "Published user-storage scripts to $($script:NextGpuUserStorageRuntimeDir)" -Level OK
    return $script:NextGpuUserStorageRuntimeDir
}

function Grant-NextGpuRepoRootReadAccess {
    <#
    .SYNOPSIS
        Minimal ACLs so nextGPU can read domain.txt (repo stays where it is). Mount tasks use ProgramData scripts.
    #>
    param([Parameter(Mandatory)][string]$RepoRoot)

    $repo = $RepoRoot.TrimEnd('\')
    $domainFile = Join-Path $repo 'domain.txt'
    if (-not (Test-Path -LiteralPath $domainFile)) {
        Write-Warning "domain.txt not found at $domainFile - skip repo ACL grant."
        return $false
    }

    $nextGpu = Get-NextGpuRentalUserPrincipal
    $ok = $true

    & icacls.exe $domainFile /grant "${nextGpu}:R" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    # Traverse/list repo root only (not inherited on all children) so domain.txt path is reachable.
    & icacls.exe $repo /grant "${nextGpu}:(RX)" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    $runtimeSrc = Join-Path $repo 'scripts\runtime'
    if (Test-Path -LiteralPath $runtimeSrc) {
        & icacls.exe $runtimeSrc /grant "${nextGpu}:(OI)(CI)RX" /T 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { $ok = $false }
    }

    if ($ok) {
        Write-Host "[*] nextGPU can read domain.txt and run scripts under $repo (repo not moved)." -ForegroundColor DarkGray
        Write-Host "    Tasks use $($script:NextGpuUserStorageRuntimeDir) (set up via Setup-UserStorage.bat)." -ForegroundColor DarkGray
    } else {
        Write-Warning 'One or more icacls grants failed (nextGPU may not read domain.txt).'
    }
    return $ok
}

function Test-UserStoragePublishedScriptsForNextGpu {
    $mountScript = Get-NextGpuUserStoragePublishedScriptPath -ScriptName 'Mount-UserStorage.ps1'
    if (-not (Test-Path -LiteralPath $mountScript)) {
        return [pscustomobject]@{ Ok = $false; Detail = "Missing $mountScript - re-run Setup-UserStorage.bat as Administrator." }
    }
    try {
        $null = Get-Content -LiteralPath $mountScript -TotalCount 1 -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Detail = $mountScript }
    } catch {
        return [pscustomobject]@{ Ok = $false; Detail = "Cannot read published mount script: $($_.Exception.Message)" }
    }
}

function Repair-UserStoragePermissionsForNextGpu {
    <#
    .SYNOPSIS
        Re-apply ProgramData script publish + ACLs (repo path unchanged).
    #>
    param([string]$SourceDir = '')

    if ([string]::IsNullOrWhiteSpace($SourceDir)) {
        $SourceDir = $PSScriptRoot
    }
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'UserStorageCommon.ps1'))) {
        throw "User storage scripts not found under: $SourceDir"
    }

    $null = Publish-NextGpuUserStorageRuntimeScripts -SourceDir $SourceDir
    $null = Set-NextGpuRentalUserStorageAccess
    try {
        $repoRoot = Get-NextGpuRepoRoot -StartPath $SourceDir
        Set-NextGpuRepoRootMarker -RepoRoot $repoRoot
        Grant-NextGpuRepoRootReadAccess -RepoRoot $repoRoot | Out-Null
        $null = Publish-NextGpuDomainForRentalUser -RepoRoot $repoRoot
    } catch {
        Write-Warning "Repo ACL/marker: $($_.Exception.Message)"
    }
    return $true
}

function Get-NextGpuSessionQueryLines {
    $lines = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($l in (& query.exe user 2>&1 | Out-String) -split "`r?`n") {
            if ($l.Trim()) { [void]$lines.Add($l) }
        }
    } catch { }
    try {
        foreach ($l in (& qwinsta.exe 2>&1 | Out-String) -split "`r?`n") {
            if ($l.Trim()) { [void]$lines.Add("qwinsta: $l") }
        }
    } catch { }
    return $lines.ToArray()
}

function Test-NextGpuSessionLine {
    param([string]$Line)
    # Exact user nextGPU only (not NextGPU-Authority).
    return ($Line -match '(?i)^\s*>?\s*nextGPU\s+\S+\s+\d+\s+(Active|Disc)')
        -or ($Line -match '(?i)^\s*>?\s*nextGPU\s+\d+\s+(Active|Disc)')
        -or ($Line -match '(?i)qwinsta:\s+>?\s*nextGPU\s+\S*\s+\d+\s+(Active|Disc)')
}

function Get-NextGpuSessionInfo {
    <#
    .SYNOPSIS
        Parses query.exe / qwinsta for local user nextGPU (Active or Disconnected).
    #>
    foreach ($line in (Get-NextGpuSessionQueryLines)) {
        if (-not (Test-NextGpuSessionLine -Line $line)) { continue }
        $clean = $line -replace '^qwinsta:\s*', ''
        if ($clean -match '(?i)^\s*>?\s*nextGPU\s+(\S+)\s+(\d+)\s+(Active|Disc)') {
            return [pscustomobject]@{
                SessionName = $Matches[1]
                SessionId   = [int]$Matches[2]
                State       = $Matches[3]
            }
        }
        if ($clean -match '(?i)^\s*>?\s*nextGPU\s+(\d+)\s+(Active|Disc)') {
            return [pscustomobject]@{
                SessionName = ''
                SessionId   = [int]$Matches[1]
                State       = $Matches[2]
            }
        }
    }
    return $null
}

function Write-NextGpuSessionDiagnostics {
    Write-Host '--- Sessions on this PC (query user) ---' -ForegroundColor DarkGray
    try {
        & query.exe user 2>&1 | ForEach-Object { Write-Host "  $_" }
    } catch {
        Write-Host "  query.exe failed: $($_.Exception.Message)"
    }
}

function Get-NextGpuActiveSessionId {
    $info = Get-NextGpuSessionInfo
    if ($info -and $info.State -ieq 'Active') {
        return $info.SessionId
    }
    return -1
}

function Get-NextGpuStreamingSessionId {
    <#
    .SYNOPSIS
        Session ID for mount while Moonlight/RDP has nextGPU logged on (Active preferred, else Disconnected).
    #>
    $info = Get-NextGpuSessionInfo
    if (-not $info) { return -1 }
    if ($info.State -ieq 'Active') { return $info.SessionId }
    if ($info.State -ieq 'Disc') { return $info.SessionId }
    return -1
}

function Test-NextGpuUserStorageMountTaskRegistered {
    return (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageMountTaskName)
}

function Invoke-NextGpuUserStorageScheduledTask {
    <#
    .SYNOPSIS
        Run nextGPU-UserStorageMount via Task Scheduler (single mount path for logon, Sunshine, and Admin).
    #>
    param(
        [ValidateSet('Mount', 'Unmount')]
        [string]$Operation = 'Mount',
        [int]$WaitSeconds = 25
    )
    $taskName = if ($Operation -eq 'Unmount') {
        $script:NextGpuUserStorageUnmountTaskName
    } else {
        $script:NextGpuUserStorageMountTaskName
    }

    if (-not (Test-NextGpuUserStorageScheduledTaskExists -TaskName $taskName)) {
        throw "Scheduled task '$taskName' is not registered. Run Setup-UserStorage.bat as Administrator."
    }

    $run = Invoke-SchtasksQuiet -ArgumentList @('/Run', '/TN', $taskName)
    if ($WaitSeconds -gt 0) {
        Start-Sleep -Seconds $WaitSeconds
    }

    $taskInfo = $null
    try {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
    } catch { }
    $lastResult = if ($taskInfo) { [int]$taskInfo.LastTaskResult } else { -1 }
    $lastRun = if ($taskInfo) { $taskInfo.LastRunTime } else { $null }

    $mountLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-mount.log'
    $mountLogExists = Test-Path -LiteralPath $mountLog
    $stateExists = Test-Path -LiteralPath $script:NextGpuUserStorageStatePath

    $ok = $false
    if ($Operation -eq 'Unmount') {
        $ok = (-not $stateExists) -or ($lastResult -eq 0)
    } else {
        $ok = ($lastResult -eq 0) -and ($mountLogExists -or $stateExists)
    }

    return [pscustomobject]@{
        Ok             = $ok
        TaskName       = $taskName
        LastTaskResult = $lastResult
        LastRunTime    = $lastRun
        MountLogExists = $mountLogExists
        StateExists    = $stateExists
    }
}

function Invoke-UserStorageMountForNextGpuSession {
    param(
        [int]$WaitSeconds = 25,
        [switch]$ShowDiagnostics
    )
    if ($ShowDiagnostics) {
        Write-NextGpuSessionDiagnostics
    }

    $sessionId = Get-NextGpuStreamingSessionId
    if ($sessionId -lt 0) {
        throw @"
nextGPU has no Windows session (Active or Disconnected).
U: mounts only via Task Scheduler into the nextGPU session.

  1) Disconnect Admin RDP before/during Moonlight.
  2) Renter connects Moonlight (nextGPU desktop).
  3) Wait 30s for automatic logon task, or run: schtasks /Run /TN $($script:NextGpuUserStorageMountTaskName)
  4) Or run Mount-UserStorage-Now.bat as Admin while Moonlight is connected.

Run: query user  (need nextGPU Active, not only NextGPU-Authority)
"@
    }

    $info = Get-NextGpuSessionInfo
    Write-Host "[*] nextGPU session $($info.SessionId) ($($info.State)) - Task Scheduler: $($script:NextGpuUserStorageMountTaskName)" -ForegroundColor Cyan

    $result = Invoke-NextGpuUserStorageScheduledTask -Operation Mount -WaitSeconds $WaitSeconds
    Write-Host "    Task LastTaskResult: $($result.LastTaskResult) (0 = success)"
    Write-Host "    Task LastRunTime: $($result.LastRunTime)"

    $mountLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-mount.log'
    if ($result.MountLogExists) {
        Write-Host ''
        Write-Host '--- user-storage-mount.log (tail) ---' -ForegroundColor DarkGray
        Get-Content -LiteralPath $mountLog -Tail 15 | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Host '[WARN] No mount log yet - Mount-UserStorage.ps1 may not have run as nextGPU in that session.' -ForegroundColor Yellow
    }

    if ($result.StateExists) {
        Write-Host "[OK]   Mount state: $($script:NextGpuUserStorageStatePath)" -ForegroundColor Green
    }

    return $result.Ok
}

function Test-UserStorageAlreadyMounted {
    param([string]$DriveLetter = 'U')
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $drivePath = "${letter}:"
    if (-not (Test-Path -LiteralPath $drivePath)) {
        return $false
    }
    $state = Get-UserStorageState
    if (-not $state) { return $false }
    $mountPid = 0
    if ($state.mountPid) { $mountPid = [int]$state.mountPid }
    if ($mountPid -gt 0 -and (Get-Process -Id $mountPid -ErrorAction SilentlyContinue)) {
        return $true
    }
    return $false
}

function Stop-UserStorageRcloneMountProcesses {
    param([string]$DriveLetter = 'U')
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $drivePatterns = @(
        "${letter}:",
        "\s${letter}\s",
        "mount\s+${letter}:"
    )
    try {
        Get-CimInstance -ClassName Win32_Process -Filter "Name='rclone.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $cmd = $_.CommandLine
                if ([string]::IsNullOrWhiteSpace($cmd)) { return }
                $isMount = $false
                foreach ($pat in $drivePatterns) {
                    if ($cmd -match $pat) { $isMount = $true; break }
                }
                if (-not $isMount -and $cmd -match '\s+mount\s+') { $isMount = $true }
                if ($isMount) {
                    Write-UserStorageLog "Stopping rclone mount PID $($_.ProcessId)" -Level INFO
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
            }
    } catch {
        Get-Process -Name rclone -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-UserStorageLog "Stopping rclone PID $($_.Id) (fallback)" -Level INFO
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
            }
    }
    Start-Sleep -Seconds 2
}

function Stop-UserStorageMountProcess {
    param(
        [int]$MountPid = 0,
        [string]$DriveLetter = 'U'
    )
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $drivePath = "${letter}:"

    if ($MountPid -gt 0) {
        $proc = Get-Process -Id $MountPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-UserStorageLog "Stopping rclone mount PID $MountPid" -Level INFO
            Stop-Process -Id $MountPid -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        }
    }

    Stop-UserStorageRcloneMountProcesses -DriveLetter $letter

    if (Test-Path -LiteralPath $drivePath) {
        try {
            $null = & net.exe use "${letter}:" /delete /y 2>&1
        } catch { }
    }
}

function Repair-UserStorageDriveLabelIfNeeded {
    param(
        [string]$DriveLetter = 'U',
        [Parameter(Mandatory)][string]$ExpectedLabel,
        [string]$LogFile = ''
    )
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $actual = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
    if ($actual -eq $ExpectedLabel) {
        return $true
    }
    Write-UserStorageLog "Drive ${letter}: relabeling '$actual' -> '$ExpectedLabel'" -Level INFO -LogFile $LogFile
    Set-UserStorageDriveLabel -DriveLetter $letter -Label $ExpectedLabel -LogFile $LogFile
    return ((Get-UserStorageCurrentVolumeLabel -DriveLetter $letter) -eq $ExpectedLabel)
}

function Set-UserStorageDriveLabel {
    param(
        [Parameter(Mandatory)][string]$DriveLetter,
        [Parameter(Mandatory)][string]$Label,
        [string]$LogFile = '',
        [int]$MaxAttempts = 5
    )
    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $drivePath = "${letter}:"

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (Get-Command Set-Volume -ErrorAction SilentlyContinue) {
            try {
                Set-Volume -DriveLetter $letter -NewFileSystemLabel $Label -ErrorAction Stop
                Write-UserStorageLog "Volume label set via Set-Volume (attempt $attempt): $Label" -Level OK -LogFile $LogFile
            } catch {
                Write-UserStorageLog "Set-Volume attempt $attempt failed: $($_.Exception.Message)" -Level WARN -LogFile $LogFile
            }
        }

        $actual = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
        if ($actual -eq $Label) {
            Write-UserStorageLog "Drive ${letter}: label verified '$actual'" -Level OK -LogFile $LogFile
            return
        }

        $labelCmd = Join-Path $env:SystemRoot 'System32\label.exe'
        if (Test-Path -LiteralPath $labelCmd) {
            $null = & $labelCmd $drivePath $Label 2>&1
            Write-UserStorageLog "Volume label set via label.exe (attempt $attempt): $Label" -Level OK -LogFile $LogFile
        }

        $actual = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
        if ($actual -eq $Label) {
            Write-UserStorageLog "Drive ${letter}: label verified '$actual'" -Level OK -LogFile $LogFile
            return
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds 2
        }
    }

    $actual = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
    if ($actual) {
        Write-UserStorageLog "Drive ${letter}: label mismatch expected='$Label' actual='$actual'" -Level WARN -LogFile $LogFile
    } else {
        Write-UserStorageLog "Drive ${letter}: could not read volume label after set (expected '$Label')" -Level WARN -LogFile $LogFile
    }
}
