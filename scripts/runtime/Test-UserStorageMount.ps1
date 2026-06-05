#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnose per-user S3 storage mount (run as nextGPU, or as Admin to preview checks).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')

Write-Host '=== nextGPU user storage diagnostics ===' -ForegroundColor Cyan
Write-Host "User: $env:USERDOMAIN\$env:USERNAME"

$fail = 0
function Test-Check {
    param([string]$Label, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
    } else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor Yellow }
        $script:fail++
    }
}

Test-Check 'Running as nextGPU' ($env:USERNAME -ieq 'nextGPU') 'Admin+Moonlight: use Invoke-UserStorageMountFromAdmin.ps1'
$ngSid = Get-NextGpuActiveSessionId
if ($ngSid -ge 0) {
    Test-Check 'nextGPU Active session' $true "SessionId=$ngSid"
}

Test-Check 'rclone config' (Test-UserStorageRcloneConfigReady) $script:NextGpuUserStorageRcloneConfigPath
$rclone = Get-RcloneExeForUserStorage
Test-Check 'rclone.exe' ([bool]$rclone) $(if ($rclone) { $rclone } else { 'winget install Rclone.Rclone' })
Test-Check 'WinFsp' (Test-WinFspInstalled) 'Run Setup-UserStorage.bat as Administrator'

try {
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Get-NextGpuRepoRoot -StartPath $PSScriptRoot
    }
    Test-Check 'Repo root / domain.txt' $true $RepoRoot
    $domain = Get-NextGpuDomainFromFile -RepoRoot $RepoRoot
    Test-Check 'DOMAIN in domain.txt' $true $domain
    try {
        $api = Invoke-CheckDomainApi -Domain $domain
        $uid = $api.userID
        Test-Check 'checkDomain API' ([bool]$uid) "userID=$uid lastName=$($api.lastName)"
    } catch {
        Test-Check 'checkDomain API' $false $_.Exception.Message
    }
} catch {
    Test-Check 'Repo root / domain.txt' $false $_.Exception.Message
}

Test-Check 'Bindings current' (Test-NextGpuUserStorageBindingsCurrent) 'Stale after recreate until ensure/Sync'
Test-Check 'Published scripts current' (Test-NextGpuUserStoragePublishedScriptsCurrent) 'Admin: Sync from repo'

$ensure = Get-ScheduledTask -TaskName $script:NextGpuUserStorageEnsureTaskName -ErrorAction SilentlyContinue
Test-Check 'Ensure scheduled task' ([bool]$ensure) $script:NextGpuUserStorageEnsureTaskName

$task = Get-ScheduledTask -TaskName 'nextGPU-UserStorageMount' -ErrorAction SilentlyContinue
Test-Check 'Logon scheduled task' ([bool]$task) 'nextGPU-UserStorageMount'
if ($task) {
    $info = Get-ScheduledTaskInfo -TaskName 'nextGPU-UserStorageMount' -ErrorAction SilentlyContinue
    if ($info) {
        Write-Host "       Last run: $($info.LastRunTime)  Result: $($info.LastTaskResult)" -ForegroundColor DarkGray
    }
}

$mountLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-mount.log'
if (Test-Path -LiteralPath $mountLog) {
    Write-Host ''
    Write-Host "Last 15 lines of $mountLog :" -ForegroundColor Cyan
    Get-Content -LiteralPath $mountLog -Tail 15 | ForEach-Object { Write-Host $_ }
} else {
    Write-Host ''
    Write-Host "No mount log yet: $mountLog" -ForegroundColor Yellow
}

Write-Host ''
if ($env:USERNAME -eq 'nextGPU') {
    Write-Host 'To mount now (interactive):' -ForegroundColor Cyan
    Write-Host "  powershell -ExecutionPolicy Bypass -File `"$PSScriptRoot\Mount-UserStorage.ps1`""
} else {
    Write-Host 'Log on as nextGPU, wait ~60s after logon, or run Mount-UserStorage.ps1 as nextGPU.' -ForegroundColor Cyan
}

if ($fail -gt 0) { exit 1 }
exit 0
