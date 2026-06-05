#Requires -Version 5.1
<#
.SYNOPSIS
    Pre-flight checks for nextGPU recreate -> U: mount flow (run as Administrator after deploying scripts).
.EXAMPLE
    Test-NextGpuUserStorageRecreateReadiness.bat
    powershell -NoProfile -ExecutionPolicy Bypass -File Test-NextGpuUserStorageRecreateReadiness.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')

$fail = 0
function Test-Line {
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

Write-Host '=== nextGPU user storage recreate readiness ===' -ForegroundColor Cyan
Write-Host "Computer: $env:COMPUTERNAME  User: $env:USERDOMAIN\$env:USERNAME"

Test-Line 'Administrator or SYSTEM' (Test-NextGpuUserStorageRepairPrincipal) 'Required for Sync/Register'
Test-Line 'rclone.conf installed' (Test-UserStorageRcloneConfigReady) $script:NextGpuUserStorageRcloneConfigPath

$repoRuntime = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
Test-Line 'Repo runtime scripts present' (Test-Path -LiteralPath $repoRuntime) $PSScriptRoot

$ready = Test-UserStorageLogonMountReady -Quiet
Test-Line 'Logon mount ready (full)' $ready.Ok $(if (-not $ready.Ok) { "Failed: $($ready.Failed -join ', ')" } else { $script:NextGpuUserStorageRuntimeDir })

$user = Get-NextGpuRentalLocalUser
if ($user) {
    Test-Line 'nextGPU SID marker' (Test-NextGpuUserStorageBindingsCurrent) $user.SID.Value
} else {
    Test-Line 'nextGPU local account exists' $false 'Create nextGPU before rental logon'
}

$mount = Get-ScheduledTask -TaskName $script:NextGpuUserStorageMountTaskName -ErrorAction SilentlyContinue
if ($mount) {
    $triggers = $mount.Triggers
    $logonDelay = $null
    foreach ($t in $triggers) {
        if ($t.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $t.Delay) {
            $logonDelay = $t.Delay
        }
    }
    $expected = "PT$($script:NextGpuUserStorageMountLogonDelaySeconds)S"
    $delayOk = (-not $logonDelay) -or ($logonDelay -eq $expected) -or ($logonDelay.ToString() -eq $expected)
    Test-Line "Mount logon delay ~$($script:NextGpuUserStorageMountLogonDelaySeconds)s" $delayOk `
        $(if ($logonDelay) { "Actual: $logonDelay (re-run Sync if stale)" } else { 'No Delay property on this OS' })
}

Write-Host ''
Write-Host 'Recreate test procedure:' -ForegroundColor Cyan
Write-Host '  1) User-Storage.bat Sync (once after deploy)'
Write-Host '  2) Delete + recreate local user nextGPU'
Write-Host '  3) Log in as nextGPU (Moonlight)'
Write-Host '  4) Within ~30s: U: mounted; logs: user-storage-ensure.log + user-storage-mount.log'
Write-Host ''

if ($fail -gt 0) { exit 1 }
exit 0
