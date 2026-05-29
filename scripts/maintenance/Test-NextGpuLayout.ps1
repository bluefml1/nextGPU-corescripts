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
    @('scripts\desktop\Set-DesktopWallpaper-Gpo.ps1', 'Wallpaper policy'),
    @('scripts\desktop\Release-DefaultUserHives.ps1', 'Hive release helper'),
    @('scripts\desktop\Clear-NextGpuUserDesktop.ps1', 'nextGPU desktop cleanup'),
    @('scripts\desktop\Register-NextGpuDesktopCleanupTask.ps1', 'nextGPU desktop logon task'),
    @('scripts\provisioning\Get-DisplayDeviceId.ps1', 'Sunshine display ID'),
    @('scripts\provisioning\Get-SunshineDeviceIdFromLog.ps1', 'Sunshine log device_id parser'),
    @('scripts\provisioning\Register-SunshineLogonTask.ps1', 'Sunshine logon task'),
    @('scripts\provisioning\Start-Sunshine-InSession.ps1', 'Sunshine session start'),
    @('scripts\provisioning\Invoke-SunshineApiRestart.ps1', 'Sunshine API restart helper'),
    @('scripts\runtime\auto-repair.bat', 'Auto-repair'),
    @('scripts\runtime\heartbeat-only.bat', 'Heartbeat'),
    @('assets\nextgputobu.jpeg', 'Wallpaper asset')
)

foreach ($item in $required) {
    Test-PathRequired -RelativePath $item[0] -Label $item[1] | Out-Null
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
