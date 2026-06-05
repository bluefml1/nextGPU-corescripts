#Requires -Version 5.1
<#
.SYNOPSIS
    Step-by-step diagnosis when U: tenant storage does not appear.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Troubleshoot-UserStorage.ps1
    powershell -ExecutionPolicy Bypass -File Troubleshoot-UserStorage.ps1 -RepairAcl -TryMount
#>
[CmdletBinding()]
param(
    [switch]$RepairAcl,
    [switch]$InstallWinFsp,
    [switch]$TryMount,
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')

$logDir = $script:NextGpuUserStorageLogDir
$mountLog = Join-Path $logDir 'user-storage-mount.log'
$fail = 0

function Write-Step {
    param([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    Write-Host ''
    Write-Host "=== $Message ===" -ForegroundColor $Color
}

function Test-Line {
    param([string]$Label, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
    } else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        $script:fail++
    }
    if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
}

Write-Step 'nextGPU user storage troubleshoot'
Write-Host "Computer: $env:COMPUTERNAME  User: $env:USERDOMAIN\$env:USERNAME"
Write-Host "Log folder: $logDir"

Write-Step '1) Log files'
if (-not (Test-Path -LiteralPath $logDir)) {
    Test-Line 'Logs directory exists' $false "Create by running Setup-UserStorage.bat as Administrator"
} else {
    Test-Line 'Logs directory exists' $true $logDir
    Get-ChildItem -LiteralPath $logDir -File -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "       $($_.Name)  ($([math]::Round($_.Length/1KB, 1)) KB, $($_.LastWriteTime))" -ForegroundColor DarkGray
    }
    if (-not (Test-Path -LiteralPath $mountLog)) {
        Test-Line 'user-storage-mount.log present' $false 'Mount script never ran or failed before first log line'
    }
}

Write-Step '2) Scheduled tasks'
$mountTask = Get-ScheduledTask -TaskName 'nextGPU-UserStorageMount' -ErrorAction SilentlyContinue
$unmountTask = Get-ScheduledTask -TaskName 'nextGPU-UserStorageUnmount' -ErrorAction SilentlyContinue
Test-Line 'nextGPU-UserStorageMount registered' ([bool]$mountTask)
Test-Line 'nextGPU-UserStorageUnmount registered' ([bool]$unmountTask) 'Optional; logoff cleanup'
$ensureTask = Get-ScheduledTask -TaskName $script:NextGpuUserStorageEnsureTaskName -ErrorAction SilentlyContinue
Test-Line 'nextGPU-UserStorageEnsureBindings registered' ([bool]$ensureTask) 'Run Sync once from repo after script update'
Test-Line 'Published ProgramData scripts current' (Test-NextGpuUserStoragePublishedScriptsCurrent) 'Run Sync-NextGpuUserStorageForLocalUser.bat from repo'
$rentalUser = Get-NextGpuRentalLocalUser
if ($rentalUser) {
    $storedSid = Get-NextGpuUserStorageBoundSid
    $sidOk = (-not [string]::IsNullOrWhiteSpace($storedSid)) -and ($storedSid -eq $rentalUser.SID.Value)
    Test-Line 'nextGPU SID binding marker current' $sidOk $(if ($sidOk) { $storedSid } else { "stored='$storedSid' current=$($rentalUser.SID)" })
    if (-not $sidOk -and (Test-UserStorageRcloneConfigReady)) {
        Write-Host '       After recreate: nextGPU-UserStorageEnsureBindings at logon, then mount (+22s). Admin: Sync-NextGpuUserStorageForLocalUser.bat' -ForegroundColor DarkGray
    }
}
if ($mountTask) {
    $info = Get-ScheduledTaskInfo -TaskName 'nextGPU-UserStorageMount' -ErrorAction SilentlyContinue
    if ($info) {
        Write-Host "       Last run: $($info.LastRunTime)  Result code: $($info.LastTaskResult) (0=success)" -ForegroundColor DarkGray
        $neverRun = ($info.LastRunTime.Year -lt 2000)
        if ($neverRun) {
            Test-Line 'Mount task has run at least once' $false 'Run: Invoke-UserStorageMountFromAdmin.ps1 or schtasks /Run /TN nextGPU-UserStorageMount'
        } elseif ($info.LastTaskResult -ne 0) {
            Test-Line 'Last mount task succeeded' $false "See Task Scheduler History and $mountLog"
        }
    }
}

Write-Step '3) rclone + WinFsp'
$rclone = Get-RcloneExeForUserStorage
Test-Line 'rclone installed' ([bool]$rclone) $(if ($rclone) { $rclone } else { 'Run Setup-UserStorage.bat as Administrator' })
if ($InstallWinFsp -and (-not $rclone -or -not (Test-WinFspInstalled))) {
    $null = Ensure-UserStoragePrerequisites
    $rclone = Get-RcloneExeForUserStorage
}
$winFspOk = Test-WinFspInstalled
$winFspDetail = if ($winFspOk) { Get-WinFspBinDirectory } else { '' }
Test-Line 'WinFsp installed' $winFspOk $(if ($winFspOk) { $winFspDetail } else { 'Run Setup-UserStorage.bat as Admin, or Troubleshoot with -InstallWinFsp' })

Write-Step '4) Config + permissions (common failure)'
Test-Line 'rclone.conf exists' (Test-UserStorageRcloneConfigReady) $script:NextGpuUserStorageRcloneConfigPath
Test-Line 'Current user can read rclone.conf' (Test-UserStorageRcloneConfigReadable) `
    'If FAIL as nextGPU: run this script as Admin with -RepairAcl'
Test-Line 'Current user can write logs dir' (Test-UserStorageLogDirWritable) `
    'rclone needs write on ProgramData\nextGPU\logs; Admin -RepairAcl fixes this'

$published = Test-UserStoragePublishedScriptsForNextGpu
Test-Line 'Published mount script (ProgramData)' $published.Ok $published.Detail

if ($RepairAcl) {
    if (-not (Test-UserStorageRcloneConfigReady)) {
        Write-Host '[!] Run Setup-UserStorage.bat first (no config to fix).' -ForegroundColor Yellow
    } else {
        try {
            Repair-UserStoragePermissionsForNextGpu -SourceDir $PSScriptRoot
            Write-Host '[OK]   Republished scripts to ProgramData + rclone/repo ACLs for nextGPU' -ForegroundColor Green
            Test-Line 'Read test after ACL repair' (Test-UserStorageRcloneConfigReadable)
            Test-Line 'Log dir writable after repair' (Test-UserStorageLogDirWritable)
            $published = Test-UserStoragePublishedScriptsForNextGpu
            Test-Line 'Published mount script after repair' $published.Ok $published.Detail
        } catch {
            Test-Line 'ACL repair' $false $_.Exception.Message
        }
    }
}

Write-Host ''
Write-Host 'icacls rclone.conf:' -ForegroundColor DarkGray
if (Test-Path -LiteralPath $script:NextGpuUserStorageRcloneConfigPath) {
    & icacls.exe $script:NextGpuUserStorageRcloneConfigPath 2>&1 | ForEach-Object { Write-Host "       $_" }
}

Write-Step '5) domain.txt + checkDomain API'
try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-NextGpuRepoRoot -StartPath $PSScriptRoot
    }
    Test-Line 'repo-root.txt / domain.txt' $true "RepoRoot=$RepoRoot"
    $domain = Get-NextGpuDomainFromFile -RepoRoot $RepoRoot
    Test-Line 'DOMAIN value' $true $domain
    $api = Invoke-CheckDomainApi -Domain $domain
    $uid = $api.userID
    $labelName = if ($api.labelName) { $api.labelName } else { $api.lastName }
    $expectedLabel = if ($labelName) { Get-UserStorageVolumeLabel -LastName $labelName } else { '' }
    Test-Line 'checkDomain userID' ([bool]$uid) "$uid  labelName=$labelName lastName=$($api.lastName) -> '$expectedLabel'"
    if ($uid -and $rclone -and (Test-UserStorageRcloneConfigReadable)) {
        Write-Host "       S3 URL:  $(Get-UserStorageS3ConsoleUrl -UserId $uid)" -ForegroundColor DarkGray
        Write-Host "       rclone:  $($script:NextGpuUserStorageRemoteName):$uid/" -ForegroundColor DarkGray
        $s3 = Test-UserStorageS3Access -RcloneExe $rclone -UserId $uid
        foreach ($line in $s3.Lines) {
            Write-Host "       $line" -ForegroundColor DarkGray
        }
        Test-Line 'S3 prefix reachable' $s3.Ok $s3.Summary
    }
} catch {
    $apiMsg = $_.Exception.Message
    Test-Line 'checkDomain API' $false $apiMsg
    if ($apiMsg -match 'No active session') {
        Write-Host '       Backend has no active rental session for this machine/domain.' -ForegroundColor Yellow
        Write-Host '       Mount worked earlier only when a session was active (see user-storage-mount.log).' -ForegroundColor Yellow
        Write-Host '       Start a renter session in your app DB (machine-sessions), then retry or connect Moonlight.' -ForegroundColor Yellow
    } elseif ($apiMsg -match 'Invalid JSON') {
        Write-Host '       Re-run Sync from repo to refresh scripts; JSON body encoding was fixed in UserStorageCommon.ps1.' -ForegroundColor Yellow
    }
}

