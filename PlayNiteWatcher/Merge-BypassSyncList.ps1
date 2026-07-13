#Requires -Version 5.1
<#
.SYNOPSIS
    Add, merge, or remove entries in bypass-sync-list.json.
#>
[CmdletBinding()]
param(
    [string]$Title = "",
    [string]$GameId = "",
    [string]$NameId = "",
    [string]$ShortcutName = "",
    [string]$AppExe = "",
    [string]$LaunchesJson = "",
    [string]$PreLaunches = "",
    [string]$ImportPath = "",
    [string]$DeleteGameId = "",
    [string]$DeleteNameId = "",
    [string]$DeleteShortcutName = "",
    [ValidateSet('Skip', 'Replace')]
    [string]$OnDuplicate = 'Skip'
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Playnite-Common.ps1')

function New-SyncListMergeResult {
    param(
        [int]$Added = 0,
        [int]$Skipped = 0,
        [int]$Replaced = 0,
        [int]$Removed = 0,
        [string[]]$Warnings = @(),
        [string]$Path = "",
        [string]$Message = ""
    )
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "Added $Added, skipped $Skipped, replaced $Replaced, removed $Removed."
    }
    return [PSCustomObject]@{
        Added    = $Added
        Skipped  = $Skipped
        Replaced = $Replaced
        Removed  = $Removed
        Warnings = $Warnings
        Path     = $Path
        Success  = $true
        Message  = $Message
    }
}

