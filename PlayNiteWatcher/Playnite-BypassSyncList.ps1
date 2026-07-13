#Requires -Version 5.1
<#
    Bypass sync list helpers — declarative targets for setup and sync.
    Dot-sourced from Playnite-BypassCommon.ps1.
#>

$script:BypassSyncListFileName = 'bypass-sync-list.json'
$script:BypassSyncListTemplateFileName = 'bypass-sync-list.json.template'

function Get-BypassSyncListPath {
    param([string]$RepoRoot)
    return Join-Path $RepoRoot "config\playnite\$($script:BypassSyncListFileName)"
}

function Ensure-BypassSyncListFile {
    param([string]$RepoRoot)

    $target = Get-BypassSyncListPath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $target) {
        return $target
    }

    $template = Join-Path $RepoRoot "config\playnite\$($script:BypassSyncListTemplateFileName)"
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Bypass sync list template not found: $template"
    }

    $dir = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Copy-Item -LiteralPath $template -Destination $target -Force
    return $target
}

function Get-BypassSyncListAppExe {
    param($Entry)
    if ($null -eq $Entry) { return '' }
    if ($Entry.PSObject.Properties.Match('appExe').Count -gt 0 -and $Entry.appExe) {
        return $Entry.appExe.ToString().Trim()
    }
    if ($Entry.PSObject.Properties.Match('exe').Count -gt 0 -and $Entry.exe) {
        return $Entry.exe.ToString().Trim()
    }
    return ''
}

function Get-BypassSyncListBindingExe {
    param($Entry)

    $appExe = Get-BypassSyncListAppExe -Entry $Entry
    if (-not [string]::IsNullOrWhiteSpace($appExe)) {
        return $appExe
    }

    $launches = Normalize-BypassSyncListLaunches -Entry $Entry
    if ($launches.Count -gt 0 -and $launches[0].path) {
        return [System.IO.Path]::GetFileName($launches[0].path.ToString())
    }

    return ''
}

function Trim-BypassLaunchPath {
    param([string]$Path)

    $p = if ($null -eq $Path) { '' } else { $Path.Trim() }
    while ($p.Length -ge 2) {
        if (($p.StartsWith("'") -and $p.EndsWith("'")) -or ($p.StartsWith('"') -and $p.EndsWith('"'))) {
            $p = $p.Substring(1, $p.Length - 2).Trim()
            continue
        }
        break
    }

    return $p
}

function Normalize-BypassSyncListLaunchItem {
    param($Item)

    if ($null -eq $Item) {
        throw 'Each launch item must be an object with path.'
    }
    $path = Trim-BypassLaunchPath -Path $(if ($Item.path) { $Item.path.ToString() } else { '' })
    if ([string]::IsNullOrWhiteSpace($path)) {
        throw 'Each launch item requires path.'
    }
    $delaySec = 2
    if ($null -ne $Item.delaySec -and $Item.delaySec.ToString() -match '^\d+$') {
        $delaySec = [int]$Item.delaySec
    }
    if ($delaySec -lt 0) {
        throw "launch delaySec must be >= 0 for path: $path"
    }
    return [PSCustomObject]@{
        path     = $path
        delaySec = $delaySec
    }
}

function Normalize-BypassSyncListLaunches {
    param($Entry)

    $normalized = New-Object System.Collections.Generic.List[object]
    if ($Entry.launches) {
        foreach ($item in @($Entry.launches)) {
            [void]$normalized.Add((Normalize-BypassSyncListLaunchItem -Item $item))
        }
    }
    elseif ($Entry.helperPath -and -not [string]::IsNullOrWhiteSpace($Entry.helperPath.ToString())) {
        [void]$normalized.Add([PSCustomObject]@{
                path     = $Entry.helperPath.ToString().Trim()
                delaySec = 2
            })
    }
    return ,$normalized.ToArray()
}

function Format-BypassSyncListPreLaunchesSummary {
    param([object[]]$Launches)

    $list = @($Launches)
    if ($list.Count -eq 0) { return '—' }
    if ($list.Count -eq 1) {
        $leaf = [System.IO.Path]::GetFileName($list[0].path)
        return "$leaf (+$($list[0].delaySec)s)"
    }
    $leaves = @($list | ForEach-Object { [System.IO.Path]::GetFileName($_.path) })
    return "$($list.Count) pre-launches ($($leaves -join ', '))"
}

