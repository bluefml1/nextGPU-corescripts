#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Copies nextGPU wallpaper, enables User Configuration "Desktop Wallpaper" (Fit),
    and applies the same image to the Windows lock/sign-in screen.
    Desktop: fixed 3840x2160 master (nextgputobu-4k.bmp or 4K JPEG) + Fit on any monitor.
    Lock/sign-in: original nextgputobu.jpeg.
#>
[CmdletBinding()]
param(
    [string]$ScriptDir = '',
    [string]$WallpaperFileName = 'nextgputobu.jpeg',
    [switch]$SkipDefaultUser,
    [switch]$SkipWallpaperFitLogonTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $localScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ScriptDir = if ($env:NEXTGPU_REPO_ROOT) {
        $env:NEXTGPU_REPO_ROOT
    } else {
        (Resolve-Path (Join-Path $localScriptDir '..\..')).Path
    }
}

. (Join-Path $PSScriptRoot 'DefaultUserHive.ps1')
. (Join-Path $PSScriptRoot 'WallpaperFitCommon.ps1')

#region registry.pol helpers (MS-GPREG / GPRegistryPolicy format)
enum RegType {
    REG_NONE = 0
    REG_SZ = 1
    REG_EXPAND_SZ = 2
    REG_BINARY = 3
    REG_DWORD = 4
    REG_MULTI_SZ = 7
    REG_QWORD = 11
}

class GPRegistryPolicyEntry {
    [string]$KeyName
    [string]$ValueName
    [RegType]$ValueType
    [object]$ValueData

    GPRegistryPolicyEntry([string]$KeyName, [string]$ValueName, [RegType]$ValueType, [object]$ValueData) {
        $this.KeyName = $KeyName
        $this.ValueName = $ValueName
        $this.ValueType = $ValueType
        $this.ValueData = $ValueData
    }
}

function New-RegistryPolEntryBytes {
    param([GPRegistryPolicyEntry]$Entry)
    $bytes = New-Object System.Collections.Generic.List[byte]
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes('['))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes($Entry.KeyName + [char]0))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes($Entry.ValueName + [char]0))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    [void]$bytes.AddRange([System.BitConverter]::GetBytes([int32]$Entry.ValueType))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))

    switch ($Entry.ValueType) {
        { @([RegType]::REG_SZ, [RegType]::REG_EXPAND_SZ, [RegType]::REG_MULTI_SZ) -contains $_ } {
            $dataBytes = [System.Text.Encoding]::Unicode.GetBytes([string]$Entry.ValueData + [char]0)
            $dataSize = $dataBytes.Length
        }
        ([RegType]::REG_DWORD) {
            $dataBytes = [System.BitConverter]::GetBytes([int32]$Entry.ValueData)
            $dataSize = 4
        }
        default {
            $dataBytes = [byte[]]@()
            $dataSize = 0
        }
    }

    [void]$bytes.AddRange([System.BitConverter]::GetBytes($dataSize))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    if ($dataSize -gt 0) { [void]$bytes.AddRange($dataBytes) }
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(']'))
    return $bytes.ToArray()
}

function Read-RegistryPolFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $raw = [System.IO.File]::ReadAllBytes($Path)
    if ($raw.Length -lt 8) { return @() }

    $sig = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
    if ($sig -ne 'PReg') { throw "Invalid registry.pol header in $Path" }

    $entries = New-Object System.Collections.Generic.List[object]
    $index = 8
    while ($index -lt $raw.Length - 2) {
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne '[') { break }
        $index += 2

        $semi = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ';') { $semi = $i; break }
        }
        if ($semi -lt 0) { break }
        $keyName = [System.Text.Encoding]::Unicode.GetString($raw, $index, $semi - $index)
        $index = $semi + 2

        $semi = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ';') { $semi = $i; break }
        }
        if ($semi -lt 0) { break }
        $valueName = [System.Text.Encoding]::Unicode.GetString($raw, $index, $semi - $index)
        $index = $semi + 2

        $valueType = [System.BitConverter]::ToInt32($raw, $index)
        $index += 4
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne ';') { break }
        $index += 2

        $valueLength = [System.BitConverter]::ToInt32($raw, $index)
        $index += 4
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne ';') { break }
        $index += 2

        $valueData = $null
        if ($valueLength -gt 0 -and $valueType -eq [RegType]::REG_SZ) {
            $valueData = [System.Text.Encoding]::Unicode.GetString($raw, $index, $valueLength - 2)
            $index += $valueLength
        }
        elseif ($valueType -eq [RegType]::REG_DWORD) {
            $valueData = [System.BitConverter]::ToInt32($raw, $index)
            $index += 4
        }

        $close = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ']') { $close = $i; break }
        }
        if ($close -lt 0) { break }
        $index = $close + 2

        if ($valueName) {
            $entries.Add([GPRegistryPolicyEntry]::new($keyName, $valueName, [RegType]$valueType, $valueData))
        }
    }
    return $entries.ToArray()
}

