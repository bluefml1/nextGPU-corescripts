#Requires -Version 5.1
<#
.SYNOPSIS
    Add or merge entries into desktop-apps.allowlist.json with type-aware nameId resolution.
#>
[CmdletBinding()]
param(
    [string]$Exe = "",
    [string]$NameIdInput = "",
    [string]$Title = "",
    [ValidateSet('Adobe', 'Autodesk', 'ThirdParty', 'Games', '')]
    [string]$Type = "",
    [string]$ImportPath = "",
    [ValidateSet('Skip', 'Replace')]
    [string]$OnDuplicateNameId = 'Skip',
    [ValidateSet('Allow', 'Skip', 'Replace')]
    [string]$OnDuplicateExe = 'Allow'
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Playnite-Common.ps1')

function New-AllowlistResult {
    param(
        [int]$Added = 0,
        [int]$Skipped = 0,
        [int]$Replaced = 0,
        [string[]]$Warnings = @(),
        [string]$Path = "",
        [string]$ResolvedNameId = ""
    )
    return [PSCustomObject]@{
        Added          = $Added
        Skipped        = $Skipped
        Replaced       = $Replaced
        Warnings       = $Warnings
        Path           = $Path
        ResolvedNameId = $ResolvedNameId
        Success        = $true
        Message        = "Added $Added, skipped $Skipped, replaced $Replaced."
    }
}

function Read-AllowlistJsonDocument {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        $parsed = [PSCustomObject]@{ apps = @() }
    }
    if ($null -eq $parsed.apps) {
        $parsed | Add-Member -NotePropertyName apps -NotePropertyValue @() -Force
    }
    return $parsed
}

function Get-AllowlistEntryKey {
    param($Entry)
    return @{
        Exe    = if ($Entry.exe) { $Entry.exe.ToString().Trim() } else { '' }
        NameId = if ($Entry.nameId) { $Entry.nameId.ToString().Trim() } else { '' }
        Title  = if ($Entry.title) { $Entry.title.ToString().Trim() } else { '' }
        Type   = if ($Entry.type) { $Entry.type.ToString().Trim() } else { '' }
    }
}

function Normalize-IncomingEntry {
    param(
        $Entry,
        [string]$DefaultType = ''
    )

    $key = Get-AllowlistEntryKey -Entry $Entry
    if ([string]::IsNullOrWhiteSpace($key.Exe)) {
        throw 'Each entry requires exe.'
    }

    $type = $key.Type
    if ([string]::IsNullOrWhiteSpace($type)) {
        $type = $DefaultType
    }

    $nameId = $key.NameId
    if ([string]::IsNullOrWhiteSpace($nameId)) {
        throw "Entry for $($key.Exe) requires nameId or type for resolution."
    }

    if ($nameId -match '^\d{1,7}$' -and -not [string]::IsNullOrWhiteSpace($type)) {
        $nameId = Resolve-AllowlistNameId -Type $type -SlotInput $nameId
    }
    elseif ($nameId -match '^\d+$' -and [string]::IsNullOrWhiteSpace($type)) {
        $type = Get-AllowlistTypeFromNameId -NameId $nameId
        if ([string]::IsNullOrWhiteSpace($type)) {
            throw "Cannot infer type for nameId $nameId on $($key.Exe)."
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($type)) {
        if (-not (Test-NameIdInAllowlistTypeRange -NameId $nameId -Type $type)) {
            $nameId = Resolve-AllowlistNameId -Type $type -SlotInput $nameId
        }
    }
    else {
        $type = Get-AllowlistTypeFromNameId -NameId $nameId
        if ([string]::IsNullOrWhiteSpace($type)) {
            throw "Cannot infer type for nameId $nameId on $($key.Exe)."
        }
    }

    if (-not (Test-NameIdInAllowlistTypeRange -NameId $nameId -Type $type)) {
        throw "nameId $nameId is outside type $type range."
    }

    $title = $key.Title
    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [System.IO.Path]::GetFileNameWithoutExtension($key.Exe)
    }

    return [PSCustomObject]@{
        exe    = $key.Exe
        nameId = $nameId
        title  = $title
        type   = $type
    }
}

function Import-AllowlistEntriesFromFile {
    param([string]$Path)

    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($ext -eq '.json') {
        $doc = Read-AllowlistJsonDocument -Path $Path
        return @($doc.apps | ForEach-Object { Normalize-IncomingEntry -Entry $_ })
    }

    if ($ext -eq '.csv') {
        $rows = Import-Csv -LiteralPath $Path
        $result = New-Object System.Collections.Generic.List[object]
        foreach ($row in $rows) {
            $entry = [PSCustomObject]@{
                exe    = $row.exe
                nameId = $row.nameId
                title  = $row.title
                type   = $row.type
            }
            [void]$result.Add((Normalize-IncomingEntry -Entry $entry))
        }
        return $result.ToArray()
    }

    throw "Unsupported import format: $ext (use .json or .csv)"
}