function Get-BypassSyncListEntryKey {
    param($Entry)
    return @{
        Title        = if ($Entry.title) { $Entry.title.ToString().Trim() } else { '' }
        GameId       = if ($Entry.gameId) { $Entry.gameId.ToString().Trim() } else { '' }
        NameId       = if ($Entry.nameId) { $Entry.nameId.ToString().Trim() } else { '' }
        AppExe       = if ($Entry.appExe) { $Entry.appExe.ToString().Trim() } elseif ($Entry.exe) { $Entry.exe.ToString().Trim() } else { '' }
        ShortcutName = if ($Entry.shortcutName) { $Entry.shortcutName.ToString().Trim() } else { '' }
    }
}

function Test-BypassSyncListEntryValid {
    param($Entry)

    $key = Get-BypassSyncListEntryKey -Entry $Entry
    if ([string]::IsNullOrWhiteSpace($key.Title)) {
        throw 'Each sync list entry requires title.'
    }
    if ([string]::IsNullOrWhiteSpace($key.ShortcutName)) {
        throw "Entry '$($key.Title)' requires shortcutName."
    }

    $hasGameId = -not [string]::IsNullOrWhiteSpace($key.GameId)
    $hasNameId = -not [string]::IsNullOrWhiteSpace($key.NameId)
    if ($hasGameId -and $hasNameId) {
        throw "Entry '$($key.Title)' cannot have both gameId and nameId."
    }
    if (-not $hasGameId -and -not $hasNameId) {
        throw "Entry '$($key.Title)' requires gameId or nameId."
    }

    return $true
}

function Normalize-BypassSyncListEntry {
    param($Entry)

    Test-BypassSyncListEntryValid -Entry $Entry | Out-Null
    $key = Get-BypassSyncListEntryKey -Entry $Entry
    $shortcutName = Sanitize-BypassShortcutFileName -Name $key.ShortcutName
    if ([string]::IsNullOrWhiteSpace($shortcutName)) {
        throw "Entry '$($key.Title)' has invalid shortcutName."
    }

    return [PSCustomObject]@{
        title        = $key.Title
        gameId       = $key.GameId
        nameId       = $key.NameId
        shortcutName = $shortcutName
        launches     = Normalize-BypassSyncListLaunches -Entry $Entry
    }
}

function Get-BypassSyncList {
    param(
        [string]$RepoRoot,
        [string]$SyncListPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($SyncListPath)) {
        $SyncListPath = Ensure-BypassSyncListFile -RepoRoot $RepoRoot
    }

    $raw = Get-Content -LiteralPath $SyncListPath -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        $parsed = [PSCustomObject]@{ apps = @() }
    }
    if ($null -eq $parsed.apps) {
        $parsed | Add-Member -NotePropertyName apps -NotePropertyValue @() -Force
    }

    $entries = @()
    foreach ($app in @($parsed.apps)) {
        if ($null -eq $app) { continue }
        try {
            $entries += Normalize-BypassSyncListEntry -Entry $app
        }
        catch {
            throw "Invalid bypass sync list entry in ${SyncListPath}: $($_.Exception.Message)"
        }
    }

    return $entries
}