Write-Step '6) Session user (Admin RDP + Moonlight)'
Test-Line 'Logged in as nextGPU' ($env:USERNAME -ieq 'nextGPU') `
    'OK for direct mount; Admin RDP uses Sunshine hook or Invoke-UserStorageMountFromAdmin.ps1'
$ngSid = Get-NextGpuActiveSessionId
if ($ngSid -ge 0) {
    Test-Line 'nextGPU Active session' $true "SessionId=$ngSid (schtasks mount can run from Admin)"
} else {
    Test-Line 'nextGPU Active session' $false 'No Active nextGPU - logon task may never fire while only Admin is RDP'
}
$sessionLog = Join-Path $logDir 'user-storage-session.log'
if (Test-Path -LiteralPath $sessionLog) {
    Write-Host '--- user-storage-session.log (tail) ---' -ForegroundColor DarkGray
    Get-Content -LiteralPath $sessionLog -Tail 8 | ForEach-Object { Write-Host "  $_" }
}

if ($mountLog -and (Test-Path -LiteralPath $mountLog)) {
    Write-Step 'Last mount log lines' 'Yellow'
    Get-Content -LiteralPath $mountLog -Tail 20 | ForEach-Object { Write-Host "  $_" }
}

Write-Step 'What to do next'
if ($env:USERNAME -ne 'nextGPU') {
    Write-Host '  Admin RDP + Moonlight (single session):' -ForegroundColor White
    Write-Host '  1. Setup + Register + Troubleshoot -RepairAcl (Administrator)' -ForegroundColor White
    Write-Host '  2. powershell -File Invoke-UserStorageMountFromAdmin.ps1  (after renter connects Moonlight)' -ForegroundColor White
    Write-Host '  3. Read logs under repo\logs\user-storage-*.log (mirrored) OR ProgramData\nextGPU\logs' -ForegroundColor White
    Write-Host '  4. U: appears in renter desktop (nextGPU), not necessarily in your Admin Explorer' -ForegroundColor White
} else {
    Write-Host '  1. If ACL failed above, sign out; Admin runs: Troubleshoot-UserStorage.ps1 -RepairAcl' -ForegroundColor White
    Write-Host "  2. Run: powershell -File `"$PSScriptRoot\Mount-UserStorage.ps1`"" -ForegroundColor White
    Write-Host '  3. Open This PC -> U: (may take 30s)' -ForegroundColor White
}

if ($TryMount -and $env:USERNAME -ieq 'nextGPU') {
    Write-Step 'Running Mount-UserStorage.ps1' 'Green'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Mount-UserStorage.ps1')
    if (Test-Path -LiteralPath 'U:\') {
        Write-Host '[OK]   U: is visible' -ForegroundColor Green
    } else {
        Write-Host '[FAIL] U: still not visible - read mount log above' -ForegroundColor Red
    }
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "Finished with $fail failed check(s)." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed. If U: is still missing, wait 60s after logon or run -TryMount as nextGPU.' -ForegroundColor Green
exit 0
