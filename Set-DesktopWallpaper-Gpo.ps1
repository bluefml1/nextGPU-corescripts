#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Copies nextGPU wallpaper and enables User Configuration "Desktop Wallpaper" (Fill)
    via local User registry.pol so gpedit shows Enabled under User Configuration.
#>
[CmdletBinding()]
param(
    [string]$ScriptDir = $PSScriptRoot,
    [string]$WallpaperFileName = 'nextgputobu.jpeg',
    [string]$WallpaperStyle = '10',
    [string]$TileWallpaper = '0',
    [switch]$SkipDefaultUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Set-WallpaperPolicyRegistry {
    param(
        [string]$HiveRoot,
        [string]$WallpaperPath,
        [string]$Style,
        [string]$Tile
    )
    $regPath = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path -LiteralPath $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $regPath -Name 'Wallpaper' -Value $WallpaperPath -Type String
    Set-ItemProperty -LiteralPath $regPath -Name 'WallpaperStyle' -Value $Style -Type String
    Set-ItemProperty -LiteralPath $regPath -Name 'TileWallpaper' -Value $Tile -Type String
}
#endregion

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
}

function Invoke-RegExe {
    param([Parameter(Mandatory)][string[]]$ArgumentList)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & reg.exe @ArgumentList 2>&1
        $text = if ($null -eq $output) { '' } else { ($output | Out-String).Trim() }
        return @{ ExitCode = $LASTEXITCODE; Output = $text }
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
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

$policyValues = @(
    [GPRegistryPolicyEntry]::new($PolicyKey, 'Wallpaper', [RegType]::REG_SZ, $WallpaperDest)
    [GPRegistryPolicyEntry]::new($PolicyKey, 'WallpaperStyle', [RegType]::REG_SZ, $WallpaperStyle)
    [GPRegistryPolicyEntry]::new($PolicyKey, 'TileWallpaper', [RegType]::REG_SZ, $TileWallpaper)
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

Write-Log "Applying HKCU policy for current user ($env:USERNAME)..."
Set-WallpaperPolicyRegistry -HiveRoot 'HKCU:' -WallpaperPath $WallpaperDest -Style $WallpaperStyle -Tile $TileWallpaper

if (-not $SkipDefaultUser) {
    $defaultNtuser = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    $tempHive = 'HKU\NextGPUWallpaperDefault'
    if (Test-Path -LiteralPath $defaultNtuser) {
        Write-Log "Applying policy to Default user profile (new accounts)..."
        $loaded = $false
        try {
            $loadResult = Invoke-RegExe -ArgumentList @('load', $tempHive, $defaultNtuser)
            if ($loadResult.ExitCode -eq 0) {
                $loaded = $true
                Set-WallpaperPolicyRegistry -HiveRoot 'Registry::HKEY_USERS\NextGPUWallpaperDefault' `
                    -WallpaperPath $WallpaperDest -Style $WallpaperStyle -Tile $TileWallpaper
                Write-Log 'Default profile policy keys written.'
            }
            else {
                if ($loadResult.Output) { Write-Warning $loadResult.Output }
                Write-Warning "Could not load Default NTUSER.DAT (exit $($loadResult.ExitCode)). User GPO still applies at logon."
            }
        }
        finally {
            if ($loaded) {
                $unloadResult = Invoke-RegExe -ArgumentList @('unload', $tempHive)
                if ($unloadResult.ExitCode -ne 0 -and $unloadResult.Output) {
                    Write-Warning "reg unload Default hive: $($unloadResult.Output)"
                }
            }
        }
    }
}

Write-Log "Refreshing desktop (restart Explorer)..."
$explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue
if ($explorer) {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
Start-Process -FilePath 'explorer.exe' | Out-Null
Start-Sleep -Seconds 1
Start-Process -FilePath 'RUNDLL32.EXE' -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -Wait -NoNewWindow | Out-Null

Write-Log "Done."
Write-Log "gpedit: User Configuration -> Administrative Templates -> Desktop -> Desktop -> Desktop Wallpaper"
Write-Log "  (Computer Configuration for this policy always shows Not Configured - that is normal.)"
Write-Log ('Enabled, Fill style ' + $WallpaperStyle + ', path ' + $WallpaperDest)

exit 0
