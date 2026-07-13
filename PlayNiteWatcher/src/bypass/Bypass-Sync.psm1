#Requires -Version 5.1
<#
    Review and sync logic for bypass shortcuts.
    Dot-sourced from Playnite-Common.ps1.
#>

$script:_moduleRoot = $PSScriptRoot

function Resolve-BypassReviewedRowLauncher {
    param(
        [object]$Row,
        [string]$BypassesPath,
        [string]$DisplayName,
        [string]$ShortcutLnkPath,
        [scriptblock]$LogAction
    )

    $helperPath = if ($Row.HelperPath) { $Row.HelperPath.Trim() } else { "" }
    $helperDelaySec = if ($Row.HelperDelaySec) { [int]$Row.HelperDelaySec } else { 2 }
    $launcherScript = ""
    $playLaunchPath = ""
    $exeLeaf = if ($Row.SuggestedExe) { $Row.SuggestedExe } else { "" }
    $launcherMode = 'AppOnly'
    $resolvedLnk = Resolve-BypassShortcutLnkPathOnDisk `
        -ShortcutLnkPath $ShortcutLnkPath `
        -BypassesPath $BypassesPath `
        -DisplayName $DisplayName

    if (-not [string]::IsNullOrWhiteSpace($helperPath)) {
        $launcherMode = 'HelperAndApp'
        if (-not (Test-BypassPathLiteral -Path $helperPath)) {
            if ($LogAction) { & $LogAction "Skip composite launch (helper not found): $helperPath" "WARN" }
            return [PSCustomObject]@{ Skipped = $true }
        }
        if (-not (Test-BypassPathLiteral -Path $resolvedLnk)) {
            if ($LogAction) { & $LogAction "Skip composite launch (shortcut not found): $ShortcutLnkPath" "WARN" }
            return [PSCustomObject]@{ Skipped = $true }
        }

        $paths = New-BypassCompositeLauncherScript `
            -BypassesPath $BypassesPath `
            -DisplayName $DisplayName `
            -HelperPath $helperPath `
            -ShortcutLnkPath $resolvedLnk `
            -HelperDelaySec $helperDelaySec `
            -LogAction $LogAction
        $playLaunchPath = $paths.CmdPath
        $launcherScript = $paths.Ps1Path
        $ShortcutLnkPath = $resolvedLnk
    }
    else {
        if (-not (Test-BypassPathLiteral -Path $resolvedLnk)) {
            if ($LogAction) { & $LogAction "Skip shortcut wrapper (.lnk not found): $ShortcutLnkPath" "WARN" }
            return [PSCustomObject]@{ Skipped = $true }
        }

        $ShortcutLnkPath = $resolvedLnk
        $playLaunchPath = New-BypassShortcutCmdWrapper `
            -BypassesPath $BypassesPath `
            -DisplayName $DisplayName `
            -ShortcutLnkPath $resolvedLnk `
            -LogAction $LogAction
    }

    return [PSCustomObject]@{
        Skipped         = $false
        PlayLaunchPath  = $playLaunchPath
        ShortcutLnkPath = $ShortcutLnkPath
        LauncherMode    = $launcherMode
        LauncherScript  = $launcherScript
        HelperPath      = $helperPath
        HelperDelaySec  = $helperDelaySec
        ExeLeaf         = $exeLeaf
    }
}

function Get-BypassShortcutReviewRow {
    param(
        [string]$LnkPath,
        [string]$RepoRoot,
        [string]$InstallDir,
        [object]$Config,
        [object[]]$Games = @()
    )

    $info = Get-ShortcutLaunchInfo -LnkPath $LnkPath
    if (-not $info) {
        return $null
    }

    $bindings = @($Config.bindings)
    $binding = Find-BypassBindingForShortcutRow -Bindings $bindings -LnkPath $LnkPath

    $title = $info.Name
    $exePath = $info.TargetPath
    $gamePath = ""
    if (Test-ShortcutLooksLikeRunAsTool -ShortcutInfo $info) {
        if ($binding -and $binding.gamePath) {
            $gamePath = $binding.gamePath
            $exePath = [System.IO.Path]::GetFileName($binding.gamePath)
        }
        elseif ($binding -and $binding.exe -and $binding.exe -notmatch '(?i)runastool') {
            $exePath = $binding.exe
        }
    }
    elseif ($binding -and $binding.gamePath) {
        $gamePath = $binding.gamePath
        $exePath = [System.IO.Path]::GetFileName($binding.gamePath)
    }

    $exeLeaf = if ($exePath -match '\.exe$') { [System.IO.Path]::GetFileName($exePath) } elseif ($gamePath) { [System.IO.Path]::GetFileName($gamePath) } else { if ($binding) { $binding.exe } else { "" } }

    $Games = Normalize-PlayniteGamesArray -Games $Games
    if ($Games.Count -eq 0) {
        $Games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -StopPlayniteFirst)
    }

    $playniteMatch = $null
    if ($binding -and $binding.playniteId) {
        $playniteMatch = Find-PlayniteGameForBypassShortcut -Games $Games -PlayniteId $binding.playniteId
    }
    if (-not $playniteMatch) {
        $playniteMatch = Find-PlayniteGameForBypassShortcut -Games $Games -ExePath $exePath -Title $title -Bindings @($binding)
    }

    $playniteMatch = Get-SinglePlayniteGameRecord -Game $playniteMatch
    $displayName = if ($binding -and $binding.title) { $binding.title } elseif ($playniteMatch) { $playniteMatch.Name } else { $title }
    $storeGame = Get-SinglePlayniteGameRecord -Game (Find-PlayniteStoreGameForBypassShortcut -Games $Games -Title $displayName -PreferredId $(if ($binding) { $binding.playniteId } elseif ($playniteMatch) { $playniteMatch.Id } else { "" }))
    $classifyGame = if ($storeGame) { $storeGame } else { $playniteMatch }

    $allowlistMatch = Find-AllowlistEntryByExeOrTitle -RepoRoot $RepoRoot -Exe $exeLeaf -Title $title
    if (-not $allowlistMatch -and $binding -and $binding.nameId) {
        try {
            $allowlist = Get-DesktopAppAllowlist -RepoRoot $RepoRoot
            $allowlistMatch = $allowlist | Where-Object { $_.NameId -ieq $binding.nameId } | Select-Object -First 1
        }
        catch { }
    }

    $syncType = Get-BypassShortcutSyncTypeFromGame -PlayniteGame $classifyGame -AllowlistMatch $allowlistMatch
    $hint = Get-BypassShortcutReviewHint -PlayniteGame $classifyGame -AllowlistMatch $allowlistMatch -Binding $binding

    $titleDupes = Get-PlayniteGamesMatchingTitle -Games $Games -Title $displayName
    if ($titleDupes.Count -gt 1) {
        $hint += " | $($titleDupes.Count) Playnite entries with this name (launch path will update one existing row)"
    }

    $suggestedNameId = ""
    $suggestedType = "ThirdParty"
    if ($allowlistMatch) {
        $suggestedNameId = $allowlistMatch.NameId
        $suggestedType = $allowlistMatch.Type
    }
    elseif ($binding -and $binding.nameId) {
        $suggestedNameId = $binding.nameId
    }

    $displayName = if ($binding -and $binding.title) { $binding.title } elseif ($allowlistMatch) { $allowlistMatch.Title } elseif ($classifyGame) { $classifyGame.Name } else { $title }

    $launcherMode = if ($binding -and $binding.launcherMode -eq 'HelperAndApp' -and $binding.helperPath) {
        'HelperAndApp'
    }
    elseif ($binding -and $binding.helperPath) {
        'HelperAndApp'
    }
    else {
        'AppOnly'
    }
    $helperPath = if ($binding -and $binding.helperPath) { $binding.helperPath } else { "" }
    $helperDelaySec = if ($binding -and $binding.helperDelaySec) { [int]$binding.helperDelaySec } else { 2 }

    return [PSCustomObject]@{
        OriginalLnkPath     = $LnkPath
        FileName            = [System.IO.Path]::GetFileName($LnkPath)
        DisplayName         = $displayName
        SyncType            = $syncType
        SuggestedPlayniteId = if ($storeGame) { $storeGame.Id } elseif ($playniteMatch) { $playniteMatch.Id } else { "" }
        SuggestedNameId     = $suggestedNameId
        SuggestedExe       = $exeLeaf
        SuggestedType      = $suggestedType
        Hint                = $hint
        IsNewDesktopApp     = ($syncType -eq 'InAllowlist' -and -not $allowlistMatch -and [string]::IsNullOrWhiteSpace($suggestedNameId))
        HelperPath          = $helperPath
        HelperDelaySec      = $helperDelaySec
    }
}

function Get-BypassShortcutReviewRowsFromFolder {
    param(
        [string]$BypassesPath,
        [string]$RepoRoot,
        [string]$InstallDir,
        [object]$Config,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($BypassesPath) -or -not (Test-Path -LiteralPath $BypassesPath)) {
        throw "Game Shortcuts folder not found: $BypassesPath"
    }

    $lnks = @(Get-ChildItem -LiteralPath $BypassesPath -Filter "*.lnk" -File -ErrorAction SilentlyContinue | Sort-Object Name)
    $games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -StopPlayniteFirst -LogAction $LogAction)
    $rows = @()

    foreach ($lnk in $lnks) {
        $row = Get-BypassShortcutReviewRow -LnkPath $lnk.FullName -RepoRoot $RepoRoot -InstallDir $InstallDir -Config $Config -Games $games
        if ($row) {
            $rows += $row
        }
    }

    return $rows
}

function Invoke-BypassShortcutReviewSync {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [string]$BypassesPath,
        [object[]]$ReviewedRows,
        [scriptblock]$LogAction
    )

    $stats = @{ Added = 0; Updated = 0; Skipped = 0; Renamed = 0; Errors = 0; DuplicateNotices = @() }

    foreach ($row in @($ReviewedRows)) {
        try {
            $displayName = Sanitize-BypassShortcutFileName -Name $row.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                if ($LogAction) { & $LogAction "Skip (empty display name): $($row.FileName)" "WARN" }
                $stats.Skipped++
                continue
            }

            $launchPath = $row.OriginalLnkPath
            $targetLnk = Join-Path $BypassesPath "$displayName.lnk"

            if ($launchPath -ine $targetLnk) {
                if (Test-Path -LiteralPath $targetLnk) {
                    if ($LogAction) { & $LogAction "Skip rename (target exists): $displayName.lnk" "WARN" }
                    $stats.Skipped++
                    continue
                }
                Rename-Item -LiteralPath $launchPath -NewName "$displayName.lnk" -Force
                $launchPath = $targetLnk
                $stats.Renamed++
                if ($LogAction) { & $LogAction "Renamed shortcut -> $displayName.lnk" }
            }

            $launcherResult = Resolve-BypassReviewedRowLauncher `
                -Row $row `
                -BypassesPath $BypassesPath `
                -DisplayName $displayName `
                -ShortcutLnkPath $launchPath `
                -LogAction $LogAction
            if ($launcherResult.Skipped) {
                $stats.Skipped++
                continue
            }

            $playLaunchPath = $launcherResult.PlayLaunchPath
            $launcherSyncParams = @{
                LauncherMode    = $launcherResult.LauncherMode
                LauncherScript  = $launcherResult.LauncherScript
                HelperPath      = $launcherResult.HelperPath
                ShortcutLnkPath = $launcherResult.ShortcutLnkPath
            }

            $syncType = $row.SyncType
            if ($syncType -ne 'OutsideAllowlist' -and $syncType -ne 'InAllowlist') {
                $syncType = 'InAllowlist'
            }

            if ($syncType -eq 'OutsideAllowlist') {
                $games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -StopPlayniteFirst -LogAction $LogAction)
                $storeGame = Find-PlayniteStoreGameForBypassShortcut -Games $games -Title $displayName -PreferredId $row.SuggestedPlayniteId
                if (-not $storeGame) {
                    if ($LogAction) { & $LogAction "Skip Outside allowlist (no Steam/Epic match): $displayName" "WARN" }
                    $stats.Skipped++
                    continue
                }

                $syncResult = Sync-PlayniteBypassBindingToLibrary `
                    -InstallDir $InstallDir `
                    -RepoRoot $RepoRoot `
                    -LaunchPath $playLaunchPath `
                    -Exe $(if ($launcherResult.ExeLeaf) { $launcherResult.ExeLeaf } elseif ($row.SuggestedExe) { $row.SuggestedExe } else { "game.exe" }) `
                    -Title $displayName `
                    -NameId "" `
                    -Type "ThirdParty" `
                    -NameIdInput "" `
                    -IsNewApp $false `
                    -ExistingPlayniteId $storeGame.Id `
                    -OutsideAllowlist `
                    @launcherSyncParams `
                    -LogAction $LogAction

                if ($syncResult.Action -eq 'Added') { $stats.Added++ } else { $stats.Updated++ }
                if ($syncResult.DuplicateNotice) {
                    $stats.DuplicateNotices += $syncResult.DuplicateNotice
                }
                continue
            }
            $exeLeaf = if ($launcherResult.ExeLeaf) { $launcherResult.ExeLeaf } else { $row.SuggestedExe }
            $title = $displayName
            $type = $row.SuggestedType
            $nameId = $row.SuggestedNameId
            $nameIdInput = ""
            $isNewApp = $false
            $existingPlayniteId = $row.SuggestedPlayniteId

            $allowlistMatch = Find-AllowlistEntryByExeOrTitle -RepoRoot $RepoRoot -Exe $exeLeaf -Title $title
            if ($allowlistMatch) {
                $nameId = $allowlistMatch.NameId
                $type = $allowlistMatch.Type
                $title = $allowlistMatch.Title
                $exeLeaf = $allowlistMatch.Exe
            }
            elseif ($row.IsNewDesktopApp -or [string]::IsNullOrWhiteSpace($nameId)) {
                $defaultExe = $exeLeaf
                $addForm = Show-BypassAddAppForm -DefaultExe $defaultExe -DefaultTitle $title -DefaultType $type
                if (-not $addForm) {
                    if ($LogAction) { & $LogAction "Skip (allowlist form cancelled): $displayName" "WARN" }
                    $stats.Skipped++
                    continue
                }
                $exeLeaf = $addForm.Exe
                $title = $addForm.Title
                $type = $addForm.Type
                $nameIdInput = $addForm.NameIdInput
                $nameId = $addForm.NameId
                $isNewApp = $true
            }

            if ([string]::IsNullOrWhiteSpace($exeLeaf)) {
                if ($LogAction) { & $LogAction "Skip In allowlist (executable unknown): $displayName" "WARN" }
                $stats.Skipped++
                continue
            }

            $syncResult = Sync-PlayniteBypassBindingToLibrary `
                -InstallDir $InstallDir `
                -RepoRoot $RepoRoot `
                -LaunchPath $playLaunchPath `
                -Exe $exeLeaf `
                -Title $title `
                -NameId $nameId `
                -Type $type `
                -NameIdInput $nameIdInput `
                -IsNewApp $isNewApp `
                -ExistingPlayniteId $existingPlayniteId `
                @launcherSyncParams `
                -LogAction $LogAction

            if ($syncResult.Action -eq 'Added') { $stats.Added++ } else { $stats.Updated++ }
            if ($syncResult.DuplicateNotice) {
                $stats.DuplicateNotices += $syncResult.DuplicateNotice
            }
        }
        catch {
            $stats.Errors++
            if ($LogAction) { & $LogAction "Error syncing $($row.FileName): $($_.Exception.Message)" "ERROR" }
        }
    }

    return $stats
}

function Invoke-PlayniteBypassShortcutsSyncFromFolder {
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

    $lnks = @(Get-ChildItem -LiteralPath $bypassRoot -Filter "*.lnk" -File -ErrorAction SilentlyContinue)
    $stats = @{ Updated = 0; Skipped = 0; Missing = 0 }
    $processedShortcutLnks = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($binding in @($config.bindings)) {
        if (-not $binding -or -not $binding.launchPath) { continue }

        $bindingLaunchPath = $binding.launchPath
        $launchExt = [System.IO.Path]::GetExtension($binding.launchPath).ToLowerInvariant()
        if ($launchExt -eq '.lnk') {
            $shortcutLnk = $binding.launchPath
            if ($binding.shortcutLnkPath) {
                $shortcutLnk = $binding.shortcutLnkPath
            }
            $displayName = if ($binding.title) { $binding.title } else { [System.IO.Path]::GetFileNameWithoutExtension($shortcutLnk) }
            $displayName = Sanitize-BypassShortcutFileName -Name $displayName
            if (-not [string]::IsNullOrWhiteSpace($displayName) -and -not $WhatIf) {
                try {
                    $bindingLaunchPath = New-BypassShortcutCmdWrapper `
                        -BypassesPath $bypassRoot `
                        -DisplayName $displayName `
                        -ShortcutLnkPath $shortcutLnk `
                        -LogAction $LogAction
                }
                catch {
                    if ($LogAction) { & $LogAction "SyncOnly shortcut wrapper failed: $($binding.title) - $($_.Exception.Message)" "WARN" }
                    continue
                }
            }
            else {
                $bindingLaunchPath = $binding.launchPath
            }
        }
        elseif ($launchExt -notin @('.cmd', '.bat', '.ps1')) {
            continue
        }

        if ($binding.launcherMode -eq 'HelperAndApp' -and $binding.helperPath -and $binding.shortcutLnkPath) {
            $displayName = if ($binding.title) { $binding.title } else { [System.IO.Path]::GetFileNameWithoutExtension($binding.launchPath) }
            $displayName = Sanitize-BypassShortcutFileName -Name $displayName
            if (-not [string]::IsNullOrWhiteSpace($displayName)) {
                try {
                    if (-not $WhatIf) {
                        $paths = New-BypassCompositeLauncherScript `
                            -BypassesPath $bypassRoot `
                            -DisplayName $displayName `
                            -HelperPath $binding.helperPath `
                            -ShortcutLnkPath $binding.shortcutLnkPath `
                            -HelperDelaySec $(if ($binding.helperDelaySec) { [int]$binding.helperDelaySec } else { 2 }) `
                            -LogAction $LogAction
                        $bindingLaunchPath = $paths.CmdPath
                    }
                }
                catch {
                    if ($LogAction) { & $LogAction "SyncOnly launcher regen failed: $($binding.title) - $($_.Exception.Message)" "WARN" }
                }
            }
        }
        elseif ($launchExt -eq '.ps1') {
            if (-not $WhatIf) {
                $bindingLaunchPath = New-BypassLauncherCmdWrapper -Ps1Path $binding.launchPath -LogAction $LogAction
            }
        }
        elseif ($binding.launcherMode -eq 'AppOnly' -and $binding.shortcutLnkPath -and $launchExt -eq '.cmd') {
            $displayName = if ($binding.title) { $binding.title } else { [System.IO.Path]::GetFileNameWithoutExtension($binding.shortcutLnkPath) }
            $displayName = Sanitize-BypassShortcutFileName -Name $displayName
            if (-not [string]::IsNullOrWhiteSpace($displayName) -and -not $WhatIf) {
                try {
                    $bindingLaunchPath = New-BypassShortcutCmdWrapper `
                        -BypassesPath $bypassRoot `
                        -DisplayName $displayName `
                        -ShortcutLnkPath $binding.shortcutLnkPath `
                        -LogAction $LogAction
                }
                catch {
                    if ($LogAction) { & $LogAction "SyncOnly shortcut wrapper regen failed: $($binding.title) - $($_.Exception.Message)" "WARN" }
                }
            }
        }

        $bindingLaunchPath = if ($bindingLaunchPath) { $bindingLaunchPath } else { $binding.launchPath }

        if (-not $WhatIf -and -not (Test-Path -LiteralPath $bindingLaunchPath)) {
            $stats.Missing++
            if ($LogAction) { & $LogAction "SyncOnly skip (launcher missing): $bindingLaunchPath" "WARN" }
            continue
        }

        $exePath = if ($binding.exe) { $binding.exe } else { "" }
        $title = if ($binding.title) { $binding.title } else { [System.IO.Path]::GetFileNameWithoutExtension($bindingLaunchPath) }
        $exists = Test-PlayniteOrAllowlistExistsForBypassApp -RepoRoot $RepoRoot -InstallDir $InstallDir -ExePath $exePath -Title $title
        if (-not $exists.Exists) {
            $stats.Missing++
            if ($LogAction) { & $LogAction "SyncOnly skip (no Playnite/allowlist match): $title" "WARN" }
            continue
        }

        if ($WhatIf) {
            if ($LogAction) { & $LogAction "Would sync launcher binding: $bindingLaunchPath" }
            continue
        }

        $allow = $exists.AllowlistMatch
        $nameId = if ($allow) { $allow.NameId } elseif ($binding.nameId) { $binding.nameId } else { "" }
        $type = if ($allow) { $allow.Type } else { "ThirdParty" }
        $exeLeaf = if ($binding.exe) { $binding.exe } elseif ($exePath -match '\.exe$') { [System.IO.Path]::GetFileName($exePath) } elseif ($allow) { $allow.Exe } else { "" }

        $useOutside = $false
        if ($binding.syncType -eq 'OutsideAllowlist') {
            $useOutside = $true
        }
        elseif ($exists.PlayniteMatch -and (Test-PlayniteGameIsStoreLibrary -Game $exists.PlayniteMatch)) {
            $useOutside = $true
        }

        $launcherScriptVal = if ($binding.launcherScript) { $binding.launcherScript } else { '' }
        $helperPathVal = if ($binding.helperPath) { $binding.helperPath } else { '' }
        $shortcutLnkVal = if ($binding.shortcutLnkPath) { $binding.shortcutLnkPath } else { '' }
        $launcherSyncParams = @{
            LauncherMode    = $(if ($binding.launcherMode) { $binding.launcherMode } else { 'CustomScript' })
            LauncherScript  = $launcherScriptVal
            HelperPath      = $helperPathVal
            ShortcutLnkPath = $shortcutLnkVal
        }

        $existingId = if ($binding.playniteId) { $binding.playniteId } elseif ($exists.PlayniteMatch) { $exists.PlayniteMatch.Id } else { '' }
        $syncParams = @{
            InstallDir         = $InstallDir
            RepoRoot           = $RepoRoot
            LaunchPath         = $bindingLaunchPath
            Exe                = $exeLeaf
            Title              = $title
            NameId             = $nameId
            Type               = $type
            NameIdInput        = ""
            IsNewApp           = $false
            ExistingPlayniteId = $existingId
            LogAction          = $LogAction
        }
        $syncParams += $launcherSyncParams

        if ($useOutside) {
            Sync-PlayniteBypassBindingToLibrary @syncParams -OutsideAllowlist | Out-Null
        }
        else {
            Sync-PlayniteBypassBindingToLibrary @syncParams | Out-Null
        }

        if ($binding.shortcutLnkPath) {
            [void]$processedShortcutLnks.Add($binding.shortcutLnkPath)
        }
        $stats.Updated++
    }

    foreach ($lnk in $lnks) {
        if ($processedShortcutLnks.Contains($lnk.FullName)) {
            continue
        }

        $binding = Find-BypassBindingForShortcutRow -Bindings @($config.bindings) -LnkPath $lnk.FullName
        if ($binding -and $binding.launcherMode -in @('HelperAndApp', 'CustomScript')) {
            $bindingExt = [System.IO.Path]::GetExtension($binding.launchPath).ToLowerInvariant()
            if ($bindingExt -in @('.cmd', '.bat', '.ps1')) {
                continue
            }
        }

        $info = Get-ShortcutLaunchInfo -LnkPath $lnk.FullName
        $exePath = $info.TargetPath
        if (Test-ShortcutLooksLikeRunAsTool -ShortcutInfo $info) {
            if ($binding -and $binding.gamePath) {
                $exePath = [System.IO.Path]::GetFileName($binding.gamePath)
            }
            elseif ($binding -and $binding.exe -and $binding.exe -notmatch '(?i)runastool') {
                $exePath = $binding.exe
            }
        }

        $title = $info.Name
        $exists = Test-PlayniteOrAllowlistExistsForBypassApp -RepoRoot $RepoRoot -InstallDir $InstallDir -ExePath $exePath -Title $title
        if (-not $exists.Exists) {
            $stats.Missing++
            if ($LogAction) { & $LogAction "SyncOnly skip (no Playnite/allowlist match): $($lnk.Name)" "WARN" }
            continue
        }

        if ($WhatIf) {
            if ($LogAction) { & $LogAction "Would sync: $($lnk.FullName)" }
            continue
        }

        $allow = $exists.AllowlistMatch
        $syncTitle = if ($binding -and $binding.title) { $binding.title } elseif ($allow) { $allow.Title } else { $info.Name }
        $syncTitle = Sanitize-BypassShortcutFileName -Name $syncTitle
        if ([string]::IsNullOrWhiteSpace($syncTitle)) {
            $syncTitle = [System.IO.Path]::GetFileNameWithoutExtension($lnk.Name)
        }

        try {
            $playLaunchPath = New-BypassShortcutCmdWrapper `
                -BypassesPath $bypassRoot `
                -DisplayName $syncTitle `
                -ShortcutLnkPath $lnk.FullName `
                -LogAction $LogAction
        }
        catch {
            $stats.Missing++
            if ($LogAction) { & $LogAction "SyncOnly skip (shortcut wrapper failed): $($lnk.Name) - $($_.Exception.Message)" "WARN" }
            continue
        }

        $nameId = if ($allow) { $allow.NameId } else { "" }
        $type = if ($allow) { $allow.Type } else { "ThirdParty" }
        $exeLeaf = if ($exePath -match '\.exe$') { [System.IO.Path]::GetFileName($exePath) } elseif ($allow) { $allow.Exe } else { if ($binding) { $binding.exe } else { "" } }

        $useOutside = $false
        if ($binding -and $binding.syncType -eq 'OutsideAllowlist') {
            $useOutside = $true
        }
        elseif ($exists.PlayniteMatch -and (Test-PlayniteGameIsStoreLibrary -Game $exists.PlayniteMatch)) {
            $useOutside = $true
        }

        $launcherScriptVal = if ($binding -and $binding.launcherScript) { $binding.launcherScript } else { '' }
        $helperPathVal = if ($binding -and $binding.helperPath) { $binding.helperPath } else { '' }
        $launcherSyncParams = @{
            LauncherMode    = $(if ($binding -and $binding.launcherMode) { $binding.launcherMode } else { 'AppOnly' })
            LauncherScript  = $launcherScriptVal
            HelperPath      = $helperPathVal
            ShortcutLnkPath = $lnk.FullName
        }

        $existingId = if ($binding -and $binding.playniteId) { $binding.playniteId } elseif ($exists.PlayniteMatch) { $exists.PlayniteMatch.Id } else { '' }
        $syncParams = @{
            InstallDir         = $InstallDir
            RepoRoot           = $RepoRoot
            LaunchPath         = $playLaunchPath
            Exe                = $exeLeaf
            Title              = $(if ($binding -and $binding.title) { $binding.title } elseif ($allow) { $allow.Title } else { $title })
            NameId             = $nameId
            Type               = $type
            NameIdInput        = ""
            IsNewApp           = $false
            ExistingPlayniteId = $existingId
            LogAction          = $LogAction
        }
        $syncParams += $launcherSyncParams

        if ($useOutside) {
            Sync-PlayniteBypassBindingToLibrary @syncParams -OutsideAllowlist | Out-Null
        }
        else {
            Sync-PlayniteBypassBindingToLibrary @syncParams | Out-Null
        }
        $stats.Updated++
    }

    return $stats
}

function Get-NextGpuBypassBindingsPlaynitePath {
    param([string]$InstallDir)
    return Join-Path $InstallDir 'ExtensionsData\NextGPU\bypass-bindings.json'
}

function Publish-NextGpuBypassBindingsToPlaynite {
    param(
        [string]$InstallDir,
        [object]$Config
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir) -or -not $Config) {
        return
    }

    $outBindings = @()
    foreach ($b in @($Config.bindings)) {
        if ($null -eq $b -or [string]::IsNullOrWhiteSpace($b.launchPath)) {
            continue
        }
        $outBindings += [PSCustomObject]@{
            playniteId = [string]$b.playniteId
            title      = [string]$b.title
            launchPath = [string]$b.launchPath
            syncType   = if ($b.syncType) { [string]$b.syncType } else { "InAllowlist" }
        }
    }

    $doc = [PSCustomObject]@{
        bypassesPath = [string]$Config.bypassesPath
        bindings     = $outBindings
        updatedAt    = (Get-Date).ToString("o")
    }

    $targetDir = Join-Path $InstallDir 'ExtensionsData\NextGPU'
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $path = Get-NextGpuBypassBindingsPlaynitePath -InstallDir $InstallDir
    ($doc | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
}

function Invoke-ReapplyPlayniteBypassShortcuts {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [scriptblock]$LogAction
    )

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $bypassRoot = $wrapper.Config.bypassesPath
    if ([string]::IsNullOrWhiteSpace($bypassRoot) -or -not (Test-Path -LiteralPath $bypassRoot)) {
        return
    }

    $lnkCount = @(Get-ChildItem -LiteralPath $bypassRoot -Filter "*.lnk" -File -ErrorAction SilentlyContinue).Count
    if ($lnkCount -eq 0) {
        return
    }

    if ($LogAction) {
        & $LogAction "Re-applying bypass shortcuts after library update ($lnkCount .lnk under $bypassRoot)..."
    }

    Invoke-PlayniteBypassShortcutsSyncFromFolder -InstallDir $InstallDir -RepoRoot $RepoRoot -BypassesPath $bypassRoot -LogAction $LogAction | Out-Null
}

function Invoke-ReapplyPlayniteBypassShortcutsAfterDesktopImport {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [scriptblock]$LogAction
    )

    Invoke-ReapplyPlayniteBypassShortcuts -InstallDir $InstallDir -RepoRoot $RepoRoot -LogAction $LogAction
}

function Initialize-BypassShortcutsFolder {
    param(
        [string]$ParentPath,
        [switch]$NoPrompt
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $parent = Get-NormalizedDirectoryPath -Path $ParentPath
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Parent path is required."
    }

    $bypassesPath = Resolve-GameShortcutsPathFromParent -ParentPath $parent
    if ([string]::IsNullOrWhiteSpace($bypassesPath)) {
        throw "Parent path is invalid."
    }

    $exists = Test-Path -LiteralPath $bypassesPath
    $lnkCount = 0
    if ($exists) {
        $lnkCount = @(Get-ChildItem -LiteralPath $bypassesPath -Filter "*.lnk" -File -ErrorAction SilentlyContinue).Count
    }

    if ($exists -and -not $NoPrompt) {
        $msg = "Game Shortcuts folder already exists:`n$bypassesPath"
        if ($lnkCount -gt 0) {
            $msg += "`n`nIt contains $lnkCount shortcut(s)."
        }
        $msg += "`n`nUse this folder?"
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $msg,
            "Game Shortcuts folder",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            return $null
        }
    }

    if (-not $exists) {
        New-Item -ItemType Directory -Path $bypassesPath -Force | Out-Null
    }

    return [PSCustomObject]@{
        ParentPath   = $parent
        BypassesPath = $bypassesPath
    }
}