function Find-BypassSyncListEntry {
    param(
        [object[]]$Entries,
        [string]$GameId = "",
        [string]$NameId = "",
        [string]$ShortcutName = "",
        [string]$Title = ""
    )

    $list = @($Entries)
    if ([string]::IsNullOrWhiteSpace($GameId) -and [string]::IsNullOrWhiteSpace($NameId) `
            -and [string]::IsNullOrWhiteSpace($ShortcutName) -and [string]::IsNullOrWhiteSpace($Title)) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($GameId)) {
        $match = $list | Where-Object { $_.gameId -and $_.gameId -ieq $GameId.Trim() } | Select-Object -First 1
        if ($match) { return $match }
    }
    if (-not [string]::IsNullOrWhiteSpace($NameId)) {
        $match = $list | Where-Object { $_.nameId -and $_.nameId -ieq $NameId.Trim() } | Select-Object -First 1
        if ($match) { return $match }
    }
    if (-not [string]::IsNullOrWhiteSpace($ShortcutName)) {
        $key = Sanitize-BypassShortcutFileName -Name $ShortcutName
        $match = $list | Where-Object { $_.shortcutName -ieq $key } | Select-Object -First 1
        if ($match) { return $match }
    }
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $titleKey = $Title.Trim().ToLowerInvariant()
        $match = $list | Where-Object { $_.title -and $_.title.Trim().ToLowerInvariant() -eq $titleKey } | Select-Object -First 1
        if ($match) { return $match }
    }

    return $null
}

function Get-NormalizedSyncListStoreGameId {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ''
    }

    $text = $Value.ToString().Trim()
    if ($text -match '(\d{4,})') {
        return $Matches[1]
    }

    return $text.ToLowerInvariant()
}

function Test-PlayniteGameMatchesSyncGameId {
    param(
        [object]$Game,
        [string]$SyncGameId
    )

    if (-not $Game -or [string]::IsNullOrWhiteSpace($SyncGameId)) {
        return $false
    }

    $playniteGameId = if ($Game.GameId) { $Game.GameId.ToString().Trim() } else { '' }
    if ($playniteGameId -ieq $SyncGameId.Trim()) {
        return $true
    }

    $normalizedPlaynite = Get-NormalizedSyncListStoreGameId -Value $playniteGameId
    $normalizedSync = Get-NormalizedSyncListStoreGameId -Value $SyncGameId
    return (-not [string]::IsNullOrWhiteSpace($normalizedPlaynite) `
        -and -not [string]::IsNullOrWhiteSpace($normalizedSync) `
        -and $normalizedPlaynite -eq $normalizedSync)
}

function Find-PlayniteGameForSyncEntry {
    param(
        [object]$Entry,
        [object[]]$Games,
        [string]$RepoRoot
    )

    if (-not $Entry) { return $null }

    $Games = Normalize-PlayniteGamesArray -Games $Games
    $gameId = if ($Entry.gameId) { $Entry.gameId.ToString().Trim() } else { "" }
    $nameId = if ($Entry.nameId) { $Entry.nameId.ToString().Trim() } else { "" }
    $title = if ($Entry.title) { $Entry.title.ToString().Trim() } else { "" }
    $exe = Get-BypassSyncListAppExe -Entry $Entry

    if (-not [string]::IsNullOrWhiteSpace($gameId)) {
        $matches = @($Games | Where-Object { Test-PlayniteGameMatchesSyncGameId -Game $_ -SyncGameId $gameId })
        if ($matches.Count -gt 0) {
            $store = Get-SinglePlayniteGameRecord -Game (@($matches | Where-Object { Test-PlayniteGameIsStoreLibrary -Game $_ }) | Select-Object -First 1)
            if ($store) { return $store }
            return Get-SinglePlayniteGameRecord -Game ($matches | Select-Object -First 1)
        }

        $matchTitle = $title
        if ([string]::IsNullOrWhiteSpace($matchTitle) -and $Entry.shortcutName) {
            $matchTitle = $Entry.shortcutName.ToString().Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($matchTitle)) {
            return Find-PlayniteStoreGameForBypassShortcut -Games $Games -Title $matchTitle
        }

        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($nameId)) {
        $allow = $null
        try {
            $allowlist = Get-DesktopAppAllowlist -RepoRoot $RepoRoot
            $allow = $allowlist | Where-Object { $_.NameId -ieq $nameId } | Select-Object -First 1
        }
        catch { }

        $matchTitle = if ($allow) { $allow.Title } else { $title }
        $matchExe = if ($allow) { $allow.Exe } else { $exe }
        return Find-PlayniteGameForBypassShortcut -Games $Games -ExePath $matchExe -Title $matchTitle
    }

    return $null
}

function Get-BypassSyncListEntryHint {
    param(
        [object]$Entry,
        [object]$PlayniteGame
    )

    $parts = @()
    if ($Entry.gameId) { $parts += "gameId=$($Entry.gameId)" }
    if ($Entry.nameId) { $parts += "nameId=$($Entry.nameId)" }
    if ($PlayniteGame) {
        $parts += "Playnite: $($PlayniteGame.Name)"
        if ($PlayniteGame.GameId) { $parts += "store=$($PlayniteGame.GameId)" }
    }
    else {
        $parts += 'Playnite: (no match)'
    }
    return ($parts -join ' | ')
}

function Get-BypassShortcutReviewRowsFromSyncList {
    param(
        [string]$BypassesPath,
        [string]$RepoRoot,
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($BypassesPath) -or -not (Test-Path -LiteralPath $BypassesPath)) {
        throw "Game Shortcuts folder not found: $BypassesPath"
    }

    $entries = Get-BypassSyncList -RepoRoot $RepoRoot
    if ($entries.Count -eq 0) {
        throw 'Bypass sync list is empty. Add entries on the Bypass Sync tab before running sync.'
    }

    $games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -StopPlayniteFirst -LogAction $LogAction)
    $rows = @()

    foreach ($entry in $entries) {
        $shortcutName = $entry.shortcutName
        $lnkPath = Join-Path $BypassesPath "$shortcutName.lnk"
        $playniteGame = Find-PlayniteGameForSyncEntry -Entry $entry -Games $games -RepoRoot $RepoRoot

        $preLaunches = @($entry.launches)
        $rows += [PSCustomObject]@{
            OriginalLnkPath     = $lnkPath
            FileName            = "$shortcutName.lnk"
            DisplayName         = $shortcutName
            SyncListEntry       = $entry
            SuggestedPlayniteId = if ($playniteGame) { $playniteGame.Id } else { "" }
            SuggestedNameId     = if ($entry.nameId) { $entry.nameId } else { "" }
            SuggestedExe        = Get-BypassSyncListBindingExe -Entry $entry
            SuggestedType       = "ThirdParty"
            Hint                = Get-BypassSyncListEntryHint -Entry $entry -PlayniteGame $playniteGame
            IsNewDesktopApp     = $false
            PreLaunches         = $preLaunches
            PreLaunchesSummary  = Format-BypassSyncListPreLaunchesSummary -Launches $preLaunches
            HelperPath          = if ($preLaunches.Count -gt 0) { $preLaunches[0].path } else { "" }
            HelperDelaySec      = if ($preLaunches.Count -gt 0) { $preLaunches[0].delaySec } else { 2 }
        }
    }

    return $rows
}

function Invoke-SingleBypassSyncListEntry {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [string]$BypassesPath,
        [object]$Entry,
        [switch]$WhatIf,
        [scriptblock]$LogAction
    )

    $shortcutName = Sanitize-BypassShortcutFileName -Name $Entry.shortcutName
    if ([string]::IsNullOrWhiteSpace($shortcutName)) {
        if ($LogAction) { & $LogAction "Skip (invalid shortcutName): $($Entry.title)" "WARN" }
        return [PSCustomObject]@{ Updated = 0; Skipped = 1; Missing = 0 }
    }

    $lnkPath = Join-Path $BypassesPath "$shortcutName.lnk"
    if (-not (Test-Path -LiteralPath $lnkPath)) {
        if ($LogAction) { & $LogAction "Skip (shortcut missing): $lnkPath" "WARN" }
        return [PSCustomObject]@{ Updated = 0; Skipped = 0; Missing = 1 }
    }

    $games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -StopPlayniteFirst -LogAction $LogAction)
    $playniteGame = Find-PlayniteGameForSyncEntry -Entry $Entry -Games $games -RepoRoot $RepoRoot
    if (-not $playniteGame) {
        if ($LogAction) { & $LogAction "Skip (no Playnite match): $($Entry.title)" "WARN" }
        return [PSCustomObject]@{ Updated = 0; Skipped = 0; Missing = 1 }
    }

    if ($WhatIf) {
        if ($LogAction) { & $LogAction "Would sync: $shortcutName -> $($playniteGame.Name)" }
        return [PSCustomObject]@{ Updated = 1; Skipped = 0; Missing = 0 }
    }

    $preLaunches = @($Entry.launches)
    $reviewRow = [PSCustomObject]@{
        OriginalLnkPath    = $lnkPath
        FileName           = "$shortcutName.lnk"
        DisplayName        = $shortcutName
        SyncListEntry      = $Entry
        PreLaunches        = $preLaunches
        PreLaunchesSummary = Format-BypassSyncListPreLaunchesSummary -Launches $preLaunches
        HelperPath         = if ($preLaunches.Count -gt 0) { $preLaunches[0].path } else { "" }
        HelperDelaySec     = if ($preLaunches.Count -gt 0) { $preLaunches[0].delaySec } else { 2 }
        SuggestedExe       = Get-BypassSyncListBindingExe -Entry $Entry
    }

    $launcherResult = Resolve-BypassReviewedRowLauncher `
        -Row $reviewRow `
        -BypassesPath $BypassesPath `
        -DisplayName $shortcutName `
        -ShortcutLnkPath $lnkPath `
        -LogAction $LogAction
    if ($launcherResult.Skipped) {
        if ($LogAction) { & $LogAction "Skip (launcher build failed): $shortcutName" "WARN" }
        return [PSCustomObject]@{ Updated = 0; Skipped = 1; Missing = 0 }
    }

    $nameId = if ($Entry.nameId) { $Entry.nameId } else { "" }
    $type = "ThirdParty"
    if ($nameId) {
        $inferred = Get-AllowlistTypeFromNameId -NameId $nameId
        if ($inferred) { $type = $inferred }
    }

    $bindingExe = if ($launcherResult.ExeLeaf) { $launcherResult.ExeLeaf } else { Get-BypassSyncListBindingExe -Entry $Entry }
    if ([string]::IsNullOrWhiteSpace($bindingExe)) {
        $bindingExe = 'game.exe'
    }

    $syncParams = @{
        InstallDir         = $InstallDir
        RepoRoot           = $RepoRoot
        LaunchPath         = $launcherResult.PlayLaunchPath
        Exe                = $bindingExe
        Title              = if ($playniteGame.Name) { $playniteGame.Name } else { $Entry.title }
        NameId             = $nameId
        Type               = $type
        NameIdInput        = ""
        IsNewApp           = $false
        ExistingPlayniteId = $playniteGame.Id
        LauncherMode       = $launcherResult.LauncherMode
        LauncherScript     = $launcherResult.LauncherScript
        HelperPath         = $launcherResult.HelperPath
        PreLaunches        = @($launcherResult.PreLaunches)
        ShortcutLnkPath    = $launcherResult.ShortcutLnkPath
        LogAction          = $LogAction
    }

    Sync-PlayniteBypassBindingToLibrary @syncParams -SyncListDriven | Out-Null
    if ($LogAction) { & $LogAction "Sync list updated: $($Entry.title) -> $($launcherResult.PlayLaunchPath)" }
    return [PSCustomObject]@{ Updated = 1; Skipped = 0; Missing = 0 }
}

function Invoke-PlayniteBypassSyncFromSyncList {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [string]$BypassesPath = "",
        [switch]$WhatIf,
        [scriptblock]$LogAction
    )

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $config = $wrapper.Config
    $bypassRoot = $BypassesPath
    if ([string]::IsNullOrWhiteSpace($bypassRoot)) {
        $bypassRoot = $config.bypassesPath
    }
    if ([string]::IsNullOrWhiteSpace($bypassRoot) -or -not (Test-Path -LiteralPath $bypassRoot)) {
        throw "Game Shortcuts folder not found: $bypassRoot"
    }

    $entries = Get-BypassSyncList -RepoRoot $RepoRoot
    if ($entries.Count -eq 0) {
        if ($LogAction) { & $LogAction 'Bypass sync list is empty; nothing to sync.' 'WARN' }
        return @{ Updated = 0; Skipped = 0; Missing = 0 }
    }

    $stats = @{ Updated = 0; Skipped = 0; Missing = 0 }
    foreach ($entry in $entries) {
        $result = Invoke-SingleBypassSyncListEntry `
            -InstallDir $InstallDir `
            -RepoRoot $RepoRoot `
            -BypassesPath $bypassRoot `
            -Entry $entry `
            -WhatIf:$WhatIf `
            -LogAction $LogAction
        $stats.Updated += $result.Updated
        $stats.Skipped += $result.Skipped
        $stats.Missing += $result.Missing
    }

    return $stats
}

