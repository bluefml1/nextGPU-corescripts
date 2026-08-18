#Requires -Version 5.1
<#
.SYNOPSIS
    Quick layout and helper checks before running setup or uninstall on Windows.
.EXAMPLE
    powershell -File .\scripts\maintenance\Test-NextGpuLayout.ps1
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'
$fail = 0

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    if ($env:NEXTGPU_REPO_ROOT) {
        $RepoRoot = $env:NEXTGPU_REPO_ROOT
    } elseif ($PSScriptRoot) {
        $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    } else {
        throw 'Pass -RepoRoot or set NEXTGPU_REPO_ROOT'
    }
}
$RepoRoot = $RepoRoot.TrimEnd('\')

function Test-PathRequired {
    param([string]$RelativePath, [string]$Label)
    $full = Join-Path $RepoRoot $RelativePath
    if (Test-Path -LiteralPath $full) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
        return $true
    }
    Write-Host "[FAIL] $Label -> $full" -ForegroundColor Red
    $script:fail++
    return $false
}

Write-Host "Repo root: $RepoRoot"
Write-Host ''

$required = @(
    @('RegisterMachine_Beta.bat', 'Root setup launcher'),
    @('uninstall-all.bat', 'Root uninstall launcher'),
    @('scripts\provisioning\RegisterMachine_Beta.bat', 'Main setup script'),
    @('scripts\maintenance\Uninstall-NextGPU.ps1', 'Uninstall script'),
    @('scripts\maintenance\uninstall-all.bat', 'Uninstall wrapper'),
    @('scripts\desktop\DefaultUserHive.ps1', 'Default-user hive helper'),
    @('scripts\desktop\Set-ShutdownPolicy.ps1', 'Shutdown policy'),
    @('scripts\desktop\NextGpuLogonTask.ps1', 'Logon task helper'),
    @('scripts\desktop\Set-DesktopWallpaper-Gpo.ps1', 'Wallpaper policy'),
    @('scripts\desktop\Release-DefaultUserHives.ps1', 'Hive release helper'),
    @('scripts\desktop\Clear-NextGpuUserDesktop.ps1', 'nextGPU desktop cleanup'),
    @('scripts\desktop\Register-NextGpuDesktopCleanupTask.ps1', 'nextGPU desktop logon task'),
    @('scripts\provisioning\VddDisplaySelection.ps1', 'VDD log/display selection helpers'),
    @('scripts\provisioning\Get-DisplayDeviceId.ps1', 'Sunshine display ID'),
    @('scripts\provisioning\Get-SunshineDeviceIdFromLog.ps1', 'Sunshine log device_id parser'),
    @('scripts\provisioning\Register-SunshineLogonTask.ps1', 'Sunshine logon task'),
    @('scripts\provisioning\Start-Sunshine-InSession.ps1', 'Sunshine session start'),
    @('scripts\provisioning\Start-Nvidia-InSession.ps1', 'NVIDIA session start'),
    @('scripts\provisioning\Invoke-SunshineApiRestart.ps1', 'Sunshine API restart helper'),
    @('scripts\provisioning\Install-SunshineScripts.ps1', 'Sunshine config and script deploy'),
    @('scripts\provisioning\Set-SunshineVddOutput.ps1', 'Sunshine VDD output_name setup'),
    @('scripts\provisioning\Invoke-PostSunshineSetup.ps1', 'Post-Sunshine setup orchestrator'),
    @('scripts\provisioning\Update-NextGpuStreamingStack.ps1', 'Shared Sunshine/Moonlight stack update'),
    @('scripts\runtime\Run-StreamingStackUpdate.bat', 'Streaming stack batch wrapper'),
    @('scripts\runtime\auto-repair.bat', 'Auto-repair'),
    @('scripts\runtime\heartbeat-only.bat', 'Heartbeat'),
    @('scripts\tasks\NextGpuScheduledTaskCommon.ps1', 'Scheduled task common helper'),
    @('scripts\tasks\Invoke-ScheduledRuntimeBat.ps1', 'Scheduled task BAT runner'),
    @('scripts\tasks\Register-HeartbeatTask.ps1', 'Heartbeat scheduled task'),
    @('scripts\tasks\Register-AutoRepairTask.ps1', 'Auto-repair scheduled task'),
    @('scripts\tasks\Register-AutoUpdateTask.ps1', 'Auto-update scheduled task'),
    @('scripts\tasks\Register-NvidiaLogonTask.ps1', 'NVIDIA logon scheduled task'),
    @('scripts\tasks\Register-EndSessionTask.ps1', 'EndSession scheduled task'),
    @('scripts\tasks\Register-NextGpuEndSessionRecoveryTask.ps1', 'EndSession recovery AtStartup task'),
    @('scripts\runtime\Recover-NextGpuEndSessionAtStartup.ps1', 'EndSession recovery runner'),
    @('scripts\runtime\NextGpuEndSessionCommon.ps1', 'EndSession pending-flag helpers'),
    @('scripts\tasks\TaskScheduler.ps1', 'Task scheduler orchestrator'),
    @('scripts\runtime\UserStorageCommon.ps1', 'User S3 storage common'),
    @('scripts\runtime\Mount-UserStorage.ps1', 'User S3 mount'),
    @('scripts\runtime\Unmount-UserStorage.ps1', 'User S3 unmount'),
    @('scripts\runtime\Install-UserStorageRcloneConfig.ps1', 'User S3 rclone config'),
    @('scripts\runtime\Register-UserStorageTasks.ps1', 'User S3 scheduled tasks'),
    @('scripts\runtime\SessionFolderRules-Common.ps1', 'Session folder rules common'),
    @('scripts\runtime\Invoke-SessionFolderRules.ps1', 'Session folder rules runner'),
    @('scripts\runtime\Register-SessionFolderRulesTasks.ps1', 'Session folder rules tasks'),
    @('scripts\runtime\Merge-SessionFolderRules.ps1', 'Session folder rules CRUD'),
    @('scripts\runtime\Seed-SessionFolderTemplates.ps1', 'Session template seeding'),
    @('config\session-folder-rules.json.template', 'Session folder rules template'),
    @('scripts\runtime\Setup-UserStorage.bat', 'User S3 setup wrapper'),
    @('scripts\runtime\Start-UserStorage-InSession.ps1', 'User S3 Sunshine session hook'),
    @('scripts\runtime\Invoke-UserStorageMountFromAdmin.ps1', 'User S3 admin mount trigger'),
    @('scripts\runtime\Troubleshoot-UserStorage.ps1', 'User S3 troubleshoot'),
    @('assets\nextgputobu.jpeg', 'Wallpaper asset')
)

