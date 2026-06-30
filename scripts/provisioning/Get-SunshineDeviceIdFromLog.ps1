#Requires -Version 5.1
<#
.SYNOPSIS
    Parse Sunshine log for the VDD display device_id (friendly_name "VDD by MTT" or edid MTT/1337).

    Scans every common sunshine.log location and uses the file that actually contains VDD JSON.
    Picks the best usable entry (display_name + info) via VddDisplaySelection.ps1; exits 1 when
    only incomplete phantom entries exist so callers can fall back to Get-DisplayDeviceId.ps1.
#>
[CmdletBinding()]
param(
    [string[]]$LogPath,
    [switch]$ListAll,
    [int]$TailBytes = 8MB
)

$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'VddDisplaySelection.ps1')

function Test-VddContextText {
    param([string]$Context)
    return (
        ($Context -match 'VDD by MTT') -or
        ($Context -match '"manufacturer_id"\s*:\s*"MTT"' -and $Context -match '"product_code"\s*:\s*"?1337"?')
    )
}

function Get-DisplayObjectsFromLogText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }

    $objects = [System.Collections.Generic.List[object]]::new()
    # device_id value may be quoted or not in sunshine.log
    $pattern = '(?is)"device_id"\s*:\s*"?(\{[0-9a-fA-F-]{36}\})"?'
    foreach ($m in [regex]::Matches($Text, $pattern)) {
        $deviceId = $m.Groups[1].Value
        $objStart = $Text.LastIndexOf('{', $m.Index)
        if ($objStart -lt 0) { continue }

        $depth = 0
        $objEnd = -1
        for ($i = $objStart; $i -lt $Text.Length; $i++) {
            $ch = $Text[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') {
                $depth--
                if ($depth -eq 0) {
                    $objEnd = $i
                    break
                }
            }
        }

        $ctxStart = [Math]::Max(0, $m.Index - 500)
        $ctxLen = [Math]::Min(2000, $Text.Length - $ctxStart)
        $ctx = $Text.Substring($ctxStart, $ctxLen)

        if ($objEnd -ge 0) {
            $json = $Text.Substring($objStart, $objEnd - $objStart + 1)
            try {
                $obj = $json | ConvertFrom-Json
                $objects.Add([pscustomobject]@{
                    Display  = $obj
                    Index    = $objStart
                    DeviceId = [string]$obj.device_id
                    IsVdd    = (Test-IsVddSunshineDisplay -Display $obj)
                })
                continue
            } catch { }
        }

        if (Test-VddContextText -Context $ctx) {
            $objects.Add([pscustomobject]@{
                Display  = $null
                Index    = $m.Index
                DeviceId = $deviceId
                IsVdd    = $true
            })
        }
    }

    return @($objects)
}

function Get-DefaultLogCandidates {
    $c = [System.Collections.Generic.List[string]]::new()
    $roots = @(
        $env:NEXTGPU_REPO_ROOT,
        (Join-Path $PSScriptRoot '..\..'),
        'C:\Users\Administrator\Downloads',
        'C:\nextcore'
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    foreach ($r in $roots) {
        $c.Add((Join-Path $r 'logs\sunshine.log'))
    }

    $c.Add('C:\Program Files\Sunshine\sunshine.log')
    $c.Add('C:\Program Files\Sunshine\config\sunshine.log')
    $c.Add("$env:ProgramData\Sunshine\sunshine.log")
    if ($env:LOCALAPPDATA) {
        $c.Add((Join-Path $env:LOCALAPPDATA 'Sunshine\sunshine.log'))
        $c.Add((Join-Path $env:LOCALAPPDATA 'sunshine\sunshine.log'))
    }
    if ($env:TEMP) { $c.Add((Join-Path $env:TEMP 'sunshine.log')) }

    return @($c | Select-Object -Unique)
}

function Read-LogTailText {
    param([string]$Path, [int]$MaxBytes)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $len = $fs.Length
            if ($len -eq 0) { return '' }
            $read = [Math]::Min($len, $MaxBytes)
            $fs.Seek($len - $read, [System.IO.SeekOrigin]::Begin) | Out-Null
            $buf = New-Object byte[] $read
            [void]$fs.Read($buf, 0, $read)
            return [System.Text.Encoding]::UTF8.GetString($buf)
        } finally {
            $fs.Dispose()
        }
    } catch {
        return $null
    }
}

function Get-VddEntriesFromLogFile {
    param([string]$Path)
    $text = Read-LogTailText -Path $Path -MaxBytes $TailBytes
    if ($null -eq $text) { return @(), $false }
    $all = Get-DisplayObjectsFromLogText -Text $text
    $vdd = @($all | Where-Object { $_.IsVdd } | Sort-Object Index)
    return $vdd, ($vdd.Count -gt 0)
}

if (-not $LogPath -or $LogPath.Count -eq 0) {
    $LogPath = Get-DefaultLogCandidates
}

$bestEntries = @()
$usedLog = $null
foreach ($p in $LogPath) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $entries, $hasVdd = Get-VddEntriesFromLogFile -Path $p
    if ($hasVdd) {
        $bestEntries = $entries
        $usedLog = $p
        # Keep scanning; later files in list may be newer — prefer last file that has VDD
    }
}

if ($bestEntries.Count -eq 0) {
    [Console]::Error.WriteLine('No VDD (VDD by MTT / edid MTT+1337) device_id in any sunshine.log.')
    foreach ($p in $LogPath) {
        $exists = Test-Path -LiteralPath $p
        $size = if ($exists) { (Get-Item -LiteralPath $p).Length } else { 0 }
        [Console]::Error.WriteLine("  $p  exists=$exists  size=$size")
    }
    exit 1
}

$pick = Select-BestVddSunshineLogEntry -Entries $bestEntries

if ($ListAll) {
    foreach ($e in $bestEntries) {
        $summary = Get-VddSunshineLogEntrySummary -Display $e.Display
        $fn = if ($e.Display) { [string]$e.Display.friendly_name } else { 'VDD (context)' }
        $selected = ($pick -and $pick.DeviceId -eq $e.DeviceId)
        $tag = if ($selected) { ' SELECTED' } else { '' }
        Write-Host ("log VDD: {0}  usable={1}  score={2}  display_name={3}  primary={4}  friendly_name={5}{6}" -f `
            $e.DeviceId, $summary.Usable, $summary.Score, $summary.DisplayName, $summary.Primary, $fn, $tag)
    }
    if ($usedLog) { Write-Host "source: $usedLog" }
    if (-not $pick) {
        Write-Host "selected: (none usable - $($bestEntries.Count) incomplete candidate(s))"
    }
    exit 0
}

if (-not $pick) {
    [Console]::Error.WriteLine("No usable VDD device_id in sunshine.log ($($bestEntries.Count) incomplete candidate(s)).")
    exit 1
}

[Console]::Out.WriteLine($pick.DeviceId)
exit 0
