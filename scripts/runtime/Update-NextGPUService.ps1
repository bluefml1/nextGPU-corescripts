#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Stops the service, copies the new binary, restarts the service.
#>
param(
    [string]$SourcePath,
    [string]$ServiceName = "NextGPUService",
    [string]$BinaryPath = "$env:ProgramFiles\NextGPU\Service\NextGPUService.exe"
)

$ErrorActionPreference = "Stop"

if (-not $SourcePath) {
    $SourcePath = Join-Path $PSScriptRoot "..\..\apps\NextGPU\NextGPU.Service\bin\Release\net8.0-windows\win-x64\publish\NextGPUService.exe"
}

if (-not (Test-Path $SourcePath)) {
    Write-Error "Source binary not found: $SourcePath"
    Write-Error "Build with: dotnet publish apps/NextGPU/NextGPU.Service -c Release -o <path>"
    exit 1
}

Write-Output "Stopping service..."
Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$dir = Split-Path -Parent $BinaryPath
if (-not (Test-Path $dir)) {
    New-Item -Path $dir -ItemType Directory -Force | Out-Null
}

Write-Output "Copying new binary..."
Copy-Item -Path $SourcePath -Destination $BinaryPath -Force -Recurse

Write-Output "Starting service..."
Start-Service -Name $ServiceName -ErrorAction Stop
$svc = Get-Service -Name $ServiceName
Write-Output "Service status: $($svc.Status)"