function Copy-BypassGameShortcutsForSyncList {
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutsSeedPath,
        [Parameter(Mandatory)]
        [string]$BypassesPath,
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [switch]$NoPrompt,
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $ShortcutsSeedPath)) {
        throw "Shortcuts seed folder not found: $ShortcutsSeedPath"
    }

    $entries = Get-BypassSyncList -RepoRoot $RepoRoot
    if ($entries.Count -eq 0) {
        throw 'Bypass sync list is empty. Add sync list entries before running Setup Bypass.'
    }

    if (-not (Test-Path -LiteralPath $BypassesPath)) {
        New-Item -ItemType Directory -Path $BypassesPath -Force | Out-Null
    }

    $copied = 0
    $skipped = 0
    foreach ($entry in $entries) {
        $name = "$($entry.shortcutName).lnk"
        $source = Join-Path $ShortcutsSeedPath $name
        $dest = Join-Path $BypassesPath $name
        if (-not (Test-Path -LiteralPath $source)) {
            $skipped++
            if ($LogAction) { & $LogAction "Seed shortcut missing (skipped): $name" 'WARN' }
            continue
        }
        Copy-Item -LiteralPath $source -Destination $dest -Force
        $copied++
        if ($LogAction) { & $LogAction "Copied seed shortcut: $name -> $dest" }
    }

    return [PSCustomObject]@{
        Copied  = $copied
        Skipped = $skipped
    }
}