function Get-DefaultBypassSeedRoot {
    return Join-Path $script:PlayNiteWatcherScriptRoot 'templates\bypass'
}

function Copy-BypassGameShortcutsSeed {
    param(
        [Parameter(Mandatory)]
        [string]$ShortcutsSeedPath,
        [Parameter(Mandatory)]
        [string]$BypassesPath,
        [switch]$NoPrompt,
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $ShortcutsSeedPath)) {
        throw "Shortcuts seed folder not found: $ShortcutsSeedPath"
    }

    $seedLnks = @(Get-ChildItem -LiteralPath $ShortcutsSeedPath -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
    $seedScripts = @(
        Get-ChildItem -LiteralPath $ShortcutsSeedPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $ShortcutsSeedPath -Filter '*.cmd' -File -ErrorAction SilentlyContinue
    )
    if ($seedLnks.Count -eq 0 -and $seedScripts.Count -eq 0) {
        throw "Shortcuts seed folder has no .lnk, .ps1, or .cmd files: $ShortcutsSeedPath"
    }

    if (-not (Test-Path -LiteralPath $BypassesPath)) {
        New-Item -ItemType Directory -Path $BypassesPath -Force | Out-Null
    }

    $destLnks = @(Get-ChildItem -LiteralPath $BypassesPath -Filter '*.lnk' -File -ErrorAction SilentlyContinue)
    $destScripts = @(
        Get-ChildItem -LiteralPath $BypassesPath -Filter '*.ps1' -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $BypassesPath -Filter '*.cmd' -File -ErrorAction SilentlyContinue
    )
    $seedTotal = $seedLnks.Count + $seedScripts.Count
    if (($destLnks.Count + $destScripts.Count) -gt 0 -and -not $NoPrompt) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $msg = "Game Shortcuts folder already contains $($destLnks.Count) shortcut(s) and $($destScripts.Count) launcher script(s):`n$BypassesPath`n`nCopy $seedTotal seed file(s) and overwrite matching names?"
        $choice = [System.Windows.Forms.MessageBox]::Show(
            $msg,
            'Copy seed shortcuts',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            if ($LogAction) { & $LogAction 'Seed shortcut copy cancelled by user.' 'WARN' }
            return [PSCustomObject]@{
                Copied  = 0
                Skipped = $seedTotal
            }
        }
    }

    $copied = 0
    foreach ($lnk in $seedLnks) {
        $dest = Join-Path $BypassesPath $lnk.Name
        Copy-Item -LiteralPath $lnk.FullName -Destination $dest -Force
        $copied++
        if ($LogAction) { & $LogAction "Copied seed shortcut: $($lnk.Name) -> $dest" }
    }
    foreach ($scriptFile in $seedScripts) {
        $dest = Join-Path $BypassesPath $scriptFile.Name
        Copy-Item -LiteralPath $scriptFile.FullName -Destination $dest -Force
        $copied++
        if ($LogAction) { & $LogAction "Copied seed launcher: $($scriptFile.Name) -> $dest" }
    }

    return [PSCustomObject]@{
        Copied  = $copied
        Skipped = ($seedTotal - $copied)
    }
}

Export-ModuleMember -Function *
