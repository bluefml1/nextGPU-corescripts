#Requires -Version 5.1
<#
    Bypass shortcut helpers for Playnite + RunAsTool integration.
    Dot-sourced from Playnite-Common.ps1.
#>

$script:BypassShortcutsConfigFileName = "bypass-shortcuts.json"
$script:BypassShortcutsTemplateFileName = "bypass-shortcuts.json.template"
$script:DefaultRunAsToolProgramDataDir = Join-Path $env:ProgramData "NextGPU\RunAsTool"
$script:DefaultBypassAdminUser = "NextGPU-Admin"
$script:DefaultGameShortcutsFolderName = 'Game Shortcuts'
$script:LegacyGameShortcutsFolderName = 'Bypasses'
$script:PlayNiteWatcherScriptRoot = $PSScriptRoot

function Get-DefaultGameShortcutsFolderName {
    return $script:DefaultGameShortcutsFolderName
}

function Resolve-GameShortcutsPathFromParent {
    param([string]$ParentPath)

    $parent = Get-NormalizedDirectoryPath -Path $ParentPath
    if ([string]::IsNullOrWhiteSpace($parent)) {
        return $null
    }

    $preferred = Join-Path $parent $script:DefaultGameShortcutsFolderName
    $legacy = Join-Path $parent $script:LegacyGameShortcutsFolderName

    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }
    if (Test-Path -LiteralPath $legacy) {
        return $legacy
    }

    return $preferred
}

function Get-PlayNiteWatcherScriptRoot {
    return $script:PlayNiteWatcherScriptRoot
}

function Get-DefaultRunAsToolInstallDir {
    return $script:DefaultRunAsToolProgramDataDir
}

function Get-BypassShortcutsConfigPath {
    param([string]$RepoRoot)
    return Join-Path $RepoRoot "config\playnite\$($script:BypassShortcutsConfigFileName)"
}

function Initialize-BypassShortcutsConfigFromTemplate {
    param([string]$RepoRoot)

    $target = Get-BypassShortcutsConfigPath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $target) {
        return $target
    }

    $template = Join-Path $RepoRoot "config\playnite\$($script:BypassShortcutsTemplateFileName)"
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Bypass shortcuts template not found: $template"
    }

    $dir = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Copy-Item -LiteralPath $template -Destination $target -Force
    return $target
}

function Get-BypassShortcutsConfig {
    param([string]$RepoRoot)

    $path = Initialize-BypassShortcutsConfigFromTemplate -RepoRoot $RepoRoot
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        $parsed = [PSCustomObject]@{}
    }
    if ($null -eq $parsed.bindings) {
        $parsed | Add-Member -NotePropertyName bindings -NotePropertyValue @() -Force
    }
    return [PSCustomObject]@{
        Path    = $path
        Config  = $parsed
    }
}

function Save-BypassShortcutsConfig {
    param(
        [string]$RepoRoot,
        [object]$Config
    )

    $path = Get-BypassShortcutsConfigPath -RepoRoot $RepoRoot
    if ($null -eq $Config.bindings) {
        $Config | Add-Member -NotePropertyName bindings -NotePropertyValue @() -Force
    }
    $Config.updatedAt = (Get-Date).ToString("o")
    ($Config | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-BypassBindingsFromConfig {
    param([object]$Config)
    if ($null -eq $Config -or $null -eq $Config.bindings) {
        return @()
    }
    return @($Config.bindings)
}

function Test-BypassPathLiteral {
    param([string]$Path)
    if ($null -eq $Path) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return Test-Path -LiteralPath $Path
}

function Resolve-BypassExecutablePath {
    param(
        [string]$ExePath,
        [string]$FallbackFullPath = ""
    )

    $candidate = if ($null -ne $ExePath) { $ExePath.Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($candidate) -and -not [string]::IsNullOrWhiteSpace($FallbackFullPath)) {
        $candidate = $FallbackFullPath.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw "Application executable path is required. Browse for the .exe in the bypass wizard."
    }

    $isRooted = ($candidate -match '^[A-Za-z]:[\\/]') -or ($candidate -match '^\\\\')
    if (-not $isRooted) {
        $fallback = if ($null -ne $FallbackFullPath) { $FallbackFullPath.Trim() } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($fallback) -and ($fallback -match '^[A-Za-z]:[\\/]' -or $fallback -match '^\\\\')) {
            $candidate = Join-Path (Split-Path -Path $fallback -Parent) ([System.IO.Path]::GetFileName($candidate))
        }
        else {
            throw "Executable must be a full path to an existing .exe (got '$candidate'). Use Browse to select the file again."
        }
    }

    if (-not (Test-BypassPathLiteral -Path $candidate)) {
        throw "Executable not found: $candidate"
    }

    return ([System.IO.Path]::GetFullPath($candidate))
}

function Start-RunAsToolApplication {
    param(
        [Parameter(Mandatory)]
        [string]$ExePath,
        [string]$WorkingDirectory = ""
    )

    if (-not (Test-BypassPathLiteral -Path $ExePath)) {
        throw "RunAsTool not found: $ExePath"
    }

    $workDir = $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($workDir)) {
        $workDir = Split-Path -Path $ExePath -Parent
    }

    $existing = Get-Process -Name "RunAsTool*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        try {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32RunAsToolFocus {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue
            [Win32RunAsToolFocus]::ShowWindow($existing.MainWindowHandle, 9) | Out-Null
            [Win32RunAsToolFocus]::SetForegroundWindow($existing.MainWindowHandle) | Out-Null
        }
        catch { }
        return $existing
    }

    return Start-Process -FilePath $ExePath -WorkingDirectory $workDir -PassThru
}

