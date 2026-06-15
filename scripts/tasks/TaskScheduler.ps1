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
    'Register-EndSessionTask.ps1'
)

foreach ($scriptName in $taskScripts) {
    $scriptPath = Join-Path $PSScriptRoot $scriptName
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Task registration script not found: $scriptPath"
    }
    Write-Host "[*] Running $scriptName..."
    & $scriptPath
}

Write-Host '[*] All scheduled tasks registered.'