function Test-RunAsToolRntItemMatchesSyncEntry {
    param(
        [hashtable]$Item,
        [object]$Entry
    )

    $fileName = if ($Item.FileName) { $Item.FileName.ToString().Trim() } else { "" }
    $filePath = if ($Item.FilePath) { $Item.FilePath.ToString().Trim() } else { "" }
    $exeLeaf = if ($filePath) { [System.IO.Path]::GetFileName($filePath) } else { "" }
    $title = if ($Entry.title) { $Entry.title.ToString().Trim() } else { "" }
    $shortcutName = if ($Entry.shortcutName) { $Entry.shortcutName.ToString().Trim() } else { "" }
    $appExe = Get-BypassSyncListAppExe -Entry $Entry

    if ($title -and $fileName -ieq $title) { return $true }
    if ($shortcutName -and $fileName -ieq $shortcutName) { return $true }
    if ($title -and $exeLeaf -and $appExe -and $exeLeaf -ieq $appExe) { return $true }
    if ($appExe -and $exeLeaf -ieq $appExe) { return $true }
    foreach ($launch in @($Entry.launches)) {
        if (-not $launch -or -not $launch.path) { continue }
        $launchLeaf = [System.IO.Path]::GetFileName($launch.path.ToString())
        if ($launchLeaf -and $exeLeaf -ieq $launchLeaf) { return $true }
        if ($launchLeaf -and $fileName -ieq $launchLeaf) { return $true }
    }
    return $false
}

