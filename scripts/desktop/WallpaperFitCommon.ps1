# Shared wallpaper helpers (dot-source; do not run directly).
# Master desktop image is always 3840x2160 (4K UHD): full artwork visible, Fit on any monitor size.
$script:WallpaperPolicyStyleFit = '3'       # Policies\System (GPO Fit)
$script:WallpaperDesktopStyleFit = '6'      # Control Panel\Desktop (Explorer Fit)
$script:WallpaperPolicyStyleSpan = '5'      # Policies\System (GPO Span, multi-monitor)
$script:WallpaperDesktopStyleSpan = '22'    # Control Panel\Desktop (Span all heads — Moonlight/VDD)
$script:TileWallpaperOff = '0'
$script:WallpaperNative4KWidth = 3840
$script:WallpaperNative4KHeight = 2160
$script:WallpaperSourceFileName = 'nextgputobu.jpeg'
$script:Desktop4KFileName = 'nextgputobu-4k.bmp'

function Get-4KDesktopWallpaperPath {
    param([string]$SourceImagePath)
    if ([string]::IsNullOrWhiteSpace($SourceImagePath)) { return $null }
    return (Join-Path (Split-Path -Parent $SourceImagePath) $script:Desktop4KFileName)
}

function Get-WallpaperSourceImagePath {
    param([string]$ConfiguredOrSourcePath)
    if ([string]::IsNullOrWhiteSpace($ConfiguredOrSourcePath)) { return $null }
    if ($ConfiguredOrSourcePath -match 'nextgputobu-(4k|desktop-fit)\.(bmp|jpg|jpeg|png)$') {
        $dir = Split-Path -Parent $ConfiguredOrSourcePath
        $candidate = Join-Path $dir $script:WallpaperSourceFileName
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    if (Test-Path -LiteralPath $ConfiguredOrSourcePath) { return $ConfiguredOrSourcePath }
    return $null
}

function Get-ImagePixelSize {
    param([Parameter(Mandatory)][string]$ImagePath)
    $img = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $img = [System.Drawing.Image]::FromFile($ImagePath)
        return [PSCustomObject]@{ Width = $img.Width; Height = $img.Height }
    } catch {
        return $null
    } finally {
        if ($img) { $img.Dispose() }
    }
}

function New-4KWallpaperBitmap {
    param(
        [Parameter(Mandatory)][string]$SourceImagePath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    if (-not (Test-Path -LiteralPath $SourceImagePath)) { return $null }

    $width = $script:WallpaperNative4KWidth
    $height = $script:WallpaperNative4KHeight
    $dir = Split-Path -Parent $OutputPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $srcImage = $null
    $bitmap = $null
    $graphics = $null
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $srcImage = [System.Drawing.Image]::FromFile($SourceImagePath)
        $bitmap = New-Object System.Drawing.Bitmap $width, $height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.Clear([System.Drawing.Color]::Black)
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality

        $scale = [Math]::Min($width / $srcImage.Width, $height / $srcImage.Height)
        $drawW = [int][Math]::Round($srcImage.Width * $scale)
        $drawH = [int][Math]::Round($srcImage.Height * $scale)
        $drawX = [int](($width - $drawW) / 2)
        $drawY = [int](($height - $drawH) / 2)
        $graphics.DrawImage($srcImage, $drawX, $drawY, $drawW, $drawH)

        $bitmap.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Bmp)
        return $OutputPath
    } catch {
        return $null
    } finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
        if ($srcImage) { $srcImage.Dispose() }
    }
}

function Ensure-4KDesktopWallpaper {
    param(
        [Parameter(Mandatory)][string]$SourceImagePath,
        [switch]$ForceRebuild
    )
    $fourKPath = Get-4KDesktopWallpaperPath -SourceImagePath $SourceImagePath
    if (-not $fourKPath) { return $SourceImagePath }

    $dims = Get-ImagePixelSize -ImagePath $SourceImagePath
    $sourceIsExact4K = $dims -and $dims.Width -eq $script:WallpaperNative4KWidth -and $dims.Height -eq $script:WallpaperNative4KHeight
    if ($sourceIsExact4K -and $SourceImagePath -match '\.(jpe?g|png)$') {
        return $SourceImagePath
    }

    $rebuild = $ForceRebuild.IsPresent
    if (-not $rebuild -and (Test-Path -LiteralPath $fourKPath)) {
        $srcTime = (Get-Item -LiteralPath $SourceImagePath).LastWriteTimeUtc
        $outTime = (Get-Item -LiteralPath $fourKPath).LastWriteTimeUtc
        if ($outTime -ge $srcTime) { return $fourKPath }
        $rebuild = $true
    }

    $built = New-4KWallpaperBitmap -SourceImagePath $SourceImagePath -OutputPath $fourKPath
    if ($built) { return $built }
    return $SourceImagePath
}

