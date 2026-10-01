#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Run Sunshine in the active user session (not session 0) so display paths can be enumerated.
.DESCRIPTION
    Stops nextGPU gpu-sunshine (NSSM) and the official SunshineService when needed, then starts
    sunshine.exe in the current console/RDP session.

    Use -ForceRestart after sunshine.exe --creds so SunshineService reloads sunshine_state.json.
    Otherwise an old service instance keeps an empty in-memory username and /api/apps returns HTTP 307.
#>
[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$ForceRestart
)

$ErrorActionPreference = 'SilentlyContinue'
$exe = 'C:\Program Files\Sunshine\sunshine.exe'
$nssmSvc = 'gpu-sunshine'
$officialSvc = 'SunshineService'

function Write-Status([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
}

function Stop-NamedService([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    if ($svc.Status -eq 'Stopped') { return $true }
    Write-Status "[*] Stopping $Name..."
    Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $s = (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
        if ($s -eq 'Stopped') { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}

function Start-NamedService([string]$Name) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    if ($svc.Status -eq 'Running') { return $true }
    Write-Status "[*] Starting $Name..."
    Start-Service -Name $Name -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        $s = (Get-Service -Name $Name -ErrorAction SilentlyContinue).Status
        if ($s -eq 'Running') { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
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

function Start-UserStorageForStreamingSession {
    $helper = Join-Path $PSScriptRoot '..\runtime\Start-UserStorage-InSession.ps1'
    if (-not (Test-Path -LiteralPath $helper)) { return }
    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Quiet' -f $helper
    Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
    Write-Status '[*] User storage: triggering Task Scheduler (nextGPU-UserStorageMount).'
}

if (-not $ForceRestart -and (Get-Process -Name sunshine -ErrorAction SilentlyContinue)) {
    Write-Status '[*] Sunshine already running - refreshing wallpaper and user storage (U:).'
    Start-WallpaperRefreshForStreamingDisplay
    Start-UserStorageForStreamingSession
    exit 0
}

# Always stop NSSM helper if present (session 0).
[void](Stop-NamedService -Name $nssmSvc)

if ($ForceRestart) {
    Write-Status '[*] Force-restart: stop SunshineService + sunshine.exe so UI credentials reload...'
    [void](Stop-NamedService -Name $officialSvc)
}

Get-Process -Name sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$started = $false
if ($ForceRestart -and (Get-Service -Name $officialSvc -ErrorAction SilentlyContinue)) {
    # Official installer service owns the Web UI on :47990 — restart it to reload sunshine_state.json.
    $started = Start-NamedService -Name $officialSvc
}

if (-not $started) {
    $wd = Split-Path -Parent $exe
    Start-Process -FilePath $exe -WorkingDirectory $wd | Out-Null
    Start-Sleep -Seconds 3
    if (Get-Process -Name sunshine -ErrorAction SilentlyContinue) {
        $started = $true
    }
}

if ($started) {
    Write-Status '[*] Sunshine started (service and/or user-session process).'
    Start-WallpaperRefreshForStreamingDisplay
    Start-UserStorageForStreamingSession
    exit 0
}

Write-Status '[!] Failed to start Sunshine. Sign in via RDP/console and run this script again.'
exit 1