function Assert-BypassShortcutPaths {
    param(
        [string]$ExePath,
        [string]$BypassesPath,
        [string]$RunAsToolExe = "",
        [string]$LaunchPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        throw "Application executable path is required."
    }
    if ([string]::IsNullOrWhiteSpace($BypassesPath)) {
        throw "Game Shortcuts folder is not configured. Run Setup Bypass Folder first."
    }
    if (-not [string]::IsNullOrWhiteSpace($RunAsToolExe) -and -not (Test-BypassPathLiteral -Path $RunAsToolExe)) {
        throw "RunAsTool not found: $RunAsToolExe"
    }
    if (-not [string]::IsNullOrWhiteSpace($LaunchPath)) {
        $launchLeaf = Split-Path -Path $LaunchPath -Leaf
        if ([string]::IsNullOrWhiteSpace($launchLeaf)) {
            throw "Bypass shortcut path is invalid: $LaunchPath"
        }
    }
}

function Install-RunAsToolIfMissing {
    param(
        [string]$RepoRoot,
        [switch]$SkipDownload,
        [scriptblock]$LogAction
    )

    $watcherRoot = Get-PlayNiteWatcherScriptRoot
    $installScript = Join-Path $watcherRoot "Install-RunAsTool.ps1"
    if (-not (Test-Path -LiteralPath $installScript)) {
        return $null
    }

    $installArgs = @{
        RepoRoot  = $watcherRoot
        LogAction = $LogAction
    }
    if ($SkipDownload.IsPresent) {
        $installArgs['SkipDownload'] = $true
    }

    $result = & $installScript @installArgs
    if ($result.Path -and (Test-Path -LiteralPath $result.Path)) {
        return $result.Path
    }
    return $null
}

function Resolve-RunAsToolExe {
    param(
        [string]$RepoRoot,
        [string]$OverridePath = "",
        [switch]$InstallIfMissing
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath) -and (Test-Path -LiteralPath $OverridePath)) {
        return $OverridePath
    }

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $saved = $wrapper.Config.runAsToolExe
    if (-not [string]::IsNullOrWhiteSpace($saved) -and (Test-Path -LiteralPath $saved)) {
        return $saved
    }

    foreach ($candidate in @(
            (Join-Path $script:DefaultRunAsToolProgramDataDir "RunAsTool_x64.exe"),
            (Join-Path $script:DefaultRunAsToolProgramDataDir "RunAsTool.exe")
        )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $watcherRoot = Get-PlayNiteWatcherScriptRoot
    $bundled = @(
        (Join-Path $watcherRoot "tools\runastool\RunAsTool_x64.exe"),
        (Join-Path $watcherRoot "tools\runastool\RunAsTool.exe")
    )
    foreach ($candidate in $bundled) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    if ($InstallIfMissing) {
        $installed = Install-RunAsToolIfMissing -RepoRoot $RepoRoot
        if ($installed) {
            return $installed
        }
    }

    return $null
}

function Show-ResolveRunAsToolExeDialog {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "RunAsTool|RunAsTool.exe;RunAsTool_x64.exe|All files (*.*)|*.*"
    $dialog.Title = "Locate RunAsTool.exe"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    return $null
}

