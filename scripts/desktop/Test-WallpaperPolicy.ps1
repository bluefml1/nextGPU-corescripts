#Requires -Version 5.1
<#
.SYNOPSIS
    Report what wallpaper policy is actually active (run on the GPU PC after setup/logon).

.DESCRIPTION
    Prints file sizes, registry (HKCU + HKLM CSP), scheduled task, and what should be working.
    Green [OK] = looks correct. Yellow [WARN] = mismatch. Red [FAIL] = missing/broken.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts\desktop\Test-WallpaperPolicy.ps1
#>
[CmdletBinding()]
param(
    [string]$PublicWallpaperDir = 'C:\Users\Public\Wallpaper'
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'WallpaperFitCommon.ps1')

$sourceName = $script:WallpaperSourceFileName
$fourKName = $script:Desktop4KFileName
$sourcePath = Join-Path $PublicWallpaperDir $sourceName
$fourKPath = Join-Path $PublicWallpaperDir $fourKName

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===') -ForegroundColor Cyan
}

function Write-Check {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,
        [string]$Message
    )
    $color = switch ($Status) {
        'OK' { 'Green' }
        'WARN' { 'Yellow' }
        'FAIL' { 'Red' }
        'INFO' { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $color
}

function Get-RegString {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$Name
}

function Get-RegDword {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $p = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$Name
}

Write-Host 'NextGPU wallpaper diagnostic' -ForegroundColor White
Write-Host ('User: {0}  Computer: {1}' -f $env:USERNAME, $env:COMPUTERNAME)

# --- Files ---
Write-Section 'Wallpaper files'
if (Test-Path -LiteralPath $sourcePath) {
    $dims = Get-ImagePixelSize -ImagePath $sourcePath
    $dimText = if ($dims) { '{0}x{1}' -f $dims.Width, $dims.Height } else { 'unknown' }
    $mb = [Math]::Round((Get-Item -LiteralPath $sourcePath).Length / 1MB, 2)
    Write-Check -Status 'OK' -Message "$sourceName exists ($dimText, ${mb} MB) -> $sourcePath"
    if ($dims -and ($dims.Width -ne $script:WallpaperNative4KWidth -or $dims.Height -ne $script:WallpaperNative4KHeight)) {
        Write-Check -Status 'WARN' -Message "Source is not $($script:WallpaperNative4KWidth)x$($script:WallpaperNative4KHeight); setup should build $fourKName"
    }
} else {
    Write-Check -Status 'FAIL' -Message "Missing source: $sourcePath"
}

if (Test-Path -LiteralPath $fourKPath) {
    $dims4 = Get-ImagePixelSize -ImagePath $fourKPath
    $dim4 = if ($dims4) { '{0}x{1}' -f $dims4.Width, $dims4.Height } else { 'unknown' }
    $mb4 = [Math]::Round((Get-Item -LiteralPath $fourKPath).Length / 1MB, 2)
    Write-Check -Status 'OK' -Message "$fourKName exists ($dim4, ${mb4} MB) -> $fourKPath"
    if ($dims4 -and ($dims4.Width -ne $script:WallpaperNative4KWidth -or $dims4.Height -ne $script:WallpaperNative4KHeight)) {
        Write-Check -Status 'WARN' -Message "4K master should be $($script:WallpaperNative4KWidth)x$($script:WallpaperNative4KHeight)"
    }
} else {
    Write-Check -Status 'INFO' -Message "$fourKName not present (OK if source JPEG is exact 4K and used directly)"
}

$legacyFit = Join-Path $PublicWallpaperDir 'nextgputobu-desktop-fit.bmp'
if (Test-Path -LiteralPath $legacyFit) {
    Write-Check -Status 'WARN' -Message "Old per-session file still present (safe to delete): $legacyFit"
}

# --- HKCU desktop (what Explorer uses) ---
Write-Section 'HKCU desktop (Explorer)'
$cpWallpaper = Get-RegString -Path 'HKCU:\Control Panel\Desktop' -Name 'Wallpaper'
$cpStyle = Get-RegString -Path 'HKCU:\Control Panel\Desktop' -Name 'WallpaperStyle'
$cpTile = Get-RegString -Path 'HKCU:\Control Panel\Desktop' -Name 'TileWallpaper'

if ($cpWallpaper) {
    Write-Check -Status 'INFO' -Message "Control Panel\Desktop\Wallpaper = $cpWallpaper"
    if (Test-Path -LiteralPath $cpWallpaper) { Write-Check -Status 'OK' -Message 'Wallpaper file exists on disk' }
    else { Write-Check -Status 'FAIL' -Message 'Wallpaper path in registry but file missing' }
} else {
    Write-Check -Status 'FAIL' -Message 'Control Panel\Desktop\Wallpaper not set'
}

$styleNames = @{ '0' = 'Center/Tile'; '2' = 'Stretch'; '6' = 'Fit'; '10' = 'Fill/CROP (bad)'; '22' = 'Span (want 22 if 2+ monitors)' }
$styleHint = if ($styleNames.ContainsKey([string]$cpStyle)) { $styleNames[[string]$cpStyle] } else { 'unknown' }
if ([string]$cpStyle -in @($script:WallpaperDesktopStyleFit, $script:WallpaperDesktopStyleSpan)) {
    Write-Check -Status 'OK' -Message "WallpaperStyle = $cpStyle ($styleHint)"
} elseif ([string]$cpStyle -eq '10') {
    Write-Check -Status 'FAIL' -Message "WallpaperStyle = 10 (Fill) -> desktop will CROP. Re-run Setup-Wallpaper.bat"
} else {
    Write-Check -Status 'WARN' -Message "WallpaperStyle = $cpStyle ($styleHint); expected $($script:WallpaperDesktopStyleFit) for Fit"
}

if ([string]$cpTile -eq $script:TileWallpaperOff) {
    Write-Check -Status 'OK' -Message "TileWallpaper = $cpTile"
} else {
    Write-Check -Status 'WARN' -Message "TileWallpaper = $cpTile (expected $($script:TileWallpaperOff))"
}

# --- HKCU GPO policy key ---
Write-Section 'HKCU GPO policy (Policies\System)'
$polWallpaper = Get-RegString -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'Wallpaper'
$polStyle = Get-RegString -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'WallpaperStyle'
if ($polWallpaper) {
    Write-Check -Status 'INFO' -Message "Policies\System\Wallpaper = $polWallpaper"
} else {
    Write-Check -Status 'WARN' -Message 'Policies\System\Wallpaper not set (gpupdate may not have run)'
}
if ([string]$polStyle -eq $script:WallpaperPolicyStyleFit) {
    Write-Check -Status 'OK' -Message "Policies\System\WallpaperStyle = $polStyle (GPO Fit = 3)"
} else {
    Write-Check -Status 'WARN' -Message "Policies\System\WallpaperStyle = $polStyle (expected $($script:WallpaperPolicyStyleFit) for GPO Fit)"
}

# --- HKLM PersonalizationCSP (like logon screen) ---
Write-Section 'HKLM PersonalizationCSP (logon + desktop policy)'
$csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
foreach ($name in @('LockScreenImagePath', 'DesktopImagePath', 'LockScreenImageStatus', 'DesktopImageStatus')) {
    $v = if ($name -match 'Status') { Get-RegDword -Path $csp -Name $name } else { Get-RegString -Path $csp -Name $name }
    if ($null -ne $v) {
        Write-Check -Status 'OK' -Message "$name = $v"
    } else {
        Write-Check -Status 'WARN' -Message "$name not set"
    }
}

# --- Theme cache (stale = wrong picture) ---
Write-Section 'Theme cache (delete if desktop wrong but registry OK)'
$themeDir = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
foreach ($name in @('TranscodedWallpaper', 'TranscodedWallpaper.jpg', 'CachedFiles')) {
    $p = Join-Path $themeDir $name
    if (Test-Path -LiteralPath $p) {
        Write-Check -Status 'WARN' -Message "Stale cache may override Fit: $p (re-run setup or sign out/in)"
    } else {
        Write-Check -Status 'OK' -Message "No $name"
    }
}

# --- Scheduled tasks ---
Write-Section 'Scheduled tasks'
foreach ($taskName in @('nextGPU-WallpaperFitLogon', 'nextGPU-DesktopCleanupLogon')) {
    $t = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($t) {
        Write-Check -Status 'OK' -Message "$taskName registered (State: $($t.State))"
    } else {
        Write-Check -Status 'WARN' -Message "$taskName not registered"
    }
}

# --- Displays (RDP vs Moonlight / VDD) ---
Write-Section 'Monitors (RDP vs Moonlight)'
$layout = Get-DisplayWallpaperLayout
Write-Check -Status 'INFO' -Message ('Monitor count: {0}' -f $layout.MonitorCount)
if ($layout.UseSpan) {
    Write-Check -Status 'OK' -Message 'Multi-monitor: wallpaper should use Span (desktop 22) so VDD/Moonlight head gets the image'
} else {
    Write-Check -Status 'INFO' -Message 'Single monitor: wallpaper uses Fit (desktop 6)'
}
try {
    foreach ($s in $layout.Screens) {
        $p = if ($s.Primary) { ' PRIMARY' } else { '' }
        Write-Check -Status 'INFO' -Message ('{0}{1} {2}x{3}' -f $s.DeviceName, $p, $s.Bounds.Width, $s.Bounds.Height)
    }
    Write-Check -Status 'INFO' -Message 'Moonlight streams VDD; RDP Fit on RDP-only primary does NOT fix Moonlight — need Span or Sunshine wallpaper refresh'
} catch { }

$spanLog = Join-Path $env:ProgramData 'nextGPU\logs\wallpaper-after-display.log'
if (Test-Path -LiteralPath $spanLog) {
    Write-Check -Status 'INFO' -Message "Sunshine display refresh log: $spanLog"
    Get-Content -LiteralPath $spanLog -Tail 5 | ForEach-Object { Write-Check -Status 'INFO' -Message $_ }
}

# --- Restart checklist ---
Write-Section 'Do you need restart?'
Write-Check -Status 'INFO' -Message 'HKLM PersonalizationCSP (desktop policy) -> often needs ONE full REBOOT after first Setup-Wallpaper.bat'
Write-Check -Status 'INFO' -Message 'HKCU Fit + Explorer -> sign OUT and IN, or run Apply-WallpaperNow.ps1 (restarts Explorer)'
Write-Check -Status 'INFO' -Message 'GPU/VDD display -> logon task runs again at 90s; wait ~2 min after login before judging wallpaper'
Write-Check -Status 'INFO' -Message 'Test as nextGPU (rental user), not only Administrator — each user has separate HKCU'

# --- Summary ---
Write-Section 'Fix order if desktop still crops'
Write-Host @'
  1) powershell -File scripts\desktop\Test-WallpaperPolicy.ps1   (paste output if still broken)
  2) As Admin: scripts\desktop\Setup-Wallpaper.bat
  3) REBOOT the machine once
  4) Sign in as nextGPU (rental user), wait 90 seconds
  5) Still wrong? While logged in as that user: scripts\desktop\Apply-WallpaperNow.ps1
     (or Apply-WallpaperNow.bat — run as Admin once for HKLM CSP)
'@ -ForegroundColor Gray

Write-Host ''
