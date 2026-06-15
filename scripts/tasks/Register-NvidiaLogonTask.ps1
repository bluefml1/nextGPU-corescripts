#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Register nextGPU-NvidiaLogon — starts NVIDIA App at any user logon.
#>
[CmdletBinding()]
param(
    [string]$StartScriptPath = '',
    [string]$TaskName = 'nextGPU-NvidiaLogon'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($StartScriptPath)) {
    $StartScriptPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'provisioning\Start-Nvidia-InSession.ps1'
}
if (-not (Test-Path -LiteralPath $StartScriptPath)) {
    throw "Start script not found: $StartScriptPath"
}

$helper = Join-Path (Split-Path $PSScriptRoot -Parent) 'desktop\NextGpuLogonTask.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Logon task helper not found: $helper"
}
. $helper

$psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f $StartScriptPath
Register-NextGpuAtLogonTask -TaskName $TaskName -Argument $psArgs -RunLevel Limited `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

Write-Host "[*] Registered scheduled task: $TaskName (NVIDIA starts at user logon)."
