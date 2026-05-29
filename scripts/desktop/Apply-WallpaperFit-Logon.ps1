#Requires -Version 5.1
<#
.SYNOPSIS
    Per-logon rental desktop: Fit wallpaper (full image), hide desktop icons, clear user Desktop files.
.DESCRIPTION
    Re-applies 3840x2160 desktop master + Fit (full 4K image on any monitor size).
    Invoked by scheduled task nextGPU-WallpaperFitLogon (all users at logon).
#>
[CmdletBinding()]
param(
    [string]$DefaultWallpaperPath = 'C:\Users\Public\Wallpaper\nextgputobu.jpeg'
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'WallpaperFitCommon.ps1')

$wallpaperPath = Get-ConfiguredWallpaperPath -Fallback $DefaultWallpaperPath
if (-not $wallpaperPath) {
    exit 0
}

$clearFiles = $env:USERNAME -ieq 'nextGPU'
[void](Invoke-WallpaperFitForCurrentUser -WallpaperPath $wallpaperPath -HideDesktopIcons -ClearDesktopFiles:$clearFiles -RefreshExplorer)

exit 0
