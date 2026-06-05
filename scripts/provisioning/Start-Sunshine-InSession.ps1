#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Run Sunshine in the active user session (not session 0) so display paths can be enumerated.
.DESCRIPTION
    Stops gpu-sunshine (LocalSystem service) and starts sunshine.exe in the current console/RDP session.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = 'SilentlyContinue'
$exe = 'C:\Program Files\Sunshine\sunshine.exe'
$svc = 'gpu-sunshine'

function Write-Status([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
}

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Status "[!] Sunshine not found: $exe"
    exit 1
}

function Start-WallpaperRefreshForStreamingDisplay {
    $wallpaperReady = Join-Path $PSScriptRoot '..\desktop\Start-WallpaperApplyAfterDisplayReady.ps1'
    if (-not (Test-Path -LiteralPath $wallpaperReady)) { return }
    $wallArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $wallpaperReady
    Start-Process -FilePath 'powershell.exe' -ArgumentList $wallArgs -WindowStyle Hidden | Out-Null
    Write-Status '[*] Wallpaper refresh scheduled for VDD/Moonlight (30s/90s/150s).'
}

if (Get-Process -Name sunshine -ErrorAction SilentlyContinue) {
    Write-Status '[*] Sunshine already running.'
    Start-WallpaperRefreshForStreamingDisplay
    exit 0
}

$svcState = (Get-Service -Name $svc -ErrorAction SilentlyContinue).Status
if ($svcState -eq 'Running') {
    Write-Status '[*] Stopping gpu-sunshine service (session 0)...'
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

Get-Process -Name sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500

$wd = Split-Path -Parent $exe
Start-Process -FilePath $exe -WorkingDirectory $wd
Start-Sleep -Seconds 2

if (Get-Process -Name sunshine -ErrorAction SilentlyContinue) {
    Write-Status '[*] Sunshine started in user session.'
    Start-WallpaperRefreshForStreamingDisplay
    exit 0
}

Write-Status '[!] Failed to start Sunshine. Sign in via RDP/console and run this script again.'
exit 1
