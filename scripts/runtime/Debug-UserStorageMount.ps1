#Requires -Version 5.1
<#
.SYNOPSIS
    Step-by-step checks + optional foreground rclone mount (see errors in this window).
.EXAMPLE
    Run as nextGPU:  powershell -File Debug-UserStorageMount.ps1
    Run as Admin:    powershell -File Debug-UserStorageMount.ps1 -FixAcl
#>
[CmdletBinding()]
param(
    [switch]$FixAcl,
    [switch]$ForegroundMount,
    [string]$DriveLetter = 'U'
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')

$letter = $DriveLetter.TrimEnd(':').ToUpperInvariant()
$drivePath = "${letter}:"

if ($FixAcl) {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host '[FAIL] -FixAcl requires Administrator.' -ForegroundColor Red
        exit 1
    }
    $sourceDir = Get-NextGpuUserStorageSyncSourceDir -FallbackDir $PSScriptRoot
    $ok = Sync-NextGpuUserStorageForLocalUser -SourceDir $sourceDir
    Write-Host "Sync result: $ok"
}

$code = Show-NextGpuUserStorageRenterDiagnostics -DriveLetter $letter
if (-not $ForegroundMount) {
    $pubMount = Join-Path $script:NextGpuUserStorageRuntimeDir 'Mount-UserStorage.ps1'
    Write-Host ''
    Write-Host 'Manual mount (same as auto task):' -ForegroundColor Cyan
    Write-Host "  powershell -File `"$pubMount`""
    Write-Host 'Foreground rclone (errors in this window):' -ForegroundColor Cyan
    Write-Host "  powershell -File `"$PSCommandPath`" -ForegroundMount"
    exit $code
}

if ($env:USERNAME -ine 'nextGPU') {
    Write-Host '[FAIL] -ForegroundMount requires nextGPU session.' -ForegroundColor Red
    exit 1
}

$rclone = Get-RcloneExeForUserStorage
if (-not $rclone -or -not (Test-WinFspInstalled)) {
    Write-Host '[FAIL] Install rclone/WinFsp via Setup-UserStorage.bat (Admin).' -ForegroundColor Red
    exit 1
}

try {
    $domain = Get-NextGpuDomainFromFile
    $api = Invoke-CheckDomainApi -Domain $domain
    $userId = $api.userID
    if ([string]::IsNullOrWhiteSpace($userId)) { throw 'checkDomain missing userID' }
} catch {
    Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '=== Foreground mount (Ctrl+C to stop) ===' -ForegroundColor Cyan
$remotePath = Get-UserStorageRemotePathForUserId -UserId $userId -RcloneExe $rclone
$labelName = if ($api.labelName) { $api.labelName } else { $api.lastName }
$volumeLabel = Get-UserStorageVolumeLabel -LastName $labelName
$extras = Get-UserStorageRcloneMountExtraArgs -RcloneExe $rclone -VolumeLabel $volumeLabel
$args = @(
    'mount', $remotePath, $drivePath,
    '--config', $script:NextGpuUserStorageRcloneConfigPath,
    '--vfs-cache-mode', 'off',
    '--dir-cache-time', '30s',
    '--attr-timeout', '30s',
    '--log-level', 'INFO'
) + $extras

Write-Host "  $rclone $($args -join ' ')"
& $rclone @args
