#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Trigger U: mount while you are on Admin RDP (no need to RDP as nextGPU).
.EXAMPLE
    powershell -File Invoke-UserStorageMountFromAdmin.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')

Write-Host '=== Mount user storage from Administrator session ===' -ForegroundColor Cyan
Write-Host "Your session: $env:USERDOMAIN\$env:USERNAME"
Write-Host ''

if (-not (Test-UserStorageRcloneConfigReady)) {
    throw 'Run Setup-UserStorage.bat first (no rclone config).'
}

$null = Ensure-UserStoragePrerequisites

try {
    Set-UserStorageRcloneConfigAcl
    Write-Host '[OK]   rclone.conf ACL checked' -ForegroundColor Green
} catch {
    Write-Warning "ACL repair: $($_.Exception.Message)"
}

Write-Host "[*] Mount uses Task Scheduler only: $($script:NextGpuUserStorageMountTaskName)"
$mounted = Invoke-UserStorageMountForNextGpuSession -WaitSeconds 25 -ShowDiagnostics

$mountLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-mount.log'
$repoRoot = $null
if (Test-Path -LiteralPath $script:NextGpuRepoRootMarkerPath) {
    $repoRoot = (Get-Content -LiteralPath $script:NextGpuRepoRootMarkerPath -Raw).Trim()
}

Write-Host ''
Write-Host 'Logs:' -ForegroundColor Cyan
Write-Host "  $mountLog"
Write-Host "  $(Join-Path $script:NextGpuUserStorageLogDir 'user-storage-session.log')"
if ($repoRoot) {
    Write-Host "  $(Join-Path $repoRoot 'logs\user-storage-mount.log')  (mirror)"
}

if ($mounted) {
    Write-Host ''
    Write-Host '[OK]   Mount completed for nextGPU session. Renter should see U: in Moonlight.' -ForegroundColor Green
} else {
    Write-Host ''
    Write-Host '[WARN] Mount may not have finished. Wait 60s after Moonlight connect, or re-run this script.' -ForegroundColor Yellow
    Write-Host '       Ensure Administrator RDP is disconnected while renter uses Moonlight.' -ForegroundColor Yellow
}

if (Test-Path -LiteralPath 'U:\') {
    Write-Host '[INFO] U: visible in this Admin session (optional).' -ForegroundColor DarkGray
} else {
    Write-Host '[INFO] U: not visible in Admin session is normal - check Moonlight desktop.' -ForegroundColor DarkGray
}
