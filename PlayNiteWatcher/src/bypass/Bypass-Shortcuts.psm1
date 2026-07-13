#Requires -Version 5.1
<#
    Shortcut file utilities and launch-path resolution.
    Dot-sourced from Playnite-Common.ps1.
#>

$script:_moduleRoot = $PSScriptRoot

function Sanitize-BypassShortcutFileName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ""
    }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $pattern = "[{0}]+" -f [regex]::Escape($invalid)
    $clean = ([regex]::Replace($Name.Trim(), $pattern, " ")).Trim()
    while ($clean -match '\s{2,}') { $clean = $clean -replace '\s{2,}', ' ' }
    return $clean
}

function Get-ShortcutLaunchInfo {
    param([string]$LnkPath)

    if (-not (Test-BypassPathLiteral -Path $LnkPath)) {
        return $null
    }

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($LnkPath)
    return [PSCustomObject]@{
        LnkPath    = $LnkPath
        Name       = [System.IO.Path]::GetFileNameWithoutExtension($LnkPath)
        TargetPath = $shortcut.TargetPath
        Arguments  = $shortcut.Arguments
        WorkingDir = $shortcut.WorkingDirectory
        IconPath   = $shortcut.IconLocation
    }
}

function Test-ShortcutLooksLikeRunAsTool {
    param([object]$ShortcutInfo)

    if (-not $ShortcutInfo) { return $false }
    $target = $ShortcutInfo.TargetPath
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }
    $leaf = [System.IO.Path]::GetFileName($target)
    return ($leaf -ieq 'RunAsTool.exe' -or $leaf -ieq 'RunAsTool_x64.exe')
}

function Find-AllowlistEntryByExeOrTitle {
    param(
        [string]$RepoRoot,
        [string]$Exe = "",
        [string]$Title = "",
        [string]$AllowlistPath = ""
    )

    try {
        $allowlist = Get-DesktopAppAllowlist -RepoRoot $RepoRoot -AllowlistPath $AllowlistPath
    }
    catch {
        return $null
    }

    $exeKey = if ($Exe) { ([System.IO.Path]::GetFileName($Exe)).ToLowerInvariant() } else { "" }
    $titleKey = if ($Title) { $Title.Trim().ToLowerInvariant() } else { "" }

    foreach ($entry in $allowlist) {
        if ($exeKey -and $entry.Exe.ToLowerInvariant() -eq $exeKey) {
            return $entry
        }
        if ($titleKey -and $entry.Title.ToLowerInvariant() -eq $titleKey) {
            return $entry
        }
    }
    return $null
}