foreach ($item in $required) {
    Test-PathRequired -RelativePath $item[0] -Label $item[1] | Out-Null
}

Write-Host ''
Write-Host 'Optional PlayNiteWatcher (step 05)...'
$playniteOptional = @(
    @('PlayNiteWatcher\Setup-PlayniteSteam.bat', 'PlayNite setup launcher'),
    @('PlayNiteWatcher\Setup-PlayniteSteam.ps1', 'PlayNite setup script'),
    @('PlayNiteWatcher\Playnite-Common.ps1', 'PlayNite shared helpers')
)
foreach ($item in $playniteOptional) {
    $full = Join-Path $RepoRoot $item[0]
    if (Test-Path -LiteralPath $full) {
        Write-Host "[INFO] $($item[1]) present" -ForegroundColor Cyan
    } else {
        Write-Host "[INFO] $($item[1]) missing (optional unless using Get Started step 05) -> $full" -ForegroundColor DarkGray
    }
}

Write-Host ''
Write-Host 'Helper load test...'
$hivePath = Join-Path $RepoRoot 'scripts\desktop\DefaultUserHive.ps1'
if (Test-Path -LiteralPath $hivePath) {
    . $hivePath
    if (Get-Command Invoke-RegExe -ErrorAction SilentlyContinue) {
        Write-Host '[OK]   DefaultUserHive: Invoke-RegExe' -ForegroundColor Green
    } else {
        Write-Host '[FAIL] DefaultUserHive: Invoke-RegExe missing' -ForegroundColor Red
        $fail++
    }
    if (Get-Command Invoke-DefaultUserNtuserScript -ErrorAction SilentlyContinue) {
        Write-Host '[OK]   DefaultUserHive: Invoke-DefaultUserNtuserScript' -ForegroundColor Green
    } else {
        Write-Host '[FAIL] DefaultUserHive: Invoke-DefaultUserNtuserScript missing' -ForegroundColor Red
        $fail++
    }
}

$vddSelectPath = Join-Path $RepoRoot 'scripts\provisioning\VddDisplaySelection.ps1'
if (Test-Path -LiteralPath $vddSelectPath) {
    . $vddSelectPath
    if (Get-Command Test-VddDisplaySelectionSamples -ErrorAction SilentlyContinue) {
        if (Test-VddDisplaySelectionSamples) {
            Write-Host '[OK]   VddDisplaySelection sample tests' -ForegroundColor Green
        } else {
            Write-Host '[FAIL] VddDisplaySelection sample tests' -ForegroundColor Red
            $fail++
        }
    }
}

$shutdownPath = Join-Path $RepoRoot 'scripts\desktop\Set-ShutdownPolicy.ps1'
if (Test-Path -LiteralPath $shutdownPath) {
    $bad = Select-String -LiteralPath $shutdownPath -Pattern 'Invoke-RegExe\s+-ArgumentList' -SimpleMatch:$false
    if ($bad) {
        Write-Host '[FAIL] Set-ShutdownPolicy.ps1 still uses -ArgumentList on Invoke-RegExe' -ForegroundColor Red
        $fail++
    } else {
        Write-Host '[OK]   Set-ShutdownPolicy.ps1 Invoke-RegExe parameter name' -ForegroundColor Green
    }
}

Write-Host ''
if ($fail -gt 0) {
    Write-Host "FAILED: $fail check(s). Fix layout or copy the full repo before setup/uninstall." -ForegroundColor Red
    exit 1
}
Write-Host 'All layout checks passed. Ready for RegisterMachine_Beta.bat or uninstall-all.bat on Windows.' -ForegroundColor Green
exit 0