function Write-RegistryPolFile {
    param(
        [string]$Path,
        [GPRegistryPolicyEntry[]]$Entries
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]0x67655250)
    $bw.Write([uint32]1)
    foreach ($entry in $Entries) {
        $bw.Write((New-RegistryPolEntryBytes -Entry $entry))
    }
    $bw.Close()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
}

#endregion

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
}

function Update-UserRegistryPol {
    param(
        [string]$PolPath,
        [string]$PolicyKey,
        [GPRegistryPolicyEntry[]]$PolicyValues
    )
    $replaceNames = @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')
    $existing = @(Read-RegistryPolFile -Path $PolPath)
    $kept = @($existing | Where-Object {
        -not ($_.KeyName -eq $PolicyKey -and $replaceNames -contains $_.ValueName)
    })
    $merged = @($kept) + @($PolicyValues)
    Write-RegistryPolFile -Path $PolPath -Entries $merged
}

# Desktop Wallpaper ADMX is User Configuration -> HKCU (not HKLM / Machine pol)
$PolicyKey = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
$UserPolPath = Join-Path $env:SystemRoot 'System32\GroupPolicy\User\registry.pol'
$WallpaperDir = 'C:\Users\Public\Wallpaper'
$WallpaperDest = Join-Path $WallpaperDir $WallpaperFileName
$WallpaperSrc = Join-Path $ScriptDir $WallpaperFileName
if (-not (Test-Path -LiteralPath $WallpaperSrc)) {
    $assetWallpaperSrc = Join-Path (Join-Path $ScriptDir 'assets') $WallpaperFileName
    if (Test-Path -LiteralPath $assetWallpaperSrc) {
        $WallpaperSrc = $assetWallpaperSrc
    }
}

Write-Log "Wallpaper source: $WallpaperSrc"
Write-Log "Wallpaper destination: $WallpaperDest"
Write-Log "Policy scope: User Configuration (HKCU)"
Write-Log "Policy key: $PolicyKey"
Write-Log "registry.pol: $UserPolPath"

if (-not (Test-Path -LiteralPath $WallpaperSrc)) {
    Write-Error "Wallpaper source not found: $WallpaperSrc"
}

if (-not (Test-Path -LiteralPath $WallpaperDir)) {
    New-Item -ItemType Directory -Path $WallpaperDir -Force | Out-Null
}

Copy-Item -LiteralPath $WallpaperSrc -Destination $WallpaperDest -Force
Write-Log "Copied wallpaper to $WallpaperDest"

$desktopWallpaperPath = Ensure-4KDesktopWallpaper -SourceImagePath $WallpaperDest -ForceRebuild
$srcDims = Get-ImagePixelSize -ImagePath $WallpaperDest
$srcDimText = if ($srcDims) { '{0}x{1}' -f $srcDims.Width, $srcDims.Height } else { 'unknown' }
Write-Log ('Source image size: ' + $srcDimText)
Write-Log ('Desktop master (4K UHD {0}x{1} Fit): {2}' -f $script:WallpaperNative4KWidth, $script:WallpaperNative4KHeight, $desktopWallpaperPath)

Set-PersonalizationCspWallpaper -LockScreenImagePath $WallpaperDest -DesktopImagePath $desktopWallpaperPath
Write-Log "PersonalizationCSP lock: $WallpaperDest | desktop: $desktopWallpaperPath"

$policyValues = @(
    [GPRegistryPolicyEntry]::new($PolicyKey, 'Wallpaper', [RegType]::REG_SZ, $desktopWallpaperPath)
    [GPRegistryPolicyEntry]::new($PolicyKey, 'WallpaperStyle', [RegType]::REG_SZ, $script:WallpaperPolicyStyleFit)
    [GPRegistryPolicyEntry]::new($PolicyKey, 'TileWallpaper', [RegType]::REG_SZ, $script:TileWallpaperOff)
)

