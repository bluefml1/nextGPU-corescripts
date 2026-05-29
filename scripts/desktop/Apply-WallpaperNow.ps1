#Requires -Version 5.1
<#
.SYNOPSIS
    Force desktop wallpaper apply NOW (current user session). Use when setup ran but desktop still crops.

.DESCRIPTION
    Clears theme cache, rebuilds 4K master, sets Fit registry, restarts Explorer.
    Run while logged in as the user who sees the wrong desktop (nextGPU or Administrator).
    HKLM PersonalizationCSP runs only if this PowerShell is elevated (Administrator).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\desktop\Apply-WallpaperNow.ps1
.EXAMPLE
    # Then check:
    powershell -ExecutionPolicy Bypass -File scripts\desktop\Test-WallpaperPolicy.ps1
#>
[CmdletBinding()]
param(
    [string]$SourceWallpaper = 'C:\Users\Public\Wallpaper\nextgputobu.jpeg'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'WallpaperFitCommon.ps1')

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "=== Apply wallpaper now (user: $env:USERNAME, admin: $isAdmin) ===" -ForegroundColor Cyan

if (-not (Test-Path -LiteralPath $SourceWallpaper)) {
    Write-Error "Source not found: $SourceWallpaper. Run Setup-Wallpaper.bat first."
}

Write-Host '[*] Rebuilding 4K master...'
$master = Ensure-4KDesktopWallpaper -SourceImagePath $SourceWallpaper -ForceRebuild
Write-Host "[*] Master file: $master"

if ($isAdmin) {
    Write-Host '[*] Setting HKLM PersonalizationCSP (lock + desktop)...'
    Set-PersonalizationCspWallpaper -LockScreenImagePath $SourceWallpaper -DesktopImagePath $master
    Write-Host '[*] gpupdate /target:user ...'
    & gpupdate.exe /force /target:user 2>&1 | Out-Null
} else {
    Write-Host '[!] Not elevated: skipped HKLM CSP (run as Administrator once for machine policy).'
}

Write-Host '[*] Applying HKCU Fit + clearing cache + restarting Explorer...'
[void](Invoke-WallpaperFitForCurrentUser -WallpaperPath $SourceWallpaper -HideDesktopIcons -RefreshExplorer)

Write-Host ''
Write-Host '[*] Done. Check with: scripts\desktop\Test-WallpaperPolicy.ps1' -ForegroundColor Green
Write-Host '[*] If desktop is STILL cropped:' -ForegroundColor Yellow
Write-Host '    1) Sign OUT (not only lock) and sign back in as the rental user (nextGPU).' -ForegroundColor Yellow
Write-Host '    2) Or reboot once after Setup-Wallpaper.bat (HKLM policy often needs a full restart).' -ForegroundColor Yellow
Write-Host '    3) Test as the same user renters use — Administrator profile is separate HKCU.' -ForegroundColor Yellow
