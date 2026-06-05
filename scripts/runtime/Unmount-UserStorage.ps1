#Requires -Version 5.1
<#
.SYNOPSIS
    Unmount nextGPU user S3 storage drive and stop the rclone mount process.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    throw "UserStorageCommon.ps1 not found: $commonPath"
}
. $commonPath

$logFile = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-unmount.log'

function Write-UnmountLog {
    param([string]$Message, [string]$Level = 'INFO')
    Write-UserStorageLog -Message $Message -Level $Level -LogFile $logFile
}

try {
    $state = Get-UserStorageState
    $letter = 'U'
    $mountPid = 0

    if ($state) {
        if ($state.driveLetter) { $letter = [string]$state.driveLetter }
        if ($state.mountPid) { $mountPid = [int]$state.mountPid }
        Write-UnmountLog "Unmounting user storage (drive ${letter}:, PID $mountPid, user $($state.userId))."
    } else {
        Write-UnmountLog 'No user-storage state file; attempting best-effort unmount of U:.' -Level WARN
    }

    Stop-UserStorageMountProcess -MountPid $mountPid -DriveLetter $letter
    Clear-UserStorageState
    Remove-UserStorageMountLock -Force

    Write-UnmountLog 'User storage unmounted and state cleared.' -Level OK
    exit 0
}
catch {
    Write-UnmountLog $_.Exception.Message -Level ERROR
    Clear-UserStorageState
    exit 1
}
