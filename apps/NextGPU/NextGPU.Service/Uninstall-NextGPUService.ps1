#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes NextGPUService Windows Service and registry metadata.
#>
param(
    [string]$ServiceName = "NextGPUService"
)

$ErrorActionPreference = "Stop"

$scriptName = Split-Path -Leaf $PSCommandPath
$logFile = "$env:TEMP\Uninstall-NextGPUService_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $Msg" | Tee-Object -FilePath $logFile -Append
}

Write-Log "=== $scriptName starting ==="

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log "Service '$ServiceName' not found. Nothing to uninstall."
    exit 0
}

Write-Log "Stopping service..."
Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
Write-Log "Deleting service..."
sc.exe delete $ServiceName 2>$null | Out-Null
Start-Sleep -Seconds 1

Write-Log "Removing registry metadata..."
$regPath = "HKLM:\SOFTWARE\NextGPU\Service"
if (Test-Path $regPath) {
    Remove-Item -Path $regPath -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Log "=== $scriptName completed ==="