function Merge-AllowlistEntries {
    param(
        [array]$Incoming,
        [string]$OnDuplicateNameIdPolicy,
        [string]$OnDuplicateExePolicy
    )

    $targetPath = Ensure-DesktopAppAllowlistFile -RepoRoot $scriptRoot
    if (-not $targetPath) {
        throw 'Could not create desktop-apps.allowlist.json from template.'
    }

    $backup = Read-AllowlistJsonDocument -Path $targetPath
    $existing = [System.Collections.Generic.List[object]]::new()
    foreach ($app in @($backup.apps)) {
        if ($null -ne $app) { [void]$existing.Add($app) }
    }

    $added = 0
    $skipped = 0
    $replaced = 0
    $warnings = New-Object System.Collections.Generic.List[string]

    foreach ($incoming in $Incoming) {
        $norm = if ($incoming.exe) { $incoming } else { Normalize-IncomingEntry -Entry $incoming -DefaultType $Type }
        $exeKey = $norm.exe.ToLowerInvariant()

        $dupName = $existing | Where-Object { $_.nameId -eq $norm.nameId } | Select-Object -First 1
        if ($dupName) {
            $same = ($dupName.exe -eq $norm.exe -and $dupName.title -eq $norm.title -and $dupName.type -eq $norm.type)
            if ($same) {
                $skipped++
                continue
            }
            if ($OnDuplicateNameIdPolicy -eq 'Skip') {
                $skipped++
                [void]$warnings.Add("Skipped duplicate nameId $($norm.nameId) for $($norm.exe).")
                continue
            }
            $idx = $existing.IndexOf($dupName)
            $existing[$idx] = $norm
            $replaced++
            continue
        }

        $dupExe = $existing | Where-Object { $_.exe -and ($_.exe.ToString().ToLowerInvariant() -eq $exeKey) } | Select-Object -First 1
        if ($dupExe) {
            if ($OnDuplicateExePolicy -eq 'Skip') {
                $skipped++
                [void]$warnings.Add("Skipped duplicate exe $($norm.exe).")
                continue
            }
            if ($OnDuplicateExePolicy -eq 'Replace') {
                $idx = $existing.IndexOf($dupExe)
                $existing[$idx] = $norm
                $replaced++
                continue
            }
            [void]$warnings.Add("Allowing duplicate exe $($norm.exe); distinguished by nameId $($norm.nameId).")
        }

        [void]$existing.Add($norm)
        $added++
    }

    $outDoc = [ordered]@{
        _comment = 'List executable filenames only (exe), not install paths. Setup uses voidtools es.exe to find the real path and writes it into Playnite.'
        apps     = @($existing)
    }

    $json = $outDoc | ConvertTo-Json -Depth 20
    $tempPath = "$targetPath.tmp"
    Set-Content -LiteralPath $tempPath -Value $json -Encoding utf8
    try {
        $null = Get-DesktopAppAllowlist -RepoRoot $scriptRoot -AllowlistPath $tempPath
        Move-Item -LiteralPath $tempPath -Destination $targetPath -Force
    }
    catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }

    return New-AllowlistResult -Added $added -Skipped $skipped -Replaced $replaced -Warnings $warnings -Path $targetPath
}

try {
    if (-not [string]::IsNullOrWhiteSpace($ImportPath)) {
        if (-not (Test-Path -LiteralPath $ImportPath)) {
            throw "Import file not found: $ImportPath"
        }
        $incoming = Import-AllowlistEntriesFromFile -Path $ImportPath
        $result = Merge-AllowlistEntries -Incoming $incoming -OnDuplicateNameIdPolicy $OnDuplicateNameId -OnDuplicateExePolicy $OnDuplicateExe
        $result | ConvertTo-Json -Depth 5 -Compress
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Exe) -or [string]::IsNullOrWhiteSpace($NameIdInput) -or [string]::IsNullOrWhiteSpace($Type)) {
        throw 'Single-entry merge requires -Exe, -NameIdInput, and -Type (or use -ImportPath).'
    }

    $resolvedId = Resolve-AllowlistNameId -Type $Type -SlotInput $NameIdInput
    $entry = Normalize-IncomingEntry -Entry ([PSCustomObject]@{
            exe    = $Exe.Trim()
            nameId = $resolvedId
            title  = $Title
            type   = $Type
        })

    $result = Merge-AllowlistEntries -Incoming @($entry) -OnDuplicateNameIdPolicy $OnDuplicateNameId -OnDuplicateExePolicy $OnDuplicateExe
    $result.ResolvedNameId = $resolvedId
    $result | ConvertTo-Json -Depth 5 -Compress
    exit 0
}
catch {
    [PSCustomObject]@{
        Success = $false
        Message = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
