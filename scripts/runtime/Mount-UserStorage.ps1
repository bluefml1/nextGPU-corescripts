#Requires -Version 5.1
<#
.SYNOPSIS
    Mount the renting nextGPU user's S3 prefix as U: (auto via nextGPU-UserStorageMount ~22s after sign-in).
#>
[CmdletBinding()]
param(
    [string]$DriveLetter = 'U',
    [int]$PollIntervalSeconds = 30,
    [int]$DirCacheSeconds = 30,
    [int]$MountReadyTimeoutSeconds = 0,
    [string]$RepoRoot = '',
    [switch]$Quiet,
    [switch]$FromScheduledTask,
    [switch]$DiagnosticListCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    throw "UserStorageCommon.ps1 not found: $commonPath"
}
. $commonPath

$mountLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-mount.log'
$rcloneLogFile = Get-UserStorageRcloneProcessLogFile
$rcloneStderrLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-rclone-stderr.log'
if (-not (Test-UserStorageLogDirWritable)) {
    $rcloneStderrLog = Join-Path (Split-Path -Parent $rcloneLogFile) 'user-storage-rclone-stderr.log'
}
$taskNote = if ($FromScheduledTask) { " task=$($script:NextGpuUserStorageMountTaskName)" } else { '' }
$scriptStamp = ''
try { $scriptStamp = (Get-Item -LiteralPath $PSCommandPath -ErrorAction Stop).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { }
Write-UserStorageLog -Message "Mount-UserStorage.ps1 started (USER=$env:USERDOMAIN\$env:USERNAME script=$PSCommandPath @ $scriptStamp)$taskNote" -LogFile $mountLog

function Write-MountLog {
    param([string]$Message, [string]$Level = 'INFO')
    Write-UserStorageLog -Message $Message -Level $Level -LogFile $mountLog
    if (-not $Quiet) {
        # Write-UserStorageLog already echoes
    }
}

try {
    Write-MountLog 'Checkpoint: entered mount try block.'
    if ($env:USERNAME -ne 'nextGPU') {
        if ($FromScheduledTask) {
            exit 0
        }
        $msg = "Refusing mount: USER=$env:USERNAME (expected nextGPU). U: mounts via Task Scheduler task $($script:NextGpuUserStorageMountTaskName) in the nextGPU session only."
        Write-MountLog $msg -Level WARN
        exit 0
    }

    if (-not (Test-UserStorageRcloneConfigReady)) {
        throw "rclone config not ready. Run Setup-UserStorage.bat as Administrator first."
    }
    Write-MountLog 'Checkpoint: rclone config is ready.'

    if (-not (Test-UserStorageRcloneConfigReadable)) {
        throw "Cannot read rclone.conf as $env:USERNAME. Admin: run Setup or Troubleshoot-UserStorage.ps1 -RepairAcl"
    }
    Write-MountLog 'Checkpoint: rclone config is readable by current user.'

    if (-not (Test-NextGpuRentalUserStorageAccess -Quiet)) {
        throw "Cannot access user-storage paths as $env:USERNAME. Admin: run Setup or User-Storage.bat Sync (-RepairAcl)."
    }
    Write-MountLog 'Checkpoint: runtime storage access OK (BUILTIN\Users ACLs).'

    Write-MountLog 'Checkpoint: resolving domain (ProgramData copy preferred)...'
    $domain = Get-NextGpuDomainFromFile
    Write-MountLog "Resolved domain: $domain"

    Write-MountLog 'Checkpoint: calling checkDomain API with retry...'
    $apiResult = Invoke-CheckDomainApiWithRetry -Domain $domain -LogFile $mountLog
    Write-MountLog 'Checkpoint: checkDomain API returned response.'
    $userId = $apiResult.userID
    $lastName = $apiResult.lastName
    $labelName = if ($apiResult.labelName) { [string]$apiResult.labelName } else { [string]$lastName }
    if ([string]::IsNullOrWhiteSpace($userId)) {
        throw 'checkDomain response missing userID'
    }
    if (-not (Test-NextGpuUserIdFormat -UserId $userId)) {
        throw "checkDomain returned invalid userID: $userId"
    }

    $letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
    $drivePath = "${letter}:"
    $volumeLabel = Get-UserStorageVolumeLabel -LastName $labelName
    $state = Get-UserStorageState
    $forceRemount = $false
    if ($state -and $state.userId -and ([string]$state.userId -ne $userId)) {
        $forceRemount = $true
        Write-MountLog "Tenant changed: U: has $($state.userId) but checkDomain wants $userId - will remount." -Level WARN
    }

    if (Test-UserStorageMountLockHeld) {
        if (Test-UserStorageMountMatchesTenant -DriveLetter $letter -ExpectedUserId $userId -ExpectedLabel $volumeLabel) {
            Write-MountLog "Mount skipped: in progress but U: already matches tenant $userId (label: '$volumeLabel')." -Level OK
            exit 0
        }
        Write-MountLog 'Stale mount lock or wrong tenant on U:; taking over mount.' -Level WARN
        Remove-UserStorageMountLock -Force
        $forceRemount = $true
    }

    Set-UserStorageMountLock

    $unmountScript = Join-Path $PSScriptRoot 'Unmount-UserStorage.ps1'
    if (-not (Test-Path -LiteralPath $unmountScript)) {
        $unmountScript = Get-NextGpuUserStoragePublishedScriptPath -ScriptName 'Unmount-UserStorage.ps1'
    }
    Prepare-UserStorageForNewMount -DriveLetter $DriveLetter -UnmountScriptPath $unmountScript -LogFile $mountLog `
        -ForceRemount:($forceRemount)

    if (Test-UserStorageMountMatchesTenant -DriveLetter $letter -ExpectedUserId $userId -ExpectedLabel $volumeLabel) {
        $liveLabel = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
        Write-MountLog "Drive ${letter}: matches current tenant $userId (label: '$liveLabel'); skipping new rclone." -Level OK
        exit 0
    }

    $liveMount = (Test-UserStorageAlreadyMounted -DriveLetter $letter) -or (Test-UserStorageHealthyMount -DriveLetter $letter)
    if ((-not $forceRemount) -and $liveMount) {
        $st = Get-UserStorageState
        if ($st -and [string]$st.userId -eq $userId) {
            if (Repair-UserStorageDriveLabelIfNeeded -DriveLetter $letter -ExpectedLabel $volumeLabel -LogFile $mountLog) {
                Write-MountLog "Drive ${letter}: tenant $userId mounted; label corrected to '$volumeLabel'." -Level OK
                exit 0
            }
            Write-MountLog "Drive ${letter}: label still wrong after repair; remounting." -Level WARN
            $forceRemount = $true
            Prepare-UserStorageForNewMount -DriveLetter $DriveLetter -UnmountScriptPath $unmountScript -LogFile $mountLog `
                -ForceRemount
        }
    }

    if (-not (Get-RcloneExeForUserStorage) -or -not (Test-WinFspInstalled)) {
        if (Ensure-UserStoragePrerequisitesIfAdmin) {
            Write-MountLog 'Installed rclone/WinFsp via admin prerequisite helper.'
        }
    }

    $rclone = Get-RcloneExeForUserStorage
    if (-not $rclone) {
        throw 'rclone not found. Run Setup-UserStorage.bat as Administrator.'
    }

    if (-not (Test-WinFspInstalled)) {
        throw 'WinFsp not found. Run Setup-UserStorage.bat as Administrator.'
    }

    $remotePath = Get-UserStorageRemotePathForUserId -UserId $userId -RcloneExe $rclone
    if (-not (Test-UserStorageRemotePathReachable -RcloneExe $rclone -RemotePath $remotePath)) {
        throw "Resolved S3 prefix is not reachable: $remotePath (check credentials/bucket/path)."
    }

    Write-MountLog "Mounting $remotePath -> $drivePath (label: $volumeLabel)"

    if ($DiagnosticListCount) {
        $count = & $rclone lsf $remotePath --config $script:NextGpuUserStorageRcloneConfigPath --max-depth 1 2>&1
        if ($LASTEXITCODE -eq 0) {
            $n = @($count).Count
            if ($n -gt 50000) {
                Write-MountLog "Diagnostic: prefix has ~$n objects (heavy LIST cost with 30s refresh)." -Level WARN
            } else {
                Write-MountLog "Diagnostic: prefix has ~$n top-level file objects." -Level INFO
            }
        }
    }

    $cacheArg = '{0}s' -f $DirCacheSeconds
    $mountExtras = Get-UserStorageRcloneMountExtraArgs -RcloneExe $rclone -VolumeLabel $volumeLabel

    $rcloneArgs = @(
        'mount', $remotePath, $drivePath,
        '--config', $script:NextGpuUserStorageRcloneConfigPath,
        '--vfs-cache-mode', 'off',
        '--dir-cache-time', $cacheArg,
        '--attr-timeout', $cacheArg
    ) + $mountExtras + @(
        '--vfs-read-ahead', '128Ki',
        '--vfs-read-chunk-size', '4M',
        '--buffer-size', '16M',
        '--no-modtime',
        '--use-server-modtime',
        '--transfers', '1',
        '--checkers', '1',
        '--log-level', 'INFO',
        '--log-file', $rcloneLogFile
    )

    if (Test-Path -LiteralPath $rcloneStderrLog) {
        Remove-Item -LiteralPath $rcloneStderrLog -Force -ErrorAction SilentlyContinue
    }
    Write-MountLog ("rclone mount extras: {0}" -f ($mountExtras -join ' '))
    $positional = @($remotePath, $drivePath)
    Write-MountLog ("rclone positional args (must be 2): {0}" -f ($positional -join ' | '))
    Write-MountLog ("rclone command: {0} {1}" -f $rclone, ($rcloneArgs -join ' '))

    $proc = Start-Process -FilePath $rclone -ArgumentList $rcloneArgs -PassThru -WindowStyle Hidden `
        -RedirectStandardError $rcloneStderrLog
    if (-not $proc -or $proc.Id -le 0) {
        throw 'Failed to start rclone mount process'
    }

    $readyTimeoutSec = if ($MountReadyTimeoutSeconds -gt 0) {
        $MountReadyTimeoutSeconds
    } else {
        $script:NextGpuUserStorageMountReadyTimeoutSeconds
    }

    $ready = $false
    for ($i = 0; $i -lt $readyTimeoutSec; $i++) {
        Start-Sleep -Seconds 1
        if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) {
            $detail = Get-UserStorageMountFailureDetails -MountLog $mountLog -StderrLog $rcloneStderrLog
            throw "rclone mount exited early (PID $($proc.Id)). Details:`n$detail"
        }
        if (Test-Path -LiteralPath $drivePath) {
            $ready = $true
            break
        }
    }

    if (-not $ready) {
        Stop-UserStorageMountProcess -MountPid $proc.Id -DriveLetter $letter
        $detail = Get-UserStorageMountFailureDetails -MountLog $mountLog -StderrLog $rcloneStderrLog
        throw "Drive $drivePath did not appear within ${readyTimeoutSec}s. Details:`n$detail"
    }

    Set-UserStorageDriveLabel -DriveLetter $letter -Label $volumeLabel -LogFile $mountLog
    $stateSaved = Set-UserStorageStateSafe -DriveLetter $letter -UserId $userId -MountPid $proc.Id -LogFile $mountLog
    if (-not $stateSaved) {
        Write-MountLog 'Mount succeeded but state file could not be written. Next run may remount; admin should run Sync.' -Level WARN
    }

    $actualLabel = Get-UserStorageCurrentVolumeLabel -DriveLetter $letter
    Write-MountLog "User storage mounted on $drivePath for $userId (PID $($proc.Id)). Label: '$actualLabel' (labelName=$labelName, lastName=$lastName)." -Level OK

    if (-not $Quiet) {
        $null = Show-UserStorageDriveInExplorer -DriveLetter $letter
        Write-MountLog 'Opened Explorer on U: (interactive mount).' -Level INFO
    } elseif ($FromScheduledTask) {
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList $drivePath -WindowStyle Normal -ErrorAction SilentlyContinue
            Write-MountLog 'Opened Explorer on U: after logon mount task.' -Level INFO
        } catch {
            Write-MountLog "Could not open Explorer on ${drivePath}: $($_.Exception.Message)" -Level WARN
        }
    }
    exit 0
}
catch {
    Write-MountLog $_.Exception.Message -Level ERROR
    exit 1
}
finally {
    Remove-UserStorageMountLock -Force
}