function Find-PlayniteGameForBypassShortcut {
    param(
        [object[]]$Games,
        [string]$ExePath = "",
        [string]$Title = "",
        [string]$PlayniteId = "",
        [object[]]$Bindings = @()
    )

    $Games = Normalize-PlayniteGamesArray -Games $Games
    $runAsToolExeNames = @('runastool.exe', 'runastool_x64.exe')

    if (-not [string]::IsNullOrWhiteSpace($PlayniteId)) {
        $match = Get-SinglePlayniteGameRecord -Game ($Games | Where-Object { $_.Id -ieq $PlayniteId } | Select-Object -First 1)
        if ($match) { return $match }
    }

    if ($Bindings -and $Bindings.Count -gt 0) {
        foreach ($binding in $Bindings) {
            if ($binding.playniteId) {
                $match = Get-SinglePlayniteGameRecord -Game ($Games | Where-Object { $_.Id -ieq $binding.playniteId } | Select-Object -First 1)
                if ($match) { return $match }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        $titleKey = $Title.Trim().ToLowerInvariant()
        $byName = $Games | Where-Object { $_.Name -and $_.Name.Trim().ToLowerInvariant() -eq $titleKey }
        if ($byName) {
            return Get-SinglePlayniteGameRecord -Game ($byName | Select-Object -First 1)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExePath)) {
        $exeLeaf = ([System.IO.Path]::GetFileName($ExePath)).ToLowerInvariant()
        if ($exeLeaf -notin $runAsToolExeNames) {
            return Find-PlayniteGameForAllowlistExe -Games $Games -ExeName $exeLeaf
        }
    }

    return $null
}

function Test-PlayniteGameIsStoreLibrary {
    param([object]$Game)
    if (-not $Game) { return $false }
    return ($Game.PluginId -ieq $script:PlayniteSteamPluginId -or $Game.PluginId -ieq $script:PlayniteEpicPluginId)
}

function Find-PlayniteStoreGameForBypassShortcut {
    param(
        [object[]]$Games,
        [string]$Title = "",
        [string]$PreferredId = ""
    )

    $Games = Normalize-PlayniteGamesArray -Games $Games

    if (-not [string]::IsNullOrWhiteSpace($PreferredId)) {
        $preferred = Get-SinglePlayniteGameRecord -Game ($Games | Where-Object { $_.Id -ieq $PreferredId } | Select-Object -First 1)
        if ($preferred -and (Test-PlayniteGameIsStoreLibrary -Game $preferred)) {
            return $preferred
        }
    }

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return $null
    }

    $titleKey = $Title.Trim().ToLowerInvariant()
    $byName = @($Games | Where-Object { $_.Name -and $_.Name.Trim().ToLowerInvariant() -eq $titleKey })
    if ($byName.Count -eq 0) {
        return $null
    }

    $store = Get-SinglePlayniteGameRecord -Game (@($byName | Where-Object { Test-PlayniteGameIsStoreLibrary -Game $_ }) | Select-Object -First 1)
    if ($store) {
        return $store
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredId)) {
        return Get-SinglePlayniteGameRecord -Game ($Games | Where-Object { $_.Id -ieq $PreferredId } | Select-Object -First 1)
    }

    return Get-SinglePlayniteGameRecord -Game ($byName | Select-Object -First 1)
}

function Get-PlayniteGamesMatchingTitle {
    param(
        [object[]]$Games,
        [string]$Title
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        return @()
    }

    $titleKey = $Title.Trim().ToLowerInvariant()
    return @($Games | Where-Object { $_.Name -and $_.Name.Trim().ToLowerInvariant() -eq $titleKey })
}

function Get-PlayniteGameLibraryKindLabel {
    param([object]$Game)

    if (-not $Game) { return "library" }
    if (Test-PlayniteGameIsStoreLibrary -Game $Game) {
        if ($Game.PluginId -ieq $script:PlayniteSteamPluginId) { return "Steam" }
        return "Epic"
    }
    if ($Game.PluginId -ieq $script:PlayniteManualPluginId) { return "manual" }
    return "library"
}

function New-PlayniteDuplicateBypassNotice {
    param(
        [object[]]$Duplicates,
        [object]$UpdatedGame,
        [string]$LaunchPath
    )

    if (-not $UpdatedGame -or @($Duplicates).Count -le 1) {
        return ""
    }

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("Duplicate Playnite entries for '$($UpdatedGame.Name)':")
    foreach ($game in @($Duplicates)) {
        $kind = Get-PlayniteGameLibraryKindLabel -Game $game
        $path = if ($game.PrimaryPlayPath) { $game.PrimaryPlayPath } else { "(no play path)" }
        $marker = if ($game.Id -ieq $UpdatedGame.Id) { " <- launch path set to bypass" } else { "" }
        [void]$lines.Add("  - $kind : $path$marker")
    }
    [void]$lines.Add("Only the entry marked above was updated. Remove the extra row(s) in Playnite if you want a single library item.")
    return ($lines -join [Environment]::NewLine)
}

