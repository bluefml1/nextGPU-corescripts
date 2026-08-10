#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Registers all NextGPU scheduled tasks by calling task-specific scripts.
#>
$ErrorActionPreference = 'Stop'

$taskScripts = @(
    'Register-HeartbeatTask.ps1',
    'Register-AutoRepairTask.ps1',
    'Register-AutoUpdateTask.ps1',
    'Register-NvidiaLogonTask.ps1',
    'Register-EndSessionTask.ps1',
    'launchGameTaskScheduler.ps1'
)

foreach ($scriptName in $taskScripts) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Task registration script not found: $scriptPath"
    }
    Write-Host "[*] Running $scriptName..."
    & $scriptPath
}

# Playnite logon lives under PlayNiteWatcher (not scripts/tasks).
$repoRoot = if ($env:NEXTGPU_REPO_ROOT) {
    $env:NEXTGPU_REPO_ROOT
} else {
    (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$playniteLogon = Join-Path $repoRoot 'PlayNiteWatcher\Register-PlayniteLogonTask.ps1'
if (Test-Path -LiteralPath $playniteLogon) {
    Write-Host '[*] Running Register-PlayniteLogonTask.ps1...'
    try {
        & $playniteLogon
    }
    catch {
        Write-Warning "Playnite logon registration skipped/failed: $($_.Exception.Message)"
    }
}
else {
    Write-Host '[*] Register-PlayniteLogonTask.ps1 not found — skip (run Playnite setup later).'
}

Write-Host '[*] All scheduled tasks registered.'
