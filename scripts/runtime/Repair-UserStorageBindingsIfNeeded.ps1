#Requires -Version 5.1
<#
.SYNOPSIS
    Idempotent bindings repair (SYSTEM/Admin). Optional manual run; logon uses nextGPU-UserStorageEnsureBindings instead.
#>
[CmdletBinding()]
param([switch]$Quiet)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    $commonPath = Join-Path $env:ProgramData 'nextGPU\scripts\runtime\UserStorageCommon.ps1'
}
if (-not (Test-Path -LiteralPath $commonPath)) {
    exit 0
}
. $commonPath

$logFile = Join-Path $script:NextGpuUserStorageLogDir 'user-storage-ensure.log'

if (-not (Test-UserStorageRcloneConfigReady)) {
    exit 0
}
if (Test-NextGpuUserStorageBindingsCurrent) {
    if (-not $Quiet) {
        Write-UserStorageLog 'Repair-UserStorageBindingsIfNeeded: bindings already current.' -Level INFO -LogFile $logFile
    }
    exit 0
}

$sourceDir = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')) {
    $PSScriptRoot
} else {
    $script:NextGpuUserStorageRuntimeDir
}
try {
    $ok = Sync-NextGpuUserStorageForLocalUser -SourceDir $sourceDir
} catch {
    Write-UserStorageLog "Repair-UserStorageBindingsIfNeeded: $($_.Exception.Message)" -Level ERROR -LogFile $logFile
    $ok = $false
}
$ok = $ok -and (Test-NextGpuUserStorageBindingsCurrent)
if (-not $Quiet) {
    $level = if ($ok) { 'OK' } else { 'WARN' }
    Write-UserStorageLog "Repair-UserStorageBindingsIfNeeded: finished (bindings current=$ok)." -Level $level -LogFile $logFile
}
exit $(if ($ok) { 0 } else { 1 })