function Read-SyncListJsonDocument {
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

function Write-SyncListJsonDocument {
    param(
        [string]$Path,
        [object[]]$Apps
    )
    $payload = [PSCustomObject]@{
        _comment = 'gameId (store) OR nameId (manual), not both. shortcutName = .lnk base name. launches[] = ordered pre-launch exe paths before the shortcut.'
        apps     = @($Apps)
    }
    $json = $payload | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function ConvertTo-SyncListSerializedApp {
    param($Entry)
    $obj = [PSCustomObject]@{
        title        = $Entry.title
        shortcutName = $Entry.shortcutName
        launches     = @($Entry.launches)
    }
    if ($Entry.appExe) { $obj | Add-Member -NotePropertyName appExe -NotePropertyValue $Entry.appExe -Force }
    if ($Entry.gameId) { $obj | Add-Member -NotePropertyName gameId -NotePropertyValue $Entry.gameId -Force }
    if ($Entry.nameId) { $obj | Add-Member -NotePropertyName nameId -NotePropertyValue $Entry.nameId -Force }
    return $obj
}

function ConvertTo-SyncListLaunchesArray {
    param(
        [string]$LaunchesJson,
        [string]$PreLaunches
    )

    if (-not [string]::IsNullOrWhiteSpace($PreLaunches)) {
        $items = @()
        foreach ($segment in ($PreLaunches -split ';')) {
            $piece = $segment.Trim()
            if ([string]::IsNullOrWhiteSpace($piece)) { continue }

            $delay = 2
            $path = $piece
            $pipe = $piece.LastIndexOf('|')
            if ($pipe -ge 0) {
                $path = $piece.Substring(0, $pipe).Trim()
                $delayPart = $piece.Substring($pipe + 1).Trim()
                if ($delayPart -match '^\d+$') {
                    $delay = [int]$delayPart
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($path)) {
                $path = Trim-BypassLaunchPath -Path $path
                $items += [PSCustomObject]@{ path = $path; delaySec = $delay }
            }
        }
        return $items
    }

    if (-not [string]::IsNullOrWhiteSpace($LaunchesJson)) {
        return @($LaunchesJson | ConvertFrom-Json)
    }

    return @()
}

function New-IncomingSyncListEntry {
    param(
        [string]$Title,
        [string]$GameId,
        [string]$NameId,
        [string]$ShortcutName,
        [string]$AppExe,
        [string]$LaunchesJson,
        [string]$PreLaunches
    )
    $entry = [PSCustomObject]@{
        title        = $Title.Trim()
        gameId       = $GameId.Trim()
        nameId       = $NameId.Trim()
        appExe       = $AppExe.Trim()
        shortcutName = $ShortcutName.Trim()
        launches     = @()
    }
    $entry.launches = @(ConvertTo-SyncListLaunchesArray -LaunchesJson $LaunchesJson -PreLaunches $PreLaunches)
    return Normalize-BypassSyncListEntry -Entry $entry
}

$repoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
$targetPath = Ensure-BypassSyncListFile -RepoRoot $repoRoot
$doc = Read-SyncListJsonDocument -Path $targetPath
$existing = [System.Collections.Generic.List[object]]::new()
foreach ($app in @($doc.apps)) {
    if ($null -ne $app) {
        try {
            [void]$existing.Add((Normalize-BypassSyncListEntry -Entry $app))
        }
        catch {
            throw "Invalid existing sync list entry in ${targetPath}: $($_.Exception.Message)"
        }
    }
}

$added = 0
$skipped = 0
$replaced = 0
$removed = 0
$warnings = New-Object System.Collections.Generic.List[string]

try {
if (-not [string]::IsNullOrWhiteSpace($DeleteGameId) -or -not [string]::IsNullOrWhiteSpace($DeleteNameId) -or -not [string]::IsNullOrWhiteSpace($DeleteShortcutName)) {
    $before = $existing.Count
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $existing) {
        $remove = $false
        if ($DeleteGameId -and $entry.gameId -ieq $DeleteGameId.Trim()) { $remove = $true }
        if ($DeleteNameId -and $entry.nameId -ieq $DeleteNameId.Trim()) { $remove = $true }
        if ($DeleteShortcutName) {
            $key = Sanitize-BypassShortcutFileName -Name $DeleteShortcutName
            if ($entry.shortcutName -ieq $key) { $remove = $true }
        }
        if (-not $remove) {
            [void]$filtered.Add($entry)
        }
    }
    $removed = $before - $filtered.Count
    $existing = $filtered
}
elseif (-not [string]::IsNullOrWhiteSpace($ImportPath)) {
    if (-not (Test-Path -LiteralPath $ImportPath)) {
        throw "Import file not found: $ImportPath"
    }
    $importRaw = Get-Content -LiteralPath $ImportPath -Raw -Encoding UTF8
    $importDoc = $importRaw | ConvertFrom-Json
    $incoming = @($importDoc.apps)
    if ($incoming.Count -eq 0) {
        throw "Import file has no apps array: $ImportPath"
    }
    foreach ($item in $incoming) {
        $norm = Normalize-BypassSyncListEntry -Entry $item
        $dup = Find-BypassSyncListEntry -Entries $existing -GameId $norm.gameId -NameId $norm.nameId -ShortcutName $norm.shortcutName -Title $norm.title
        if ($dup) {
            if ($OnDuplicate -eq 'Skip') {
                $skipped++
                [void]$warnings.Add("Skipped duplicate: $($norm.title)")
                continue
            }
            $idx = -1
            for ($i = 0; $i -lt $existing.Count; $i++) {
                if ($existing[$i] -eq $dup) { $idx = $i; break }
            }
            if ($idx -ge 0) {
                $existing[$idx] = $norm
                $replaced++
            }
            continue
        }
        [void]$existing.Add($norm)
        $added++
    }
}
else {
    if ([string]::IsNullOrWhiteSpace($Title) -or [string]::IsNullOrWhiteSpace($ShortcutName)) {
        throw 'Title and ShortcutName are required unless using -ImportPath or delete parameters.'
    }
    $norm = New-IncomingSyncListEntry -Title $Title -GameId $GameId -NameId $NameId -ShortcutName $ShortcutName -AppExe $AppExe -LaunchesJson $LaunchesJson -PreLaunches $PreLaunches
    $dup = Find-BypassSyncListEntry -Entries $existing -GameId $norm.gameId -NameId $norm.nameId -ShortcutName $norm.shortcutName -Title $norm.title
    if ($dup) {
        if ($OnDuplicate -eq 'Skip') {
            $skipped++
            [void]$warnings.Add("Skipped duplicate: $($norm.title)")
        }
        else {
            $idx = -1
            for ($i = 0; $i -lt $existing.Count; $i++) {
                if ($existing[$i] -eq $dup) { $idx = $i; break }
            }
            if ($idx -ge 0) {
                $existing[$idx] = $norm
                $replaced++
            }
        }
    }
    else {
        [void]$existing.Add($norm)
        $added++
    }
}

$serialized = @()
foreach ($entry in $existing) {
    $serialized += ConvertTo-SyncListSerializedApp -Entry $entry
}

Write-SyncListJsonDocument -Path $targetPath -Apps $serialized
$result = New-SyncListMergeResult -Added $added -Skipped $skipped -Replaced $replaced -Removed $removed -Warnings $warnings -Path $targetPath
$result | ConvertTo-Json -Depth 8 -Compress
exit 0
}
catch {
    [PSCustomObject]@{
        Success = $false
        Message = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