function Parse-RunAsToolRntItems {
    param([string]$RntPath)

    $lines = Get-Content -LiteralPath $RntPath -Encoding UTF8
    $items = New-Object System.Collections.Generic.List[hashtable]
    $current = $null

    foreach ($line in $lines) {
        if ($line -match '^\s*\[RunAsTool_Item\]\s*$') {
            if ($current) { [void]$items.Add($current) }
            $current = @{}
            continue
        }
        if ($null -eq $current) { continue }
        if ($line -match '^\s*([^=]+)=(.*)$') {
            $current[$Matches[1].Trim()] = $Matches[2]
        }
    }
    if ($current) { [void]$items.Add($current) }
    return $items.ToArray()
}

function New-FilteredRunAsToolRnt {
    param(
        [Parameter(Mandatory)]
        [string]$RntPath,
        [Parameter(Mandatory)]
        [object[]]$SyncListEntries,
        [string]$OutputPath = ""
    )

    if (-not (Test-Path -LiteralPath $RntPath)) {
        throw "RNT file not found: $RntPath"
    }

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = Join-Path ([System.IO.Path]::GetTempPath()) ("RunAsTool-filtered-{0}.rnt" -f ([guid]::NewGuid().ToString('N')))
    }

    $allItems = Parse-RunAsToolRntItems -RntPath $RntPath
    $selected = New-Object System.Collections.Generic.List[hashtable]
    foreach ($item in $allItems) {
        foreach ($entry in @($SyncListEntries)) {
            if (Test-RunAsToolRntItemMatchesSyncEntry -Item $item -Entry $entry) {
                [void]$selected.Add($item)
                break
            }
        }
    }

    if ($selected.Count -eq 0) {
        throw 'No RunAsTool RNT items matched the bypass sync list.'
    }

    $header = "; Filtered by bypass sync list - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    $body = New-Object System.Collections.Generic.List[string]
    [void]$body.Add($header)
    foreach ($item in $selected) {
        [void]$body.Add('')
        [void]$body.Add('[RunAsTool_Item]')
        foreach ($key in @('ItemID', 'FileName', 'FilePath', 'Parameters', 'WorkingDir', 'Icon', 'IconIndex', 'FileSize', 'FileHash', 'ItemOptions')) {
            if ($item.ContainsKey($key)) {
                [void]$body.Add("$key=$($item[$key])")
            }
        }
    }

    Set-Content -LiteralPath $OutputPath -Value $body -Encoding UTF8
    return [PSCustomObject]@{
        Path          = $OutputPath
        IncludedCount = $selected.Count
        TotalCount    = $allItems.Count
    }
}
