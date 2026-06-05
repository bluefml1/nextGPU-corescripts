#Requires -Version 5.1
<#
.SYNOPSIS
    Trigger U: mount via Task Scheduler only (nextGPU-UserStorageMount).
    Called from Start-Sunshine-InSession.ps1 or manually; does not call Mount-UserStorage.ps1 directly.
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    [int]$WaitSeconds = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
. $commonPath

$logFile = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-session.log'

function Write-SessionLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    Write-UserStorageLog -Message $Message -Level $Level -LogFile $logFile
}

try {
    Write-SessionLog "Start-UserStorage-InSession (USER=$env:USERDOMAIN\$env:USERNAME) -> Task: $($script:NextGpuUserStorageMountTaskName)"

    if (-not (Test-NextGpuUserStorageMountTaskRegistered)) {
        throw "Task $($script:NextGpuUserStorageMountTaskName) not registered. Run Setup-UserStorage.bat."
    }

    $sessionId = Get-NextGpuStreamingSessionId
    if ($sessionId -lt 0) {
        Write-SessionLog "No nextGPU session; cannot run Task Scheduler mount from USER=$env:USERNAME" -Level WARN
        foreach ($qline in (Get-NextGpuSessionQueryLines | Select-Object -First 10)) {
            Write-SessionLog "  $qline" -Level INFO
        }
        Write-SessionLog @"
Skipped schtasks /Run. nextGPU must be logged on (Moonlight desktop).
Automatic: logon trigger on $($script:NextGpuUserStorageMountTaskName) (~20s after nextGPU logon).
Manual: schtasks /Run /TN $($script:NextGpuUserStorageMountTaskName)  or  Mount-UserStorage-Now.bat
"@ -Level WARN
        exit 0
    }

    $info = Get-NextGpuSessionInfo
    Write-SessionLog "nextGPU session $($info.SessionId) ($($info.State)) - schtasks /Run /TN $($script:NextGpuUserStorageMountTaskName)"

    $result = Invoke-NextGpuUserStorageScheduledTask -Operation Mount -WaitSeconds $WaitSeconds
    $level = if ($result.Ok) { 'OK' } else { 'WARN' }
    Write-SessionLog "Task finished: LastTaskResult=$($result.LastTaskResult) MountLog=$($result.MountLogExists) State=$($result.StateExists)" -Level $level

    if (-not $Quiet -and -not $result.Ok) {
        Write-Host "[WARN] Mount task did not report success. See $logFile and user-storage-mount.log" -ForegroundColor Yellow
    }

    exit $(if ($result.Ok) { 0 } else { 1 })
}
catch {
    Write-SessionLog $_.Exception.Message -Level ERROR
    exit 1
}