function Ensure-RunAsToolExeResolved {
    param(
        [string]$RepoRoot,
        [ref]$ConfigRef,
        [switch]$Launch,
        [scriptblock]$LogAction
    )

    $exe = Resolve-RunAsToolExe -RepoRoot $RepoRoot -OverridePath $ConfigRef.Value.runAsToolExe -InstallIfMissing
    if (-not $exe) {
        $exe = Install-RunAsToolIfMissing -RepoRoot $RepoRoot -LogAction $LogAction
    }

    if ($exe) {
        $ConfigRef.Value.runAsToolExe = $exe
        if ($Launch.IsPresent) {
            Start-RunAsToolApplication -ExePath $exe | Out-Null
        }
        return $exe
    }

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "RunAsTool is not installed and auto-download failed.`n`nYes = retry download`nNo = browse for RunAsTool.exe`nCancel = abort",
        "RunAsTool required",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning)

    if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
        throw "RunAsTool is required for bypass shortcut creation."
    }

    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        $exe = Install-RunAsToolIfMissing -RepoRoot $RepoRoot -LogAction $LogAction
        if ($exe) {
            $ConfigRef.Value.runAsToolExe = $exe
            if ($Launch.IsPresent) {
                Start-RunAsToolApplication -ExePath $exe | Out-Null
            }
            return $exe
        }
    }

    $picked = Show-ResolveRunAsToolExeDialog
    if ($picked) {
        $ConfigRef.Value.runAsToolExe = $picked
        if ($Launch.IsPresent) {
            Start-RunAsToolApplication -ExePath $picked | Out-Null
        }
        return $picked
    }

    throw "RunAsTool.exe could not be resolved."
}

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
        [object[]]$PreLaunches = @(),
        [string]$GamePath = "",
        [string]$ShortcutLnkPath = "",
        [switch]$SyncListDriven,
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $LaunchPath)) {
        throw "Bypass shortcut not found: $LaunchPath"
    }

    if (-not $SyncListDriven.IsPresent) {
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

        if ($SyncListDriven.IsPresent) {
            if ($ExistingPlayniteId) {
                $existing = $allGames | Where-Object { $_.Id -ieq $ExistingPlayniteId } | Select-Object -First 1
            }
            if (-not $existing) {
                throw "Sync list: Playnite game not found for $Title"
            }
        }
        elseif ($OutsideAllowlist.IsPresent) {
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

        if ($SyncListDriven.IsPresent) {
            throw "Sync list: could not update Playnite row for $Title"
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
            updatedAt     = (Get-Date).ToString("o")
        }
    if (-not $SyncListDriven.IsPresent) {
        $bindingObj | Add-Member -NotePropertyName syncType -NotePropertyValue $(if ($OutsideAllowlist.IsPresent) { 'OutsideAllowlist' } else { 'InAllowlist' }) -Force
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
    if ($PreLaunches -and @($PreLaunches).Count -gt 0) {
        $bindingObj | Add-Member -NotePropertyName preLaunches -NotePropertyValue @($PreLaunches) -Force
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
    # Playnite.DesktopApp is 32-bit (Wow64). Bare `start` of a .lnk that targets
    # C:\Program Files\RunAsTool fails under SysWOW64 cmd with "path does not exist".
    # Sysnative forces a 64-bit cmd so ShellExecute resolves Program Files correctly.
    $cmdContent = @"
@echo off
if exist "%SystemRoot%\Sysnative\cmd.exe" (
  "%SystemRoot%\Sysnative\cmd.exe" /c start "" "$resolvedLnk"
) else (
  start "" "$resolvedLnk"
)
"@
    Set-Content -LiteralPath $paths.CmdPath -Value $cmdContent -Encoding ASCII
    if ($LogAction) { & $LogAction "Wrote shortcut launcher wrapper: $($paths.CmdPath) -> $resolvedLnk" }
    return $paths.CmdPath
}

function New-BypassMultiLaunchScript {
    param(
        [string]$BypassesPath,
        [string]$DisplayName,
        [object[]]$PreLaunches,
        [string]$ShortcutLnkPath,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($BypassesPath)) {
        throw 'BypassesPath is required for multi-launch script generation.'
    }
    if (-not (Test-Path -LiteralPath $BypassesPath)) {
        New-Item -ItemType Directory -Path $BypassesPath -Force | Out-Null
    }

    $paths = Get-BypassLauncherPaths -BypassesPath $BypassesPath -DisplayName $DisplayName
    $launchBlocks = New-Object System.Collections.Generic.List[string]
    foreach ($launch in @($PreLaunches)) {
        if (-not $launch -or -not $launch.path) { continue }
        $rawPath = $launch.path.ToString()
        $escaped = $rawPath.Replace("'", "''")
        $delay = 2
        if ($null -ne $launch.delaySec) { $delay = [int]$launch.delaySec }
        $isLnk = $rawPath.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)
        if ($isLnk) {
            # Same Wow64/Sysnative reason as the final shortcut: Start-Process on a RunAsTool
            # .lnk fails with "path not found" under 32-bit Playnite; cmd start via Sysnative works.
            [void]$launchBlocks.Add(@"
`$prePath = '$escaped'
if (`$prePath -and (Test-Path -LiteralPath `$prePath)) {
    `$cmd64 = Join-Path `$env:SystemRoot 'Sysnative\cmd.exe'
    if (-not (Test-Path -LiteralPath `$cmd64)) { `$cmd64 = Join-Path `$env:SystemRoot 'System32\cmd.exe' }
    Start-Process -FilePath `$cmd64 -ArgumentList ('/c start "" "' + `$prePath + '"')
    Start-Sleep -Seconds $delay
}
"@)
        }
        else {
            [void]$launchBlocks.Add(@"
`$prePath = '$escaped'
if (`$prePath -and (Test-Path -LiteralPath `$prePath)) {
    Start-Process -FilePath `$prePath -WindowStyle Hidden
    Start-Sleep -Seconds $delay
}
"@)
        }
    }

    $shortcutEscaped = $ShortcutLnkPath.Replace("'", "''")
    $ps1Content = @"
# Generated by Sync-PlayniteBypassShortcuts - do not edit by hand
$($launchBlocks -join [Environment]::NewLine)
`$shortcut = '$shortcutEscaped'
if (`$shortcut -and (Test-Path -LiteralPath `$shortcut)) {
    `$cmd64 = Join-Path `$env:SystemRoot 'Sysnative\cmd.exe'
    if (-not (Test-Path -LiteralPath `$cmd64)) { `$cmd64 = Join-Path `$env:SystemRoot 'System32\cmd.exe' }
    Start-Process -FilePath `$cmd64 -ArgumentList ('/c start "" "' + `$shortcut + '"')
}
else {
    throw "Shortcut not found: `$shortcut"
}
"@
    Set-Content -LiteralPath $paths.Ps1Path -Value $ps1Content -Encoding UTF8
    New-BypassLauncherCmdWrapper -Ps1Path $paths.Ps1Path -LogAction $LogAction | Out-Null

    if ($LogAction) {
        & $LogAction "Wrote multi-launch script: $($paths.Ps1Path) -> $($paths.CmdPath)"
    }

    return $paths
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

    $preLaunches = @(
        [PSCustomObject]@{
            path     = $HelperPath
            delaySec = $HelperDelaySec
        }
    )
    return New-BypassMultiLaunchScript `
        -BypassesPath $BypassesPath `
        -DisplayName $DisplayName `
        -PreLaunches $preLaunches `
        -ShortcutLnkPath $ShortcutLnkPath `
        -LogAction $LogAction
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
        'MultiLaunch' {
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
    $preLaunches = @()
    if ($Row.PreLaunches) {
        $preLaunches = @($Row.PreLaunches)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($helperPath)) {
        $preLaunches = @(
            [PSCustomObject]@{
                path     = $helperPath
                delaySec = $helperDelaySec
            }
        )
    }
    $launcherScript = ""
    $playLaunchPath = ""
    $exeLeaf = if ($Row.SuggestedExe) { $Row.SuggestedExe } else { "" }
    if ([string]::IsNullOrWhiteSpace($exeLeaf) -and $preLaunches.Count -gt 0 -and $preLaunches[0].path) {
        $exeLeaf = [System.IO.Path]::GetFileName($preLaunches[0].path.ToString())
    }
    $launcherMode = 'AppOnly'
    $resolvedLnk = Resolve-BypassShortcutLnkPathOnDisk `
        -ShortcutLnkPath $ShortcutLnkPath `
        -BypassesPath $BypassesPath `
        -DisplayName $DisplayName

    if ($preLaunches.Count -gt 0) {
        foreach ($launch in $preLaunches) {
            if (-not $launch -or -not $launch.path) { continue }
            if (-not (Test-BypassPathLiteral -Path $launch.path)) {
                if ($LogAction) { & $LogAction "Skip multi-launch (path not found): $($launch.path)" "WARN" }
                return [PSCustomObject]@{ Skipped = $true }
            }
        }
        if (-not (Test-BypassPathLiteral -Path $resolvedLnk)) {
            if ($LogAction) { & $LogAction "Skip multi-launch (shortcut not found): $ShortcutLnkPath" "WARN" }
            return [PSCustomObject]@{ Skipped = $true }
        }

        $paths = New-BypassMultiLaunchScript `
            -BypassesPath $BypassesPath `
            -DisplayName $DisplayName `
            -PreLaunches $preLaunches `
            -ShortcutLnkPath $resolvedLnk `
            -LogAction $LogAction
        $playLaunchPath = $paths.CmdPath
        $launcherScript = $paths.Ps1Path
        $ShortcutLnkPath = $resolvedLnk
        $launcherMode = if ($preLaunches.Count -eq 1) { 'HelperAndApp' } else { 'MultiLaunch' }
        $helperPath = $preLaunches[0].path
    }
    elseif (-not [string]::IsNullOrWhiteSpace($helperPath)) {
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
        $launcherMode = 'HelperAndApp'
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
        PreLaunches     = $preLaunches
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
        SuggestedExe        = $exeLeaf
        SuggestedType       = $suggestedType
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
            $isSyncListRow = $null -ne $row.SyncListEntry
            $displayName = if ($isSyncListRow) {
                Sanitize-BypassShortcutFileName -Name $row.DisplayName
            }
            else {
                Sanitize-BypassShortcutFileName -Name $row.DisplayName
            }
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                if ($LogAction) { & $LogAction "Skip (empty display name): $($row.FileName)" "WARN" }
                $stats.Skipped++
                continue
            }

            $launchPath = $row.OriginalLnkPath
            if (-not $isSyncListRow) {
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
            }
            elseif (-not (Test-Path -LiteralPath $launchPath)) {
                if ($LogAction) { & $LogAction "Skip (shortcut missing): $launchPath" "WARN" }
                $stats.Skipped++
                continue
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
                PreLaunches     = @($launcherResult.PreLaunches)
                ShortcutLnkPath = $launcherResult.ShortcutLnkPath
            }

            if ($isSyncListRow) {
                $entry = $row.SyncListEntry
                $games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -StopPlayniteFirst -LogAction $LogAction)
                $playniteGame = Find-PlayniteGameForSyncEntry -Entry $entry -Games $games -RepoRoot $RepoRoot
                if (-not $playniteGame) {
                    if ($LogAction) { & $LogAction "Skip sync list (no Playnite match): $($entry.title)" "WARN" }
                    $stats.Skipped++
                    continue
                }

                $nameId = if ($entry.nameId) { $entry.nameId } else { "" }
                $type = "ThirdParty"
                if ($nameId) {
                    $inferred = Get-AllowlistTypeFromNameId -NameId $nameId
                    if ($inferred) { $type = $inferred }
                }

                $entryBindingExe = Get-BypassSyncListBindingExe -Entry $entry
                if ([string]::IsNullOrWhiteSpace($entryBindingExe)) {
                    $entryBindingExe = 'game.exe'
                }

                $syncResult = Sync-PlayniteBypassBindingToLibrary `
                    -InstallDir $InstallDir `
                    -RepoRoot $RepoRoot `
                    -LaunchPath $playLaunchPath `
                    -Exe $(if ($launcherResult.ExeLeaf) { $launcherResult.ExeLeaf } else { $entryBindingExe }) `
                    -Title $(if ($playniteGame.Name) { $playniteGame.Name } else { $entry.title }) `
                    -NameId $nameId `
                    -Type $type `
                    -NameIdInput "" `
                    -IsNewApp $false `
                    -ExistingPlayniteId $playniteGame.Id `
                    @launcherSyncParams `
                    -SyncListDriven `
                    -LogAction $LogAction

                if ($syncResult.Action -eq 'Added') { $stats.Added++ } else { $stats.Updated++ }
                if ($syncResult.DuplicateNotice) {
                    $stats.DuplicateNotices += $syncResult.DuplicateNotice
                }
                continue
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

    return Invoke-PlayniteBypassSyncFromSyncList `
        -InstallDir $InstallDir `
        -RepoRoot $RepoRoot `
        -BypassesPath $BypassesPath `
        -WhatIf:$WhatIf `
        -LogAction $LogAction
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

function Invoke-RunAsToolRntImport {
    param(
        [Parameter(Mandatory)]
        [string]$RntPath,
        [string]$RunAsToolExe = '',
        [string]$AdminUser = $script:DefaultBypassAdminUser,
        [securestring]$AdminPassword,
        [switch]$ResetList,
        [string]$RepoRoot = '',
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $RntPath)) {
        throw "RNT file not found: $RntPath"
    }

    if (-not $AdminPassword) {
        $cred = Get-Credential -UserName $AdminUser -Message "RunAsTool import requires the admin password for $AdminUser"
        if (-not $cred) {
            throw 'Admin password is required for RunAsTool import.'
        }
        $AdminPassword = $cred.Password
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $script:PlayNiteWatcherScriptRoot
    }

    if ([string]::IsNullOrWhiteSpace($RunAsToolExe)) {
        $RunAsToolExe = Resolve-RunAsToolExe -RepoRoot $RepoRoot -InstallIfMissing
    }
    if (-not $RunAsToolExe -or -not (Test-Path -LiteralPath $RunAsToolExe)) {
        throw 'RunAsTool.exe not found.'
    }

    $argList = New-Object System.Collections.Generic.List[string]
    if ($ResetList.IsPresent) {
        [void]$argList.Add('/R')
    }
    [void]$argList.Add("/U=$AdminUser")
    [void]$argList.Add("/P=$plain")
    [void]$argList.Add("/I=$RntPath")

    $plain = $null
    if ($LogAction) { & $LogAction "RunAsTool RNT import starting: $RntPath (resetList=$($ResetList.IsPresent))" }

    $proc = Start-Process -FilePath $RunAsToolExe -ArgumentList $argList.ToArray() -Wait -PassThru -Verb RunAs
    if ($proc.ExitCode -ne 0) {
        throw "RunAsTool import failed with exit code $($proc.ExitCode). Check the NextGPU-Admin password and retry."
    }

    if ($LogAction) { & $LogAction "RunAsTool RNT import completed: $RntPath" }
}

function Stop-RunAsToolApplicationProcesses {
    Get-Process -Name "RunAsTool*" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
        }
        catch { }
    }
}

function Remove-RunAsToolInstallation {
    param(
        [string]$RepoRoot,
        [scriptblock]$LogAction
    )

    Stop-RunAsToolApplicationProcesses

    if (Test-Path -LiteralPath $script:DefaultRunAsToolProgramDataDir) {
        Remove-Item -LiteralPath $script:DefaultRunAsToolProgramDataDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($LogAction) { & $LogAction "Removed RunAsTool install: $($script:DefaultRunAsToolProgramDataDir)" }
    }

    $nextGpuRoot = Join-Path $env:ProgramData "NextGPU"
    if (Test-Path -LiteralPath $nextGpuRoot) {
        $remaining = @(Get-ChildItem -LiteralPath $nextGpuRoot -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $nextGpuRoot -Recurse -Force -ErrorAction SilentlyContinue
            if ($LogAction) { & $LogAction "Removed empty folder: $nextGpuRoot" }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $toolDir = Join-Path $RepoRoot "tools\runastool"
        if (Test-Path -LiteralPath $toolDir) {
            Get-ChildItem -LiteralPath $toolDir -Recurse -Filter "RunAsTool*.exe" -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    if ($LogAction) { & $LogAction "Removed bundled RunAsTool: $($_.FullName)" }
                }
            Get-ChildItem -LiteralPath $toolDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq 'RunAsTool' } |
                ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    if ($LogAction) { & $LogAction "Removed bundled RunAsTool folder: $($_.FullName)" }
                }
        }
    }
}

function Get-GameShortcutsFolderCandidatesFromConfig {
    param([object]$Config)

    $paths = New-Object System.Collections.Generic.List[string]
    if ($Config -and $Config.bypassesPath) {
        [void]$paths.Add([string]$Config.bypassesPath)
    }
    if ($Config -and $Config.parentPath) {
        $resolved = Resolve-GameShortcutsPathFromParent -ParentPath $Config.parentPath
        if ($resolved) {
            [void]$paths.Add($resolved)
        }
        foreach ($name in @($script:DefaultGameShortcutsFolderName, $script:LegacyGameShortcutsFolderName)) {
            [void]$paths.Add((Join-Path $Config.parentPath $name))
        }
    }

    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Remove-GameShortcutsFoldersFromConfig {
    param(
        [object]$Config,
        [scriptblock]$LogAction
    )

    foreach ($folder in (Get-GameShortcutsFolderCandidatesFromConfig -Config $Config)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            continue
        }
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
        if ($LogAction) { & $LogAction "Removed Game Shortcuts folder: $folder" }
    }
}

function Remove-AllowlistEntriesForBypassBindings {
    param(
        [string]$RepoRoot,
        [object[]]$Bindings,
        [scriptblock]$LogAction
    )

    $nameIds = @($Bindings | ForEach-Object { $_.nameId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($nameIds.Count -eq 0) {
        return 0
    }

    $allowPath = Get-DesktopAppAllowlistPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $allowPath)) {
        return 0
    }

    $raw = Get-Content -LiteralPath $allowPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $raw.apps) {
        return 0
    }

    $idSet = @($nameIds | ForEach-Object { $_.ToString() })
    $remaining = @($raw.apps | Where-Object { $idSet -notcontains $_.nameId })
    $removed = @($raw.apps).Count - $remaining.Count
    if ($removed -le 0) {
        return 0
    }

    $raw.apps = @($remaining)
    ($raw | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $allowPath -Encoding UTF8
    if ($LogAction) { & $LogAction "Removed $removed allowlist entries linked to bypass bindings." }
    return $removed
}

function Restore-PlayniteGameAfterBypassRemoval {
    param(
        $Doc,
        $Collection,
        [object]$Binding,
        [scriptblock]$LogAction
    )

    $title = Get-BsonValueAsString -Value $Doc['Name']
    $game = New-PlayniteGameRecordFromBsonDocument -Doc $Doc
    $syncType = if ($Binding -and $Binding.syncType) { [string]$Binding.syncType } else { "" }

    if ((Test-PlayniteGameIsStoreLibrary -Game $game) -or $syncType -eq 'OutsideAllowlist') {
        Set-LiteDbBsonField -Document $Doc -Name 'IncludeLibraryPluginAction' -Value $true
        if ($Doc.ContainsKey('GameActions')) {
            [void]$Doc.Remove('GameActions')
        }
        [void]$Collection.Update($Doc)
        if ($LogAction) { & $LogAction "Playnite store game reverted to library plugin: $title" }
        return 'StoreReverted'
    }

    [void]$Collection.Delete($Doc['_id'])
    if ($LogAction) { & $LogAction "Removed manual bypass game from Playnite library: $title (run Import Desktop Apps to restore)" }
    return 'ManualRemoved'
}

function Clear-PlayniteBypassBindingsFromLibrary {
    param(
        [string]$InstallDir,
        [object[]]$Bindings,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir) -or @($Bindings).Count -eq 0) {
        return @{ StoreReverted = 0; ManualRemoved = 0; Missing = 0 }
    }

    $stats = @{ StoreReverted = 0; ManualRemoved = 0; Missing = 0 }
    $bindingById = @{}
    foreach ($b in @($Bindings)) {
        if ($b -and $b.playniteId) {
            $bindingById[$b.playniteId.ToString()] = $b
        }
    }

    Invoke-PlayniteLibraryDatabaseSession -InstallDir $InstallDir -LogAction $LogAction -EditAction {
        param($db)
        $collection = $db.GetCollection("Game")
        foreach ($playniteId in @($bindingById.Keys)) {
            $binding = $bindingById[$playniteId]
            $guid = [guid]::Empty
            if (-not [guid]::TryParse($playniteId, [ref]$guid)) {
                $stats.Missing++
                continue
            }

            $doc = $collection.FindById($guid)
            if (-not $doc) {
                $stats.Missing++
                if ($LogAction) { & $LogAction "Playnite game not found for bypass removal: $playniteId" "WARN" }
                continue
            }

            $result = Restore-PlayniteGameAfterBypassRemoval -Doc $doc -Collection $collection -Binding $binding -LogAction $LogAction
            if ($result -eq 'StoreReverted') { $stats.StoreReverted++ }
            elseif ($result -eq 'ManualRemoved') { $stats.ManualRemoved++ }
        }
    }

    return $stats
}

function Clear-PlayniteBypassPublishedData {
    param(
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        return
    }

    $nextGpuData = Join-Path $InstallDir 'ExtensionsData\NextGPU'
    if (Test-Path -LiteralPath $nextGpuData) {
        Remove-Item -LiteralPath $nextGpuData -Recurse -Force -ErrorAction SilentlyContinue
        if ($LogAction) { & $LogAction "Removed Playnite bypass extension data: $nextGpuData" }
    }
}

function Reset-BypassShortcutsConfigFile {
    param(
        [string]$RepoRoot,
        [string]$InstallDir = "",
        [scriptblock]$LogAction
    )

    $template = Join-Path $RepoRoot "config\playnite\$($script:BypassShortcutsTemplateFileName)"
    $target = Get-BypassShortcutsConfigPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Bypass shortcuts template not found: $template"
    }

    Copy-Item -LiteralPath $template -Destination $target -Force
    if ($LogAction) { & $LogAction "Reset bypass-shortcuts.json to empty template." }

    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $empty = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
        Publish-NextGpuBypassBindingsToPlaynite -InstallDir $InstallDir -Config $empty.Config
        if ($LogAction) { & $LogAction "Cleared Playnite bypass-bindings.json." }
    }
}

function Uninstall-PlayniteWatcherHooks {
    param(
        [string]$RepoRoot,
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        return
    }

    $script = Join-Path $RepoRoot 'Install-PlayniteWatcher.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        if ($LogAction) { & $LogAction "Install-PlayniteWatcher.ps1 not found; skipping watcher uninstall." "WARN" }
        return
    }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $script,
            '-Uninstall', '-NoElevate',
            '-PlayniteInstallDir', $InstallDir
        ) -Wait -PassThru -WindowStyle Hidden
        if ($LogAction) {
            & $LogAction "PlayNiteWatcher uninstall exit code: $($proc.ExitCode)"
        }
    }
    catch {
        if ($LogAction) { & $LogAction "PlayNiteWatcher uninstall failed: $($_.Exception.Message)" "WARN" }
    }
}

function Test-PlayniteLiteDbLoadedInSession {
    param([string]$InstallDir = "")

    if ([string]::IsNullOrWhiteSpace($script:LiteDbAssemblyLoadedFrom)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        return $true
    }

    $normalizedInstall = $InstallDir.TrimEnd('\')
    return $script:LiteDbAssemblyLoadedFrom.Equals($normalizedInstall, [StringComparison]::OrdinalIgnoreCase)
}

function New-PlayniteFolderRemovalEncodedCommand {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [int]$WaitForProcessId = 0,
        [int]$MaxAttempts = 6,
        [string]$LogFile = "",
        [string]$PathFile = ""
    )

    $pathLiteral = $LiteralPath.Replace("'", "''")
    $installPrefix = $LiteralPath.TrimEnd('\').Replace("'", "''") + '\'
    $logFileLiteral = if ([string]::IsNullOrWhiteSpace($LogFile)) { "" } else { $LogFile.Replace("'", "''") }
    $pathFileLiteral = if ([string]::IsNullOrWhiteSpace($PathFile)) { "" } else { $PathFile.Replace("'", "''") }
    $waitForPid = [Math]::Max(0, $WaitForProcessId)

    $innerScript = @"
function Write-RemovalLog {
    param([string]`$Message, [string]`$Level = 'INFO')
    `$line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Level, `$Message
    if ('$logFileLiteral') {
        Add-Content -LiteralPath '$logFileLiteral' -Value `$line -Encoding utf8
    }
}

