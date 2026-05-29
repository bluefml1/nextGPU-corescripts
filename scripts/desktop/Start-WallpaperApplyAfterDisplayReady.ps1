#Requires -Version 5.1
<#
.SYNOPSIS
    Re-apply wallpaper after Sunshine/VDD display is ready (Moonlight uses VDD, not RDP monitor).
.DESCRIPTION
    Runs delayed passes so wallpaper Span/Fit matches the display Moonlight actually streams.
    Started in background from Start-Sunshine-InSession.ps1.
#>
[CmdletBinding()]
param(
    [int[]]$DelaysSeconds = @(30, 90, 150),
    [string]$DefaultWallpaperPath = 'C:\Users\Public\Wallpaper\nextgputobu.jpeg'
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'WallpaperFitCommon.ps1')

$logDir = Join-Path $env:ProgramData 'nextGPU\logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$logFile = Join-Path $logDir 'wallpaper-after-display.log'

function Write-WallLog([string]$Message) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Add-Content -LiteralPath $logFile -Value $line -ErrorAction SilentlyContinue
}

Write-WallLog "start user=$env:USERNAME delays=$($DelaysSeconds -join ',')"

$pass = 0
foreach ($delay in $DelaysSeconds) {
    if ($delay -gt 0) { Start-Sleep -Seconds $delay }
    $pass++
    $layout = Get-DisplayWallpaperLayout
    $styleText = if ($layout.UseSpan) { 'Span (multi-monitor / Moonlight+VDD)' } else { 'Fit (single monitor)' }
    Write-WallLog "pass $pass monitors=$($layout.MonitorCount) style=$styleText"
    $refresh = ($pass -eq $DelaysSeconds.Count)
    [void](Invoke-WallpaperFitForCurrentUser -WallpaperPath $DefaultWallpaperPath -RefreshExplorer:$refresh)
}

Write-WallLog 'done'