function Set-PersonalizationCspWallpaper {
    param(
        [Parameter(Mandatory)][string]$LockScreenImagePath,
        [string]$DesktopImagePath = ''
    )
    if ([string]::IsNullOrWhiteSpace($DesktopImagePath)) {
        $DesktopImagePath = $LockScreenImagePath
    }

    $personalizationPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization'
    if (-not (Test-Path -LiteralPath $personalizationPolicy)) {
        New-Item -Path $personalizationPolicy -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $personalizationPolicy -Name 'LockScreenImage' -Value $LockScreenImagePath -Type String -Force

    $personalizationCsp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    if (-not (Test-Path -LiteralPath $personalizationCsp)) {
        New-Item -Path $personalizationCsp -Force | Out-Null
    }

    foreach ($pair in @(
            @{ Prefix = 'LockScreen'; Path = $LockScreenImagePath }
            @{ Prefix = 'Desktop'; Path = $DesktopImagePath }
        )) {
        $prefix = $pair.Prefix
        $imagePath = $pair.Path
        Set-ItemProperty -LiteralPath $personalizationCsp -Name "${prefix}ImagePath" -Value $imagePath -Type String -Force
        Set-ItemProperty -LiteralPath $personalizationCsp -Name "${prefix}ImageUrl" -Value $imagePath -Type String -Force
        Set-ItemProperty -LiteralPath $personalizationCsp -Name "${prefix}ImageStatus" -Value 1 -Type DWord -Force
    }

    $systemPolicy = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
    if (-not (Test-Path -LiteralPath $systemPolicy)) {
        New-Item -Path $systemPolicy -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $systemPolicy -Name 'DisableLogonBackgroundImage' -Value 0 -Type DWord -Force
}

function Clear-Win11DesktopWallpaperOverrides {
    $paths = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers\BackgroundType'
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $personalize = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path -LiteralPath $personalize)) {
        New-Item -Path $personalize -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $personalize -Name 'BackgroundType' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -LiteralPath $personalize -Name 'EnableTransparency' -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
}

function Invoke-SystemParametersWallpaper {
    param([Parameter(Mandatory)][string]$WallpaperPath)
    if (-not (Test-Path -LiteralPath $WallpaperPath)) { return }
    try {
        if (-not ('NativeWallpaper' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class NativeWallpaper {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
'@ -ErrorAction Stop
        }
        $spiSetDesktopWallpaper = 0x0014
        $spiFUpdateIniFile = 0x01
        $spiFSendChange = 0x02
        [void][NativeWallpaper]::SystemParametersInfo($spiSetDesktopWallpaper, 0, $WallpaperPath, ($spiFUpdateIniFile -bor $spiFSendChange))
    } catch { }
}

function Set-WallpaperFitRegistry {
    param(
        [Parameter(Mandatory)][string]$HiveRoot,
        [Parameter(Mandatory)][string]$WallpaperPath,
        [string]$PolicyStyle = $script:WallpaperPolicyStyleFit,
        [string]$DesktopStyle = $script:WallpaperDesktopStyleFit,
        [string]$Tile = $script:TileWallpaperOff
    )
    $policyPath = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path -LiteralPath $policyPath)) {
        New-Item -Path $policyPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $policyPath -Name 'Wallpaper' -Value $WallpaperPath -Type String -Force
    Set-ItemProperty -LiteralPath $policyPath -Name 'WallpaperStyle' -Value $PolicyStyle -Type String -Force
    Set-ItemProperty -LiteralPath $policyPath -Name 'TileWallpaper' -Value $Tile -Type String -Force

    $desktopReg = Join-Path $HiveRoot 'Control Panel\Desktop'
    if (-not (Test-Path -LiteralPath $desktopReg)) {
        New-Item -Path $desktopReg -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $desktopReg -Name 'Wallpaper' -Value $WallpaperPath -Type String -Force
    Set-ItemProperty -LiteralPath $desktopReg -Name 'WallpaperStyle' -Value $DesktopStyle -Type String -Force
    Set-ItemProperty -LiteralPath $desktopReg -Name 'TileWallpaper' -Value $Tile -Type String -Force
}

function Set-WallpaperFitRegistryViaReg {
    param(
        [Parameter(Mandatory)][string]$HiveName,
        [Parameter(Mandatory)][string]$WallpaperPath,
        [string]$PolicyStyle = $script:WallpaperPolicyStyleFit,
        [string]$DesktopStyle = $script:WallpaperDesktopStyleFit,
        [string]$Tile = $script:TileWallpaperOff,
        [switch]$RentalDesktopExtras
    )
    $entries = @(
        @{ Path = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'Wallpaper'; Type = 'REG_SZ'; Data = $WallpaperPath }
        @{ Path = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'WallpaperStyle'; Type = 'REG_SZ'; Data = $PolicyStyle }
        @{ Path = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Policies\System"; Name = 'TileWallpaper'; Type = 'REG_SZ'; Data = $Tile }
        @{ Path = "$HiveName\Control Panel\Desktop"; Name = 'Wallpaper'; Type = 'REG_SZ'; Data = $WallpaperPath }
        @{ Path = "$HiveName\Control Panel\Desktop"; Name = 'WallpaperStyle'; Type = 'REG_SZ'; Data = $DesktopStyle }
        @{ Path = "$HiveName\Control Panel\Desktop"; Name = 'TileWallpaper'; Type = 'REG_SZ'; Data = $Tile }
    )
    if ($RentalDesktopExtras) {
        $entries += @(
            @{ Path = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop"; Name = 'NoChangingWallpaper'; Type = 'REG_DWORD'; Data = '1' }
            @{ Path = "$HiveName\Software\Policies\Microsoft\Windows\Personalization"; Name = 'NoChangingWallPaper'; Type = 'REG_DWORD'; Data = '1' }
            @{ Path = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = 'HideIcons'; Type = 'REG_DWORD'; Data = '1' }
        )
    }
    foreach ($entry in $entries) {
        $add = Invoke-RegExe -RegArguments @(
            'add', $entry.Path, '/v', $entry.Name, '/t', $entry.Type, '/d', $entry.Data, '/f'
        )
        if ($add.ExitCode -ne 0) {
            throw "reg add failed for $($entry.Path)\$($entry.Name): $($add.Output)"
        }
    }
}

function Set-PreventDesktopBackgroundChange {
    param([Parameter(Mandatory)][string]$HiveRoot)
    $activeDesktop = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop'
    if (-not (Test-Path -LiteralPath $activeDesktop)) {
        New-Item -Path $activeDesktop -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $activeDesktop -Name 'NoChangingWallpaper' -Value 1 -Type DWord -Force

    $personalization = Join-Path $HiveRoot 'Software\Policies\Microsoft\Windows\Personalization'
    if (-not (Test-Path -LiteralPath $personalization)) {
        New-Item -Path $personalization -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $personalization -Name 'NoChangingWallPaper' -Value 1 -Type DWord -Force
}

function Set-DesktopIconsHidden {
    param([Parameter(Mandatory)][string]$HiveRoot)
    $advanced = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    if (-not (Test-Path -LiteralPath $advanced)) {
        New-Item -Path $advanced -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $advanced -Name 'HideIcons' -Value 1 -Type DWord -Force
}

function Clear-WallpaperThemeCache {
    $themeDir = Join-Path $env:APPDATA 'Microsoft\Windows\Themes'
    foreach ($name in @('TranscodedWallpaper', 'TranscodedWallpaper.jpg', 'CachedFiles')) {
        $path = Join-Path $themeDir $name
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WallpaperDesktopRefresh {
    Start-Process -FilePath 'RUNDLL32.EXE' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
    Start-Process -FilePath 'RUNDLL32.EXE' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters', '1', 'True' -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null
}

function Clear-PublicDesktopItems {
    $publicDesktop = Join-Path $env:PUBLIC 'Desktop'
    if (-not (Test-Path -LiteralPath $publicDesktop)) { return 0 }
    $items = @(Get-ChildItem -LiteralPath $publicDesktop -Force -ErrorAction SilentlyContinue)
    $removed = 0
    foreach ($item in $items) {
        try {
            Remove-Item -LiteralPath $item.FullName -Force -Recurse -ErrorAction Stop
            $removed++
        } catch { }
    }
    return $removed
}

function Clear-CurrentUserDesktopItems {
    $desktop = [System.Environment]::GetFolderPath('Desktop')
    if (-not (Test-Path -LiteralPath $desktop)) { return 0 }
    $items = @(Get-ChildItem -LiteralPath $desktop -Force -ErrorAction SilentlyContinue)
    $removed = 0
    foreach ($item in $items) {
        try {
            Remove-Item -LiteralPath $item.FullName -Force -Recurse -ErrorAction Stop
            $removed++
        } catch { }
    }
    return $removed
}

function Get-DisplayWallpaperLayout {
    $monitorCount = 1
    $screens = @()
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screens = @([System.Windows.Forms.Screen]::AllScreens)
        $monitorCount = $screens.Count
    } catch { }

    # RDP + VDD = 2+ monitors: wallpaper on primary only breaks Moonlight (captures other head).
    $useSpan = $monitorCount -gt 1
    return [PSCustomObject]@{
        MonitorCount = $monitorCount
        UseSpan      = $useSpan
        PolicyStyle  = if ($useSpan) { $script:WallpaperPolicyStyleSpan } else { $script:WallpaperPolicyStyleFit }
        DesktopStyle = if ($useSpan) { $script:WallpaperDesktopStyleSpan } else { $script:WallpaperDesktopStyleFit }
        Screens      = $screens
    }
}

function Get-ConfiguredWallpaperPath {
    param([string]$Fallback = 'C:\Users\Public\Wallpaper\nextgputobu.jpeg')
    foreach ($regPath in @(
            'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System',
            'HKCU:\Control Panel\Desktop'
        )) {
        if (-not (Test-Path -LiteralPath $regPath)) { continue }
        $value = (Get-ItemProperty -LiteralPath $regPath -Name 'Wallpaper' -ErrorAction SilentlyContinue).Wallpaper
        if (-not [string]::IsNullOrWhiteSpace($value) -and (Test-Path -LiteralPath $value)) {
            return $value
        }
    }
    $fourK = Get-4KDesktopWallpaperPath -SourceImagePath $Fallback
    if ($fourK -and (Test-Path -LiteralPath $fourK)) { return $fourK }
    if (Test-Path -LiteralPath $Fallback) { return $Fallback }
    return $null
}

function Invoke-WallpaperFitForCurrentUser {
    param(
        [string]$WallpaperPath,
        [switch]$HideDesktopIcons,
        [switch]$ClearDesktopFiles,
        [switch]$RefreshExplorer
    )
    if ([string]::IsNullOrWhiteSpace($WallpaperPath)) {
        $WallpaperPath = Get-ConfiguredWallpaperPath
    }
    $sourcePath = Get-WallpaperSourceImagePath -ConfiguredOrSourcePath $WallpaperPath
    if (-not $sourcePath) { return $false }

    $masterPath = Ensure-4KDesktopWallpaper -SourceImagePath $sourcePath
    $layout = Get-DisplayWallpaperLayout
    Set-PersonalizationCspWallpaper -LockScreenImagePath $sourcePath -DesktopImagePath $masterPath

    Clear-Win11DesktopWallpaperOverrides
    Set-WallpaperFitRegistry -HiveRoot 'HKCU:' -WallpaperPath $masterPath `
        -PolicyStyle $layout.PolicyStyle -DesktopStyle $layout.DesktopStyle
    Set-PreventDesktopBackgroundChange -HiveRoot 'HKCU:'
    if ($HideDesktopIcons) {
        Set-DesktopIconsHidden -HiveRoot 'HKCU:'
    }
    if ($ClearDesktopFiles) {
        [void](Clear-CurrentUserDesktopItems)
    }
    Clear-WallpaperThemeCache
    Invoke-SystemParametersWallpaper -WallpaperPath $masterPath
    Invoke-WallpaperDesktopRefresh
    if ($RefreshExplorer) {
        $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue
        if ($explorer) {
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-Process -FilePath 'explorer.exe' | Out-Null
            Start-Sleep -Seconds 1
            Invoke-SystemParametersWallpaper -WallpaperPath $masterPath
            Invoke-WallpaperDesktopRefresh
        }
    }
    return $true
}