Update-UserRegistryPol -PolPath $UserPolPath -PolicyKey $PolicyKey -PolicyValues $policyValues
Write-Log "Updated User registry.pol ($($policyValues.Count) wallpaper entries)"

# Remove mistaken Machine-scope entries from older script versions (this ADMX policy is User-only)
$machinePolPath = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\registry.pol'
if (Test-Path -LiteralPath $machinePolPath) {
    $machineExisting = @(Read-RegistryPolFile -Path $machinePolPath)
    $machineWallpaperNames = @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')
    $machineRemoved = @($machineExisting | Where-Object {
        $_.KeyName -eq $PolicyKey -and $machineWallpaperNames -contains $_.ValueName
    })
    if (@($machineRemoved).Length -gt 0) {
        $machineKept = @($machineExisting | Where-Object {
            -not ($_.KeyName -eq $PolicyKey -and $machineWallpaperNames -contains $_.ValueName)
        })
        Write-RegistryPolFile -Path $machinePolPath -Entries @($machineKept)
        Write-Log "Removed wallpaper entries from Machine registry.pol (wrong scope)."
    }
}
$hklmPolicy = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
foreach ($name in @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')) {
    if (Get-ItemProperty -LiteralPath $hklmPolicy -Name $name -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -LiteralPath $hklmPolicy -Name $name -ErrorAction SilentlyContinue
        Write-Log "Removed HKLM policy value: $name"
    }
}

Write-Log "Running gpupdate /force /target:user ..."
$gpOut = & gpupdate.exe /force /target:user 2>&1 | Out-String
if ($gpOut.Trim()) { Write-Log $gpOut.Trim() }
if ($LASTEXITCODE -ne 0) {
    Write-Warning "gpupdate /target:user returned exit code $LASTEXITCODE"
}

$publicRemoved = Clear-PublicDesktopItems
if ($publicRemoved -gt 0) {
    Write-Log "Removed $publicRemoved item(s) from Public Desktop (shortcuts visible to all users)."
}

Write-Log "Applying HKCU 4K desktop wallpaper (Fit) for $($env:USERNAME)..."
[void](Invoke-WallpaperFitForCurrentUser -WallpaperPath $WallpaperDest -HideDesktopIcons -RefreshExplorer)

if (-not $SkipDefaultUser) {
    Write-Log 'Applying policy to Default user profile (new accounts)...'
    $defaultResult = Invoke-DefaultUserNtuserScript -HiveName 'HKU\NextGPUWallpaperDefault' -ApplyKeys {
        param($HiveName)
        Set-WallpaperFitRegistryViaReg -HiveName $HiveName -WallpaperPath $desktopWallpaperPath -RentalDesktopExtras
        Write-Log 'Default profile 4K desktop Fit + hide icons written.'
    }
    if (-not $defaultResult.Loaded -and $defaultResult.Message) {
        Write-Warning "Default user wallpaper keys skipped: $($defaultResult.Message) User GPO still applies."
    }
}

Write-Log "Done."
Write-Log "gpedit: User Configuration -> Administrative Templates -> Desktop -> Desktop -> Desktop Wallpaper"
Write-Log "  (Computer Configuration for this policy always shows Not Configured - that is normal.)"
Write-Log ('GPO/HKCU desktop (4K master, Fit): ' + $desktopWallpaperPath)
Write-Log ('PersonalizationCSP lock: ' + $WallpaperDest)
Write-Log 'Desktop icons hidden (HideIcons=1). Personalization background change blocked.'
Write-Log 'Logon task re-applies 4K master + Fit (nextGPU-WallpaperFitLogon, +90s delay).'
Write-Log 'IMPORTANT: Reboot once after first setup, then sign in as nextGPU. Or run Apply-WallpaperNow.ps1 while logged in.'

if (-not $SkipWallpaperFitLogonTask) {
    $registerLogon = Join-Path $PSScriptRoot 'Register-WallpaperFitLogonTask.ps1'
    if (Test-Path -LiteralPath $registerLogon) {
        Write-Log 'Registering nextGPU-WallpaperFitLogon (re-apply Fit on each logon)...'
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $registerLogon
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Register-WallpaperFitLogonTask.ps1 exit code $LASTEXITCODE"
        }
    } else {
        Write-Warning "Register-WallpaperFitLogonTask.ps1 not found; logon Fit refresh not registered."
    }
}

exit 0
