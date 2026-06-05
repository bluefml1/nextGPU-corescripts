#Requires -Version 5.1
<#
.SYNOPSIS
    All-in-one nextGPU per-user S3 storage (U:): setup, sync, test, troubleshoot, mount.
.EXAMPLE
    User-Storage.bat
    User-Storage.bat Test
    User-Storage.bat Mount
    User-Storage.bat Setup
    User-Storage.bat Sync
    User-Storage.bat Logs
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Auto', 'Menu', 'Setup', 'Sync', 'Test', 'Status', 'Troubleshoot', 'Mount', 'MountAdmin', 'Open', 'Logs', 'Help')]
    [string]$Action = 'Auto',
    [string]$LaunchDir = '',
    [switch]$RepairAcl,
    [switch]$TryMount,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:UserStorageLaunchDir = if (-not [string]::IsNullOrWhiteSpace($LaunchDir)) {
    $LaunchDir.TrimEnd('\')
} else {
    $PSScriptRoot
}

$script:UserStorageRoot = $PSScriptRoot
$commonCandidates = @(
    (Join-Path $script:UserStorageLaunchDir 'UserStorageCommon.ps1')
    (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')
    (Join-Path $env:ProgramData 'nextGPU\scripts\runtime\UserStorageCommon.ps1')
)
$script:UserStorageCommonPath = ''
foreach ($c in $commonCandidates) {
    if (Test-Path -LiteralPath $c) {
        $script:UserStorageCommonPath = $c
        break
    }
}
if (-not $script:UserStorageCommonPath) {
    throw 'UserStorageCommon.ps1 not found. Run from scripts\runtime (Downloads) or run User-Storage.bat Sync.'
}
. $script:UserStorageCommonPath
$script:UserStorageRoot = Split-Path -Parent $script:UserStorageCommonPath

function Get-UserStorageInstallScriptDir {
    foreach ($dir in @(
            $script:UserStorageLaunchDir
            $PSScriptRoot
            (Get-NextGpuUserStorageSyncSourceDir -FallbackDir $script:UserStorageLaunchDir)
            $script:NextGpuUserStorageRuntimeDir
        )) {
        if ([string]::IsNullOrWhiteSpace($dir)) { continue }
        $pre = Join-Path $dir.TrimEnd('\') 'Install-UserStoragePrerequisites.ps1'
        if (Test-Path -LiteralPath $pre) { return $dir.TrimEnd('\') }
    }
    throw 'Install-UserStoragePrerequisites.ps1 not found. Run User-Storage.bat Setup from the repo scripts\runtime folder (e.g. Downloads\scripts\runtime).'
}

function Write-UserStorageBanner {
    param([string]$Title)
    Write-Host ''
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host " $Title" -ForegroundColor Cyan
    Write-Host '========================================' -ForegroundColor Cyan
    Write-Host " User: $env:USERDOMAIN\$env:USERNAME"
    Write-Host " Scripts: $script:UserStorageRoot (launch: $script:UserStorageLaunchDir)"
    Write-Host " Logs: $($script:NextGpuUserStorageLogDir)"
}

function Show-UserStorageHelp {
    Write-UserStorageBanner 'nextGPU User Storage (U:)'
    Write-Host @'

Actions (run User-Storage.bat <action>):

  (no args)   Auto — Test; Mount if you are nextGPU and U: is missing
  Test        Diagnostics (nextGPU or Admin)
  Status      Is U: live now (rclone running + path reachable)?
  Mount       Mount U: now (must be nextGPU session)
  Open        Open Explorer on U: if mounted
  Troubleshoot  Full checks; Admin also repairs ACLs
  Logs        Show last lines of mount + ensure logs
  Setup       Admin one-time install (rclone, tasks, AWS config). Use User-Storage.bat (bypasses execution policy).
  Sync        Admin re-bind after recreate or script update
  MountAdmin  Admin: trigger mount in Moonlight nextGPU session
  Menu        Interactive menu
  Help        This text

Examples:
  User-Storage.bat
  User-Storage.bat Test
  User-Storage.bat Mount
  User-Storage.bat Troubleshoot
  User-Storage.bat Setup

'@
}

function Show-UserStorageMenu {
    $isAdmin = Test-NextGpuUserStorageRepairPrincipal
    Write-UserStorageBanner 'Menu'
    Write-Host '  1  Test'
    Write-Host '  2  Mount U: (nextGPU session)'
    Write-Host '  3  Status (is U: live?)'
    Write-Host '  4  Troubleshoot'
    Write-Host '  5  Logs'
    Write-Host '  6  Open U: in Explorer'
    if ($isAdmin) {
        Write-Host '  7  Setup (one-time)' -ForegroundColor Yellow
        Write-Host '  8  Sync (recreate / deploy)' -ForegroundColor Yellow
        Write-Host '  9  Mount via Moonlight (from Admin)' -ForegroundColor Yellow
    } else {
        Write-Host '  (7–9 need Administrator)' -ForegroundColor DarkGray
    }
    Write-Host '  Q  Quit'
    $choice = (Read-Host 'Choice').Trim().ToUpperInvariant()
    switch ($choice) {
        '1' { return 'Test' }
        '2' { return 'Mount' }
        '3' { return 'Status' }
        '4' { return 'Troubleshoot' }
        '5' { return 'Logs' }
        '6' { return 'Open' }
        '7' { if ($isAdmin) { return 'Setup' }; Write-Host 'Run as Administrator.' -ForegroundColor Red; return 'Menu' }
        '8' { if ($isAdmin) { return 'Sync' }; Write-Host 'Run as Administrator.' -ForegroundColor Red; return 'Menu' }
        '9' { if ($isAdmin) { return 'MountAdmin' }; Write-Host 'Run as Administrator.' -ForegroundColor Red; return 'Menu' }
        'Q' { return 'Quit' }
        default { Write-Host 'Unknown choice.' -ForegroundColor Yellow; return 'Menu' }
    }
}

function Invoke-UserStorageSetup {
    if (-not (Test-NextGpuUserStorageRepairPrincipal)) {
        throw 'Setup requires Administrator. Right-click User-Storage.bat -> Run as administrator.'
    }
    Write-UserStorageBanner 'Setup (one-time logon mount for nextGPU)'
    if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageLogDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuUserStorageLogDir -Force | Out-Null
    }
    $setupLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-setup.log'
    Add-Content -LiteralPath $setupLog -Value "[$(Get-Date)] User-Storage.ps1 Setup" -Encoding UTF8

    if (-not (Get-NextGpuRentalLocalUser)) {
        Write-Warning "Local user '$($script:NextGpuRentalLocalAccountName)' not found; continuing Setup (Users-group ACLs; register tasks when user exists)."
    }

    $installDir = Get-UserStorageInstallScriptDir
    Write-Host "[*] Install scripts: $installDir" -ForegroundColor DarkGray

    try {
        $repoRoot = Get-NextGpuRepoRoot -StartPath $installDir
        $null = Get-NextGpuDomainFromFile -RepoRoot $repoRoot
        Write-Host "[OK]   domain.txt at $repoRoot" -ForegroundColor Green
    } catch {
        throw "domain.txt not found. Provision machine first (repo root with domain.txt). $($_.Exception.Message)"
    }

    $pre = Join-Path $installDir 'Install-UserStoragePrerequisites.ps1'
    $cfg = Join-Path $installDir 'Install-UserStorageRcloneConfig.ps1'
    foreach ($p in @($pre, $cfg)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "Missing: $p" }
    }

    Write-Host '[*] (1/3) Installing rclone + WinFsp...' -ForegroundColor Cyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $pre
    if ($LASTEXITCODE -ne 0) { throw "Prerequisites failed (exit $LASTEXITCODE)" }

    Write-Host '[*] (2/3) Writing rclone config + ACLs...' -ForegroundColor Cyan
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $cfg
    if ($LASTEXITCODE -ne 0) { throw "rclone config failed (exit $LASTEXITCODE)" }

    Write-Host '[*] (3/3) Publish scripts, register tasks (ensure +0s, mount +22s), nextGPU access...' -ForegroundColor Cyan
    Invoke-UserStorageSync

    Write-Host ''
    Write-Host '--- Mount readiness ---' -ForegroundColor Cyan
    $fileReady = Test-UserStorageMountFileReady
    if (-not $fileReady.Ok) {
        throw "Setup incomplete. Failed checks: $($fileReady.Failed -join ', '). Fix and run: User-Storage.bat Sync"
    }
    $autoReady = Test-NextGpuUserStorageLogonAutomationReady -Quiet
    if (-not $autoReady.Ok) {
        Write-Warning "Logon auto-mount not ready: $($autoReady.Failed -join ', '). Run Sync when nextGPU exists, or sign in once (ensure repairs tasks)."
    }

    Write-Host ''
    Write-Host '[OK] Setup complete.' -ForegroundColor Green
    Write-Host '     Renter: sign in as nextGPU -> U: auto-mounts ~22s (BUILTIN\Users logon task).' -ForegroundColor DarkGray
    Write-Host '     Recreated nextGPU: no task re-bind needed; same Users-group task runs Mount-UserStorage.ps1.' -ForegroundColor DarkGray
    Write-Host "     Logs: $($script:NextGpuUserStorageLogDir)" -ForegroundColor DarkGray
}

function Invoke-UserStorageSync {
    if (-not (Test-NextGpuUserStorageRepairPrincipal)) {
        throw 'Sync requires Administrator.'
    }
    Write-UserStorageBanner 'Sync (publish + re-bind tasks)'
    $sourceDir = Get-NextGpuUserStorageSyncSourceDir -FallbackDir $script:UserStorageLaunchDir
    Write-Host "[*] Source: $sourceDir" -ForegroundColor Cyan
    $ok = Sync-NextGpuUserStorageForLocalUser -SourceDir $sourceDir
    if (-not $ok) { throw 'Sync failed.' }
    Write-Host '[OK] Sync complete.' -ForegroundColor Green
}

function Invoke-UserStorageTest {
    Write-UserStorageBanner 'Test'
    $script:UserStorageTestFailCount = 0
    function Test-Line {
        param([string]$Label, [bool]$Ok, [string]$Detail = '')
        if ($Ok) {
            Write-Host "[OK]   $Label" -ForegroundColor Green
            if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
        } else {
            Write-Host "[FAIL] $Label" -ForegroundColor Red
            if ($Detail) { Write-Host "       $Detail" -ForegroundColor Yellow }
            $script:UserStorageTestFailCount++
        }
    }

    Test-Line 'Running as nextGPU' ($env:USERNAME -ieq 'nextGPU') 'Mount needs nextGPU session'
    Test-Line 'rclone config' (Test-UserStorageRcloneConfigReady) $script:NextGpuUserStorageRcloneConfigPath
    Test-Line 'rclone readable' (Test-UserStorageRcloneConfigReadable) 'Admin: Troubleshoot with repair'
    Test-Line 'rclone.exe' ([bool](Get-RcloneExeForUserStorage)) ''
    Test-Line 'WinFsp' (Test-WinFspInstalled) 'Admin: Setup'
    $fileReady = Test-UserStorageMountFileReady -Quiet
    Test-Line 'Mount file ready' $fileReady.Ok $(if ($fileReady.Ok) { '' } else { "Failed: $($fileReady.Failed -join ', ')" })
    $autoReady = Test-NextGpuUserStorageLogonAutomationReady -Quiet
    Test-Line 'Logon auto-mount (sign-in -> U: ~22s)' $autoReady.Ok $(if ($autoReady.Ok) { '' } else { "Failed: $($autoReady.Failed -join ', ')" })
    $ready = Test-UserStorageLogonMountReady -Quiet
    Test-Line 'Legacy logon checks (bindings)' $ready.Ok $(if ($ready.Ok) { '' } else { "Failed: $($ready.Failed -join ', ')" })
    Test-Line 'Bindings current (tasks/SID only)' (Test-NextGpuUserStorageBindingsCurrent) 'Optional after recreate; file ACLs use BUILTIN\Users'
    Test-Line 'Scripts published' (Test-NextGpuUserStoragePublishedScriptsCurrent) 'Admin: Sync from repo'
    Test-Line 'nextGPU can use storage paths' (Test-NextGpuRentalUserStorageAccess) 'Admin: Sync or Troubleshoot'
    $launcher = Join-Path $script:NextGpuUserStorageRuntimeDir 'User-Storage.bat'
    Test-Line 'User-Storage.bat in ProgramData' (Test-Path -LiteralPath $launcher) 'Admin: Sync from repo'
    Test-Line 'Ensure task (schtasks)' (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageEnsureTaskName) ''
    Test-Line 'Mount task (schtasks)' (Test-NextGpuUserStorageScheduledTaskExists -TaskName $script:NextGpuUserStorageMountTaskName) ''
    Test-Line 'domain.txt for nextGPU' (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath) 'Admin: User-Storage.bat Sync'

    try {
        $repo = Get-NextGpuRepoRoot -StartPath $script:UserStorageRoot
        $domain = Get-NextGpuDomainFromFile -RepoRoot $repo
        Test-Line 'domain.txt' $true $domain
        $api = Invoke-CheckDomainApi -Domain $domain
        Test-Line 'checkDomain userID' ([bool]$api.userID) "$($api.userID) label=$($api.labelName)"
    } catch {
        Test-Line 'domain.txt / checkDomain' $false $_.Exception.Message
    }

    $letter = 'U'
    $uMounted = Test-UserStorageDriveLetterMounted -DriveLetter $letter
    Test-Line 'U: drive visible' $uMounted $(if (-not $uMounted) { 'Open This PC or run User-Storage.bat Mount' } else { '' })

    $mountLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-mount.log'
    if (Test-Path -LiteralPath $mountLog) {
        Write-Host ''
        Write-Host '--- mount log (last 12 lines) ---' -ForegroundColor Cyan
        Get-Content -LiteralPath $mountLog -Tail 12 | ForEach-Object { Write-Host $_ }
    }

    if ($script:UserStorageTestFailCount -gt 0) {
        Write-Host ''
        if (-not $autoReady.Ok -and $fileReady.Ok) {
            Write-Host 'NOTE: Auto-mount tasks need repair. Log in as nextGPU (ensure runs at +0s) or Admin: User-Storage.bat Sync' -ForegroundColor Yellow
        }
        if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageDomainCopyPath)) {
            Write-Host 'NOTE: domain Access denied = copy domain.txt to ProgramData. Admin: User-Storage.bat Sync' -ForegroundColor Yellow
        }
        Write-Host "Test finished: $($script:UserStorageTestFailCount) issue(s). Try: User-Storage.bat Troubleshoot" -ForegroundColor Yellow
        return 1
    }
    Write-Host ''
    Write-Host 'Test passed.' -ForegroundColor Green
    return 0
}

function Invoke-UserStorageTroubleshoot {
    Write-UserStorageBanner 'Troubleshoot'
    $trouble = Join-Path $script:UserStorageRoot 'Troubleshoot-UserStorage.ps1'
    if (-not (Test-Path -LiteralPath $trouble)) {
        throw "Missing: $trouble (Admin: Sync to publish scripts)"
    }
    $psArgs = @('-ExecutionPolicy', 'Bypass', '-File', $trouble)
    if (Test-NextGpuUserStorageRepairPrincipal) { $psArgs += '-RepairAcl' }
    if ($TryMount) { $psArgs += '-TryMount' }
    & powershell.exe -NoLogo -NoProfile @psArgs
    return $LASTEXITCODE
}

function Invoke-UserStorageMount {
    if ($env:USERNAME -ne 'nextGPU') {
        Write-Host '[WARN] Not logged in as nextGPU. U: appears in Moonlight renter desktop only.' -ForegroundColor Yellow
        if (Test-NextGpuUserStorageRepairPrincipal) {
            Write-Host '       Use: User-Storage.bat MountAdmin' -ForegroundColor Cyan
        }
        return 1
    }
    Write-UserStorageBanner 'Mount U:'
    $mount = Join-Path $script:UserStorageRoot 'Mount-UserStorage.ps1'
    if (-not (Test-Path -LiteralPath $mount)) {
        throw "Missing: $mount"
    }
    $mountArgs = @('-ExecutionPolicy', 'Bypass', '-File', $mount)
    if ($Quiet) { $mountArgs += '-Quiet' }
    & powershell.exe -NoLogo -NoProfile @mountArgs
    $code = $LASTEXITCODE
    if (Test-Path -LiteralPath 'U:\') {
        Write-Host '[OK]   U: is visible' -ForegroundColor Green
    } elseif ($code -eq 0) {
        Write-Host '[?]    Mount script exited 0 but U:\ not listed yet — wait a few seconds.' -ForegroundColor Yellow
    }
    return $code
}

function Invoke-UserStorageMountAdmin {
    if (-not (Test-NextGpuUserStorageRepairPrincipal)) {
        throw 'MountAdmin requires Administrator.'
    }
    $invoke = Join-Path $script:UserStorageRoot 'Invoke-UserStorageMountFromAdmin.ps1'
    if (-not (Test-Path -LiteralPath $invoke)) { throw "Missing: $invoke" }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $invoke
    return $LASTEXITCODE
}

function Invoke-UserStorageStatus {
    Write-UserStorageBanner 'Mount status (live)'
    $live = Get-UserStorageLiveMountStatus
    Write-Host "  Drive:            $($live.DrivePath)"
    Write-Host "  Path reachable:   $($live.PathReachable)"
    Write-Host "  rclone PID:       $($live.MountPid) (running: $($live.RcloneRunning))"
    Write-Host "  Live mount:       $($live.LiveMount)" -ForegroundColor $(if ($live.LiveMount) { 'Green' } else { 'Red' })
    Write-Host "  State userId:     $($live.StateUserId)"
    Write-Host "  State session:    $($live.StateSessionId)  Current: $($live.CurrentSession)  Match: $($live.SameSession)"
    if ($live.LiveMount) {
        Write-Host ''
        Write-Host 'U: is mounted in THIS session. If This PC does not show it, run: User-Storage.bat Open' -ForegroundColor Cyan
        return 0
    }
    Write-Host ''
    Write-Host 'U: is NOT mounted now (old log lines can still say mounted).' -ForegroundColor Yellow
    Write-Host '  nextGPU: User-Storage.bat Mount'
    Write-Host '  Admin:   User-Storage.bat Sync, then renter reconnect Moonlight'
    return 1
}

function Invoke-UserStorageOpen {
    if ($env:USERNAME -ne 'nextGPU') {
        Write-Host '[WARN] Run as nextGPU in Moonlight, or Mount first.' -ForegroundColor Yellow
    }
    if (Show-UserStorageDriveInExplorer) {
        Write-Host '[OK]   Explorer opened on U:' -ForegroundColor Green
        return 0
    }
    return 1
}

function Invoke-UserStorageLogs {
    Write-UserStorageBanner 'Logs'
    foreach ($name in @('user-storage-mount.log', 'user-storage-ensure.log', 'user-storage-rclone-stderr.log')) {
        $path = Join-Path $script:NextGpuUserStorageLogDir $name
        Write-Host ''
        Write-Host "=== $name ===" -ForegroundColor Cyan
        if (Test-Path -LiteralPath $path) {
            Get-Content -LiteralPath $path -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        } else {
            Write-Host '(not found)' -ForegroundColor DarkGray
        }
    }
    return 0
}

function Resolve-UserStorageAutoAction {
    if ($env:USERNAME -ieq 'nextGPU') {
        if (-not (Test-Path -LiteralPath 'U:\')) { return 'Mount' }
        return 'Test'
    }
    if (Test-NextGpuUserStorageRepairPrincipal) {
        if (-not (Test-UserStorageRcloneConfigReady)) { return 'Setup' }
        if (-not (Test-NextGpuUserStoragePublishedScriptsCurrent)) { return 'Sync' }
        return 'Test'
    }
    return 'Test'
}

try {
    if ($Action -eq 'Help') {
        Show-UserStorageHelp
        exit 0
    }

    if ($Action -eq 'Menu') {
        do {
            $pick = Show-UserStorageMenu
            if ($pick -eq 'Quit') { exit 0 }
            if ($pick -eq 'Menu') { continue }
            $Action = $pick
            break
        } while ($true)
    }

    if ($Action -eq 'Auto') {
        $Action = Resolve-UserStorageAutoAction
        Write-Host "[*] Auto -> $Action" -ForegroundColor DarkGray
    }

    $exitCode = switch ($Action) {
        'Setup'      { Invoke-UserStorageSetup; 0 }
        'Sync'       { Invoke-UserStorageSync; 0 }
        'Test'       { Invoke-UserStorageTest }
        'Status'     { Invoke-UserStorageStatus }
        'Troubleshoot' { Invoke-UserStorageTroubleshoot }
        'Mount'      { Invoke-UserStorageMount }
        'Open'       { Invoke-UserStorageOpen }
        'MountAdmin' { Invoke-UserStorageMountAdmin }
        'Logs'       { Invoke-UserStorageLogs; 0 }
        default      { Show-UserStorageHelp; 0 }
    }
    exit $exitCode
} catch {
    Write-Host "[ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