function Test-PlayniteGameHasActiveBypassBinding {
    param(
        [object]$Game,
        [object[]]$Bindings,
        [string]$BypassesPath = ""
    )

    if (-not $Game) { return $false }

    foreach ($binding in $Bindings) {
        if ($binding.playniteId -and $Game.Id -ieq $binding.playniteId) {
            return $true
        }
    }

    $path = $Game.PrimaryPlayPath
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    if (-not $path.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($BypassesPath)) {
        $bypassRoot = $BypassesPath.TrimEnd('\') + '\'
        $normalized = Normalize-EverythingSearchPath -Path $path
        if ($normalized -and $normalized.StartsWith($bypassRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $path.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-PlayniteOrAllowlistExistsForBypassApp {
    param(
        [string]$RepoRoot,
        [string]$InstallDir,
        [string]$ExePath,
        [string]$Title,
        [string]$AllowlistPath = ""
    )

    $exeLeaf = if ($ExePath) { [System.IO.Path]::GetFileName($ExePath) } else { "" }
    $allowlistMatch = Find-AllowlistEntryByExeOrTitle -RepoRoot $RepoRoot -Exe $exeLeaf -Title $Title -AllowlistPath $AllowlistPath

    $games = Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -StopPlayniteFirst
    $playniteMatch = Find-PlayniteGameForBypassShortcut -Games $games -ExePath $ExePath -Title $Title

    return [PSCustomObject]@{
        AllowlistMatch = $allowlistMatch
        PlayniteMatch  = $playniteMatch
        Exists         = ($null -ne $allowlistMatch -or $null -ne $playniteMatch)
    }
}

function Invoke-PlayniteLibraryDatabaseSession {
    param(
        [string]$InstallDir,
        [scriptblock]$EditAction,
        [scriptblock]$LogAction
    )

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    Ensure-PlayniteLibraryDatabaseUnlocked -InstallDir $InstallDir -LogAction $LogAction

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir

    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir
    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)

    try {
        $result = & $EditAction $db
        return $result
    }
    finally {
        $db.Dispose()
        Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 15 -Force
    }
}

function Merge-BypassAllowlistEntry {
    param(
        [string]$RepoRoot,
        [string]$Exe,
        [string]$Title,
        [string]$Type,
        [string]$NameIdInput,
        [scriptblock]$LogAction
    )

    $mergeScript = Join-Path (Get-PlayNiteWatcherScriptRoot) "Merge-DesktopAppAllowlist.ps1"
    if (-not (Test-Path -LiteralPath $mergeScript)) {
        throw "Merge-DesktopAppAllowlist.ps1 not found: $mergeScript"
    }

    $mergeParams = @{
        Exe               = $Exe
        NameIdInput       = $NameIdInput
        Title             = $Title
        Type              = $Type
        OnDuplicateNameId = 'Replace'
        OnDuplicateExe    = 'Replace'
    }

    if ($LogAction) { & $LogAction "Merging allowlist: $Title ($Exe) nameId=$NameIdInput" }
    & $mergeScript @mergeParams | Out-Null
}

function Sync-PlayniteBypassBindingToLibrary {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [string]$LaunchPath,
        [string]$Exe,
        [string]$Title,
        [string]$NameId,
        [string]$Type,
        [string]$NameIdInput,
        [bool]$IsNewApp,
        [string]$ExistingPlayniteId = "",
        [switch]$OutsideAllowlist,
        [string]$LauncherMode = "",
        [string]$LauncherScript = "",
        [string]$HelperPath = "",
        [string]$GamePath = "",
        [string]$ShortcutLnkPath = "",
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $LaunchPath)) {
        throw "Bypass shortcut not found: $LaunchPath"
    }

    if ($IsNewApp -or $NameIdInput) {
        Merge-BypassAllowlistEntry -RepoRoot $RepoRoot -Exe $Exe -Title $Title -Type $Type -NameIdInput $NameIdInput -LogAction $LogAction
        $allowEntry = Find-AllowlistEntryByExeOrTitle -RepoRoot $RepoRoot -Exe $Exe -Title $Title
        if ($allowEntry) {
            $NameId = $allowEntry.NameId
            $Title = $allowEntry.Title
        }
    }
    elseif ($NameId) {
        $mergeType = if ($Type -in @('Adobe', 'Autodesk', 'ThirdParty', 'Games')) {
            $Type
        }
        elseif ($NameId -match '^\d+$') {
            Get-AllowlistTypeFromNameId -NameId $NameId
        }
        else {
            'ThirdParty'
        }
        if ([string]::IsNullOrWhiteSpace($mergeType)) {
            $mergeType = 'ThirdParty'
        }
        Merge-BypassAllowlistEntry -RepoRoot $RepoRoot -Exe $Exe -Title $Title -Type $mergeType -NameIdInput $NameId -LogAction $LogAction
    }

    $dbResult = Invoke-PlayniteLibraryDatabaseSession -InstallDir $InstallDir -LogAction $LogAction -EditAction {
        param($db)
        $collection = $db.GetCollection("Game")
        $templateGame = Get-PlayniteNativeGameBsonTemplateDocument -Collection $collection
        $allGames = @(
            foreach ($doc in $collection.FindAll()) {
                New-PlayniteGameRecordFromBsonDocument -Doc $doc
            }
        ) | Where-Object { $_ }

        $existing = $null
        $duplicateNotice = ""

        if ($OutsideAllowlist.IsPresent) {
            $existing = Find-PlayniteStoreGameForBypassShortcut -Games $allGames -Title $Title -PreferredId $ExistingPlayniteId
        }
        else {
            if ($ExistingPlayniteId) {
                $existing = $allGames | Where-Object { $_.Id -ieq $ExistingPlayniteId } | Select-Object -First 1
            }
            if (-not $existing) {
                $existing = Find-PlayniteGameForBypassShortcut -Games $allGames -ExePath $Exe -Title $Title
            }
        }

        if (-not $existing) {
            $titleDupes = Get-PlayniteGamesMatchingTitle -Games $allGames -Title $Title
            if ($titleDupes.Count -gt 0) {
                if ($OutsideAllowlist.IsPresent) {
                    $existing = Find-PlayniteStoreGameForBypassShortcut -Games $allGames -Title $Title -PreferredId $ExistingPlayniteId
                }
                if (-not $existing) {
                    $existing = $titleDupes | Select-Object -First 1
                }
            }
        }

        if ($existing) {
            Update-PlayniteGamePlayActionInDocument -Doc $existing.LiteDbDocument -ExePath $LaunchPath -Title $Title
            [void]$collection.Update($existing.LiteDbDocument)
            if ($LogAction) { & $LogAction "Playnite bypass updated: $Title -> $LaunchPath" }

            $dupes = Get-PlayniteGamesMatchingTitle -Games $allGames -Title $Title
            $duplicateNotice = New-PlayniteDuplicateBypassNotice -Duplicates $dupes -UpdatedGame $existing -LaunchPath $LaunchPath
            if ($duplicateNotice -and $LogAction) {
                & $LogAction $duplicateNotice "WARN"
            }

            return [PSCustomObject]@{
                PlayniteId       = $existing.Id
                Action           = "Updated"
                DuplicateNotice  = $duplicateNotice
            }
        }

        $newDoc = New-PlayniteManualGameBsonDocument -Title $Title -ExePath $LaunchPath -TemplateGameDocument $templateGame
        [void]$collection.Insert($newDoc)
        $newId = Get-BsonValueAsGuid -Value $newDoc['_id']
        if ($LogAction) { & $LogAction "Playnite bypass added: $Title -> $LaunchPath" }
        return [PSCustomObject]@{
            PlayniteId      = $newId
            Action          = "Added"
            DuplicateNotice = ""
        }
    }

    $playniteId = $dbResult.PlayniteId
    $action = $dbResult.Action
    $duplicateNotice = $dbResult.DuplicateNotice

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $config = $wrapper.Config
    $bindings = [System.Collections.Generic.List[object]]::new()
    foreach ($b in @($config.bindings)) {
        if ($null -eq $b) { continue }
        if ($b.playniteId -and $playniteId -and $b.playniteId -ieq $playniteId) { continue }
        if ($b.launchPath -and $b.launchPath -ieq $LaunchPath) { continue }
        if ($ShortcutLnkPath -and $b.shortcutLnkPath -and $b.shortcutLnkPath -ieq $ShortcutLnkPath) { continue }
        if ($ShortcutLnkPath -and $b.launchPath -and $b.launchPath -ieq $ShortcutLnkPath) { continue }
        [void]$bindings.Add($b)
    }

    $bindingObj = [PSCustomObject]@{
            playniteId    = $playniteId
            shortcutName  = [System.IO.Path]::GetFileNameWithoutExtension($LaunchPath)
            launchPath    = $LaunchPath
            exe           = [System.IO.Path]::GetFileName($Exe)
            nameId        = $NameId
            title         = $Title
            syncType      = if ($OutsideAllowlist.IsPresent) { 'OutsideAllowlist' } else { 'InAllowlist' }
            updatedAt     = (Get-Date).ToString("o")
        }
    if ($LauncherMode) {
        $bindingObj | Add-Member -NotePropertyName launcherMode -NotePropertyValue $LauncherMode -Force
    }
    if ($LauncherScript) {
        $bindingObj | Add-Member -NotePropertyName launcherScript -NotePropertyValue $LauncherScript -Force
    }
    if ($HelperPath) {
        $bindingObj | Add-Member -NotePropertyName helperPath -NotePropertyValue $HelperPath -Force
    }
    if ($GamePath) {
        $bindingObj | Add-Member -NotePropertyName gamePath -NotePropertyValue $GamePath -Force
    }
    if ($ShortcutLnkPath) {
        $bindingObj | Add-Member -NotePropertyName shortcutLnkPath -NotePropertyValue $ShortcutLnkPath -Force
    }

    [void]$bindings.Add($bindingObj)

    $config.bindings = @($bindings)
    Save-BypassShortcutsConfig -RepoRoot $RepoRoot -Config $config
    Publish-NextGpuBypassBindingsToPlaynite -InstallDir $InstallDir -Config $config

    return [PSCustomObject]@{
        PlayniteId      = $playniteId
        Action          = $action
        LaunchPath      = $LaunchPath
        NameId          = $NameId
        Title           = $Title
        DuplicateNotice = $duplicateNotice
    }
}

function Get-BypassShortcutSyncTypeFromGame {
    param(
        [object]$PlayniteGame,
        [object]$AllowlistMatch
    )

    if ($AllowlistMatch) {
        return 'InAllowlist'
    }
    if (-not $PlayniteGame) {
        return 'InAllowlist'
    }

    $pluginId = $PlayniteGame.PluginId
    if ($pluginId -ieq $script:PlayniteSteamPluginId -or $pluginId -ieq $script:PlayniteEpicPluginId) {
        return 'OutsideAllowlist'
    }

    return 'InAllowlist'
}

function Get-BypassShortcutReviewHint {
    param(
        [object]$PlayniteGame,
        [object]$AllowlistMatch,
        [object]$Binding
    )

    if ($AllowlistMatch) {
        return "Allowlist: $($AllowlistMatch.Title) nameId=$($AllowlistMatch.NameId)"
    }
    $game = Get-SinglePlayniteGameRecord -Game $PlayniteGame
    if ($game) {
        if ($game.PluginId -ieq $script:PlayniteSteamPluginId) {
            $appId = if ($game.GameId) { $game.GameId } else { "?" }
            return "Playnite: $($game.Name) (Steam AppID $appId)"
        }
        if ($game.PluginId -ieq $script:PlayniteEpicPluginId) {
            return "Playnite: $($game.Name) (Epic)"
        }
        if ($game.PluginId -ieq $script:PlayniteManualPluginId) {
            return "Playnite: $($game.Name) (manual)"
        }
        return "Playnite: $($game.Name)"
    }
    if ($Binding -and $Binding.title) {
        return "Binding: $($Binding.title) (no Playnite match)"
    }
    return "No match - needs allowlist"
}

function ConvertTo-BypassLauncherModeDisplayName {
    param([string]$LauncherMode)
    switch ($LauncherMode) {
        'HelperAndApp' { return 'Helper + app' }
        'CustomScript' { return 'Custom script' }
        default { return 'App only' }
    }
}

function ConvertFrom-BypassLauncherModeDisplayName {
    param([string]$DisplayName)
    switch ($DisplayName) {
        'Helper + app' { return 'HelperAndApp' }
        'Custom script' { return 'CustomScript' }
        default { return 'AppOnly' }
    }
}

function Find-BypassBindingForShortcutRow {
    param(
        [object[]]$Bindings,
        [string]$LnkPath
    )

    foreach ($b in @($Bindings)) {
        if ($null -eq $b) { continue }
        if ($b.shortcutLnkPath -and $b.shortcutLnkPath -ieq $LnkPath) { return $b }
        if ($b.launchPath -and $b.launchPath -ieq $LnkPath) { return $b }
    }
    return $null
}

function Test-BypassPathUnderBypassesRoot {
    param(
        [string]$Path,
        [string]$BypassesPath
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($BypassesPath)) {
        return $false
    }
    if (-not (Test-BypassPathLiteral -Path $Path) -or -not (Test-BypassPathLiteral -Path $BypassesPath)) {
        return $false
    }

    $full = [System.IO.Path]::GetFullPath($Path.Trim())
    $root = [System.IO.Path]::GetFullPath($BypassesPath.Trim())
    if (-not $root.EndsWith('\')) {
        $root += '\'
    }
    return $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
}

function Get-BypassLauncherPaths {
    param(
        [string]$BypassesPath,
        [string]$DisplayName
    )

    $safe = Sanitize-BypassShortcutFileName -Name $DisplayName
    if ([string]::IsNullOrWhiteSpace($safe)) {
        throw 'Display name is required for launcher script paths.'
    }

    $ps1Path = Join-Path $BypassesPath "$safe.ps1"
    $cmdPath = Join-Path $BypassesPath "$safe.cmd"
    return [PSCustomObject]@{
        Ps1Path  = $ps1Path
        CmdPath  = $cmdPath
        PlayPath = $cmdPath
    }
}

function New-BypassLauncherCmdWrapper {
    param(
        [string]$Ps1Path,
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $Ps1Path)) {
        throw "Launcher script not found: $Ps1Path"
    }

    $cmdPath = [System.IO.Path]::ChangeExtension($Ps1Path, '.cmd')
    $ps1Name = [System.IO.Path]::GetFileName($Ps1Path)
    $cmdContent = @"
@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0$ps1Name"
"@
    Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII
    if ($LogAction) { & $LogAction "Wrote launcher wrapper: $cmdPath" }
    return $cmdPath
}

function Resolve-BypassShortcutLnkPathOnDisk {
    param(
        [string]$ShortcutLnkPath,
        [string]$BypassesPath,
        [string]$DisplayName = ""
    )

    if (Test-BypassPathLiteral -Path $ShortcutLnkPath) {
        return $ShortcutLnkPath
    }

    if (-not [string]::IsNullOrWhiteSpace($DisplayName) -and -not [string]::IsNullOrWhiteSpace($BypassesPath)) {
        $safe = Sanitize-BypassShortcutFileName -Name $DisplayName
        if (-not [string]::IsNullOrWhiteSpace($safe)) {
            $byDisplay = Join-Path $BypassesPath "$safe.lnk"
            if (Test-BypassPathLiteral -Path $byDisplay) {
                return $byDisplay
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BypassesPath)) {
        $leaf = [System.IO.Path]::GetFileName($ShortcutLnkPath)
        if ($leaf) {
            $byLeaf = Join-Path $BypassesPath $leaf
            if (Test-BypassPathLiteral -Path $byLeaf) {
                return $byLeaf
            }
        }
    }

    return $ShortcutLnkPath
}

function New-BypassShortcutCmdWrapper {
    param(
        [string]$BypassesPath,
        [string]$DisplayName,
        [string]$ShortcutLnkPath,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($BypassesPath)) {
        throw 'BypassesPath is required for shortcut launcher wrapper.'
    }

    $resolvedLnk = Resolve-BypassShortcutLnkPathOnDisk `
        -ShortcutLnkPath $ShortcutLnkPath `
        -BypassesPath $BypassesPath `
        -DisplayName $DisplayName
    if (-not (Test-BypassPathLiteral -Path $resolvedLnk)) {
        throw "Shortcut not found: $ShortcutLnkPath"
    }

    $paths = Get-BypassLauncherPaths -BypassesPath $BypassesPath -DisplayName $DisplayName
    $cmdContent = @"
@echo off
start "" "$resolvedLnk"
"@
    Set-Content -LiteralPath $paths.CmdPath -Value $cmdContent -Encoding ASCII
    if ($LogAction) { & $LogAction "Wrote shortcut launcher wrapper: $($paths.CmdPath) -> $resolvedLnk" }
    return $paths.CmdPath
}

function New-BypassCompositeLauncherScript {
    param(
        [string]$BypassesPath,
        [string]$DisplayName,
        [string]$HelperPath,
        [string]$ShortcutLnkPath,
        [int]$HelperDelaySec = 2,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($BypassesPath)) {
        throw 'BypassesPath is required for composite launcher generation.'
    }
    if (-not (Test-Path -LiteralPath $BypassesPath)) {
        New-Item -ItemType Directory -Path $BypassesPath -Force | Out-Null
    }

    $paths = Get-BypassLauncherPaths -BypassesPath $BypassesPath -DisplayName $DisplayName
    $helperEscaped = $HelperPath.Replace("'", "''")
    $shortcutEscaped = $ShortcutLnkPath.Replace("'", "''")

    $ps1Content = @"
# Generated by Sync-PlayniteBypassShortcuts - do not edit by hand
param(`$HelperDelaySec = $HelperDelaySec)
`$helper = '$helperEscaped'
`$shortcut = '$shortcutEscaped'
if (`$helper -and (Test-Path -LiteralPath `$helper)) {
    Start-Process -FilePath `$helper -WindowStyle Hidden
    Start-Sleep -Seconds `$HelperDelaySec
}
if (`$shortcut -and (Test-Path -LiteralPath `$shortcut)) {
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'start', '""', `$shortcut
}
else {
    throw "Shortcut not found: `$shortcut"
}
"@
    Set-Content -LiteralPath $paths.Ps1Path -Value $ps1Content -Encoding UTF8
    New-BypassLauncherCmdWrapper -Ps1Path $paths.Ps1Path -LogAction $LogAction | Out-Null

    if ($LogAction) {
        & $LogAction "Wrote composite launcher: $($paths.Ps1Path) -> $($paths.CmdPath)"
    }

    return $paths
}