if ($waitForPid -gt 0) {
    try { Wait-Process -Id $waitForPid -Timeout 180 -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Seconds 2
}

`$target = '$pathLiteral'
`$installPrefix = '$installPrefix'
`$selfPid = `$PID
function Stop-PlayniteInstallLockingProcesses {
    Get-Process -Name 'Playnite.DesktopApp', 'Playnite.FullscreenApp', 'RunAsTool*', 'powershell', 'pwsh' -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (`$_.Id -eq `$selfPid) { return }
            `$shouldStop = `$false
            try {
                if (`$_.Path -and `$_.Path.StartsWith(`$installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    `$shouldStop = `$true
                }
                elseif (`$_.Modules) {
                    foreach (`$module in `$_.Modules) {
                        if (`$module.FileName -and `$module.FileName.StartsWith(`$installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                            `$shouldStop = `$true
                            break
                        }
                    }
                }
            }
            catch { }
            if (`$shouldStop) {
                Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    try {
        Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                (`$_.ExecutablePath -and `$_.ExecutablePath.StartsWith(`$installPrefix, [StringComparison]::OrdinalIgnoreCase)) -or
                (`$_.CommandLine -and `$_.CommandLine -like "*$pathLiteral*")
            } |
            Where-Object { `$_.ProcessId -ne `$selfPid } |
            ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}
`$removed = `$false
for (`$attempt = 1; `$attempt -le $MaxAttempts; `$attempt++) {
    Stop-PlayniteInstallLockingProcesses
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath `$target)) {
        `$removed = `$true
        break
    }
    try {
        Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction Stop
        `$removed = `$true
        break
    }
    catch {
        `$err = `$_.Exception.Message
        Write-RemovalLog "Playnite folder removal attempt `$attempt/$MaxAttempts failed: `$err" 'WARN'
        try {
            `$empty = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path `$empty -Force | Out-Null
            & robocopy `$empty `$target /mir /r:1 /w:1 /nfl /ndl /njh /njs /nc /ns /np 2>&1 | Out-Null
            Remove-Item -LiteralPath `$empty -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath `$target) {
                Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction Stop
            }
            `$removed = `$true
            break
        }
        catch {
            Start-Sleep -Seconds 3
        }
    }
}
if (-not `$removed -and (Test-Path -LiteralPath `$target)) {
    exit 1
}
if (`$removed -and '$logFileLiteral') {
    Write-RemovalLog "Removed Playnite portable install: `$target"
}
if ('$pathFileLiteral' -and (Test-Path -LiteralPath '$pathFileLiteral')) {
    Remove-Item -LiteralPath '$pathFileLiteral' -Force -ErrorAction SilentlyContinue
    Write-RemovalLog 'Removed PlayniteInstall.path'
}
exit 0
"@

    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerScript))
}

function Remove-DirectoryInFreshProcess {
    <#
        Deletes a folder from a new PowerShell process so assemblies loaded from that
        folder in the caller (e.g. Playnite LiteDB.dll via Add-Type) do not lock files.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [int]$MaxAttempts = 6,
        [string]$LogFile = "",
        [string]$PathFile = ""
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return $true
    }

    $encoded = New-PlayniteFolderRemovalEncodedCommand `
        -LiteralPath $LiteralPath `
        -MaxAttempts $MaxAttempts `
        -LogFile $LogFile `
        -PathFile $PathFile
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encoded
    ) -Wait -PassThru -WindowStyle Hidden
    return ($proc.ExitCode -eq 0)
}

function Start-PlayniteFolderRemovalAfterProcessExit {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [Parameter(Mandatory)]
        [int]$WaitForProcessId,
        [string]$LogFile = "",
        [string]$PathFile = "",
        [int]$MaxAttempts = 6
    )

    $encoded = New-PlayniteFolderRemovalEncodedCommand `
        -LiteralPath $LiteralPath `
        -WaitForProcessId $WaitForProcessId `
        -MaxAttempts $MaxAttempts `
        -LogFile $LogFile `
        -PathFile $PathFile
    $null = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encoded
    ) -WindowStyle Hidden
}

function Remove-PlaynitePortableInstall {
    param(
        [string]$RepoRoot,
        [string]$InstallDir = "",
        [scriptblock]$LogAction,
        [string]$LogFile = "",
        [int]$CallerProcessId = 0
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $RepoRoot -OverrideDir ""
        $InstallDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        if ($LogAction) { & $LogAction "Playnite install path not configured; skipping portable folder removal." "WARN" }
        return @{ Removed = $false; Deferred = $false }
    }

    $playniteExe = Join-Path $InstallDir 'Playnite.DesktopApp.exe'
    if (Test-Path -LiteralPath $playniteExe) {
        Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 45 -Force
    }
    Stop-Process -Name 'Playnite.DesktopApp', 'Playnite.FullscreenApp' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
    $deferForLiteDbLock = Test-PlayniteLiteDbLoadedInSession -InstallDir $InstallDir
    $waitForPid = if ($CallerProcessId -gt 0) { $CallerProcessId } else { 0 }
    $useDeferredRemoval = $waitForPid -gt 0

    if (Test-Path -LiteralPath $InstallDir) {
        if ($useDeferredRemoval) {
            if ($LogAction) {
                if ($deferForLiteDbLock) {
                    & $LogAction "Scheduling Playnite folder removal after this script exits (LiteDB.dll is loaded in this session)..."
                }
                else {
                    & $LogAction "Scheduling Playnite folder removal after this script exits..."
                }
            }
            Start-PlayniteFolderRemovalAfterProcessExit `
                -LiteralPath $InstallDir `
                -WaitForProcessId $waitForPid `
                -LogFile $LogFile `
                -PathFile $pathFile
            return @{ Removed = $false; Deferred = $true }
        }

        if ($LogAction) { & $LogAction "Removing Playnite portable install in a separate process..." }
        $removed = Remove-DirectoryInFreshProcess -LiteralPath $InstallDir -LogFile $LogFile -PathFile $pathFile
        if ($removed) {
            if ($LogAction) { & $LogAction "Removed Playnite portable install: $InstallDir" }
            return @{ Removed = $true; Deferred = $false }
        }

        if ($LogAction) {
            & $LogAction "Could not remove Playnite folder (files may still be locked by Playnite or another app). Bypass/RunAsTool cleanup completed; close Playnite and delete $InstallDir manually or reboot and retry." "WARN"
        }
        return @{ Removed = $false; Deferred = $false }
    }

    if (Test-Path -LiteralPath $pathFile) {
        Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
        if ($LogAction) { & $LogAction "Removed PlayniteInstall.path" }
    }

    return @{ Removed = $true; Deferred = $false }
}

function Uninstall-PlayniteBypassEnvironment {
    param(
        [string]$RepoRoot,
        [string]$InstallDir = "",
        [switch]$SkipPlaynite,
        [switch]$SkipRunAsTool,
        [switch]$SkipFolders,
        [switch]$SkipAllowlist,
        [switch]$RemovePlayniteInstall,
        [scriptblock]$LogAction,
        [string]$LogFile = "",
        [int]$CallerProcessId = 0
    )

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $config = $wrapper.Config
    $bindings = @($config.bindings)
    $stats = @{
        StoreReverted           = 0
        ManualRemoved           = 0
        Missing                 = 0
        AllowlistRemoved        = 0
        FoldersRemoved          = 0
        PlayniteRemoved         = $false
        PlayniteRemovalDeferred = $false
    }

    if ($RemovePlayniteInstall.IsPresent) {
        Uninstall-PlayniteWatcherHooks -RepoRoot $RepoRoot -InstallDir $InstallDir -LogAction $LogAction
    }

    if (-not $SkipPlaynite.IsPresent -and -not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $playStats = Clear-PlayniteBypassBindingsFromLibrary -InstallDir $InstallDir -Bindings $bindings -LogAction $LogAction
        $stats.StoreReverted = $playStats.StoreReverted
        $stats.ManualRemoved = $playStats.ManualRemoved
        $stats.Missing = $playStats.Missing
        Clear-PlayniteBypassPublishedData -InstallDir $InstallDir -LogAction $LogAction
    }

    if (-not $SkipAllowlist.IsPresent) {
        $stats.AllowlistRemoved = Remove-AllowlistEntriesForBypassBindings -RepoRoot $RepoRoot -Bindings $bindings -LogAction $LogAction
    }

    if (-not $SkipFolders.IsPresent) {
        $folderCandidates = Get-GameShortcutsFolderCandidatesFromConfig -Config $config
        foreach ($folder in $folderCandidates) {
            if (Test-Path -LiteralPath $folder) {
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
                $stats.FoldersRemoved++
                if ($LogAction) { & $LogAction "Removed Game Shortcuts folder: $folder" }
            }
        }
    }

    if (-not $SkipRunAsTool.IsPresent) {
        Remove-RunAsToolInstallation -RepoRoot $RepoRoot -LogAction $LogAction
    }

    Reset-BypassShortcutsConfigFile -RepoRoot $RepoRoot -InstallDir $InstallDir -LogAction $LogAction

    if ($RemovePlayniteInstall.IsPresent) {
        $removalResult = Remove-PlaynitePortableInstall -RepoRoot $RepoRoot -InstallDir $InstallDir -LogAction $LogAction -LogFile $LogFile -CallerProcessId $CallerProcessId
        if ($removalResult -is [hashtable]) {
            $stats.PlayniteRemoved = [bool]$removalResult.Removed
            $stats.PlayniteRemovalDeferred = [bool]$removalResult.Deferred
            if ($removalResult.Deferred -and $LogAction) {
                & $LogAction "Playnite folder will be deleted after this script exits; check Uninstall-PlayniteBypass.log for confirmation."
            }
        }
        else {
            $stats.PlayniteRemoved = [bool]$removalResult
        }
    }

    return [PSCustomObject]$stats
}

$bypassSyncListPath = Join-Path $PSScriptRoot 'Playnite-BypassSyncList.ps1'
if (Test-Path -LiteralPath $bypassSyncListPath) {
    . $bypassSyncListPath
}
