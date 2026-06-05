#Requires -Version 5.1
<#
.SYNOPSIS
    Re-bind user storage to current nextGPU only when needed (new SID after recreate). Runs as SYSTEM at startup/logon.
.NOTES
    Registered once by Setup-UserStorage.bat. Do not run Setup again after recreating nextGPU.
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

$ensureLog = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-ensure.log'

function Write-EnsureMessage {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    Write-UserStorageLog -Message $Message -Level $Level -LogFile $ensureLog
    if (-not $Quiet) {
        switch ($Level) {
            'ERROR' { Write-Host $Message -ForegroundColor Red }
            'WARN'  { Write-Host $Message -ForegroundColor Yellow }
            'OK'    { Write-Host $Message -ForegroundColor Green }
            default { Write-Host $Message }
        }
    }
}

if (-not (Test-UserStorageRcloneConfigReady)) {
    exit 0
}

if (-not (Test-NextGpuUserStorageLogonAutomationNeedRepair)) {
    $null = Set-NextGpuRentalUserStorageAccess
    if (-not $Quiet) {
        Write-EnsureMessage 'Logon auto-mount tasks current; ACLs refreshed.' -Level INFO
    }
    exit 0
}

$user = Get-NextGpuRentalLocalUser
if (-not $user) {
    Write-EnsureMessage 'nextGPU account missing; skip logon task repair until user exists.' -Level WARN
    exit 0
}

Write-EnsureMessage "Repairing logon auto-mount for $($user.Name) (SID $($user.SID))." -Level INFO
try {
    $sourceDir = Get-NextGpuUserStorageSyncSourceDir -FallbackDir $PSScriptRoot
    Write-EnsureMessage "Repair source: $sourceDir" -Level INFO
    $ok = Repair-NextGpuUserStorageLogonAutomation -SourceDir $sourceDir -Quiet
    if ($ok) {
        Write-EnsureMessage 'Logon auto-mount repaired (mount task +22s after sign-in).' -Level OK
        exit 0
    }
    Write-EnsureMessage 'Logon automation repair incomplete.' -Level ERROR
    exit 1
} catch {
    Write-EnsureMessage "Repair failed: $($_.Exception.Message)" -Level ERROR
    exit 1
}