function Resolve-BypassPlayniteLaunchPath {
    param(
        [string]$LauncherMode,
        [string]$BypassesPath,
        [string]$DisplayName,
        [string]$OriginalLnkPath,
        [string]$CustomScriptPath = ""
    )

    switch ($LauncherMode) {
        'HelperAndApp' {
            return (Get-BypassLauncherPaths -BypassesPath $BypassesPath -DisplayName $DisplayName).CmdPath
        }
        'CustomScript' {
            if ([string]::IsNullOrWhiteSpace($CustomScriptPath)) {
                throw 'Custom script path is required.'
            }
            if (-not (Test-BypassPathUnderBypassesRoot -Path $CustomScriptPath -BypassesPath $BypassesPath)) {
                throw "Custom script must be under Game Shortcuts: $CustomScriptPath"
            }
            $ext = [System.IO.Path]::GetExtension($CustomScriptPath).ToLowerInvariant()
            if ($ext -eq '.ps1') {
                return (New-BypassLauncherCmdWrapper -Ps1Path $CustomScriptPath)
            }
            return $CustomScriptPath
        }
        default {
            return (New-BypassShortcutCmdWrapper `
                -BypassesPath $BypassesPath `
                -DisplayName $DisplayName `
                -ShortcutLnkPath $OriginalLnkPath)
        }
    }
}

Export-ModuleMember -Function *
