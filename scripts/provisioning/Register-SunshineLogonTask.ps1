#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Register nextGPU-SunshineLogon — starts Sunshine in the logged-on user session (fixes display ACCESS_DENIED in session 0).
#>
[CmdletBinding()]
param(
    [string]$StartScriptPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($StartScriptPath)) {
    $StartScriptPath = Join-Path $PSScriptRoot 'Start-Sunshine-InSession.ps1'
}
if (-not (Test-Path -LiteralPath $StartScriptPath)) {
    throw "Start script not found: $StartScriptPath"
}

$taskName = 'nextGPU-SunshineLogon'
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'desktop\NextGpuLogonTask.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    $helper = Join-Path $PSScriptRoot '..\desktop\NextGpuLogonTask.ps1'
}
. $helper

# -Argument must be one string (array breaks on Windows PowerShell 5.1).
$psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f $StartScriptPath
Register-NextGpuAtLogonTask -TaskName $taskName -Argument $psArgs -RunLevel Highest `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1)
Write-Host "[*] Registered scheduled task: $taskName (Sunshine starts at user logon, not in session 0)."
