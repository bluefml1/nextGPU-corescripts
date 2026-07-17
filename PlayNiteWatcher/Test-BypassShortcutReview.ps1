#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for bypass shortcut review classification (no UI).
#>
$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot "Playnite-Common.ps1")
. (Join-Path $scriptRoot "BypassShortcutUI.ps1")

function Assert-Equal {
    param([string]$Expected, [string]$Actual, [string]$Label)
    if ($Expected -ne $Actual) {
        throw "$Label expected '$Expected' got '$Actual'"
    }
}

# Get-BypassShortcutSyncTypeFromGame
$steamGame = [PSCustomObject]@{
    Id       = "11111111-1111-1111-1111-111111111111"
    Name     = "Half-Life 2"
    GameId   = "220"
    PluginId = $script:PlayniteSteamPluginId
}
$epicGame = [PSCustomObject]@{
    Id       = "22222222-2222-2222-2222-222222222222"
    Name     = "Fortnite"
    PluginId = $script:PlayniteEpicPluginId
}
$manualGame = [PSCustomObject]@{
    Id       = "33333333-3333-3333-3333-333333333333"
    Name     = "Genshin Impact"
    PluginId = $script:PlayniteManualPluginId
}
$allowEntry = [PSCustomObject]@{
    Title  = "Genshin Impact"
    Exe    = "GenshinImpact.exe"
    NameId = "desktop01"
    Type   = "ThirdParty"
}

Assert-Equal "OutsideAllowlist" (Get-BypassShortcutSyncTypeFromGame -PlayniteGame $steamGame) "Steam"
Assert-Equal "OutsideAllowlist" (Get-BypassShortcutSyncTypeFromGame -PlayniteGame $epicGame) "Epic"
Assert-Equal "InAllowlist" (Get-BypassShortcutSyncTypeFromGame -PlayniteGame $manualGame) "Manual"
Assert-Equal "InAllowlist" (Get-BypassShortcutSyncTypeFromGame -PlayniteGame $null) "No game"
Assert-Equal "InAllowlist" (Get-BypassShortcutSyncTypeFromGame -PlayniteGame $steamGame -AllowlistMatch $allowEntry) "Allowlist overrides"

$steamHint = Get-BypassShortcutReviewHint -PlayniteGame $steamGame
if ($steamHint -notmatch "Steam AppID 220") {
    throw "Steam hint wrong: $steamHint"
}

$manualHint = Get-BypassShortcutReviewHint -PlayniteGame $manualGame
if ($manualHint -notmatch "manual") {
    throw "Manual hint wrong: $manualHint"
}

$noMatchHint = Get-BypassShortcutReviewHint -PlayniteGame $null
Assert-Equal "No match - needs allowlist" $noMatchHint "No match hint"

Assert-Equal "Outside allowlist" (ConvertTo-BypassSyncTypeDisplayName -SyncType "OutsideAllowlist") "Type display"
Assert-Equal "OutsideAllowlist" (ConvertFrom-BypassSyncTypeDisplayName -DisplayName "Outside allowlist") "Type parse"
Assert-Equal "InAllowlist" (ConvertFrom-BypassSyncTypeDisplayName -DisplayName "In allowlist") "Type parse in"

Assert-Equal "App only" (ConvertTo-BypassLauncherModeDisplayName -LauncherMode "AppOnly") "Launcher display AppOnly"
Assert-Equal "HelperAndApp" (ConvertFrom-BypassLauncherModeDisplayName -DisplayName "Helper + app") "Launcher parse Helper"
Assert-Equal "CustomScript" (ConvertFrom-BypassLauncherModeDisplayName -DisplayName "Custom script") "Launcher parse Custom"

$tempBypass = Join-Path $env:TEMP ("nextgpu-launcher-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempBypass -Force | Out-Null
$helperPath = Join-Path $env:TEMP ("helper-" + [guid]::NewGuid().ToString("N") + ".exe")
$shortcutPath = Join-Path $tempBypass "Garena Test.lnk"
try {
    Set-Content -LiteralPath $helperPath -Value '' -Encoding ASCII
    Set-Content -LiteralPath $shortcutPath -Value '' -Encoding ASCII

    $appOnlyPath = Resolve-BypassPlayniteLaunchPath -LauncherMode AppOnly -BypassesPath $tempBypass -DisplayName "Test Game" -OriginalLnkPath $shortcutPath
    if ($appOnlyPath -notmatch '\.cmd$') { throw "App only play path must be .cmd: $appOnlyPath" }

    $wrapperPath = New-BypassShortcutCmdWrapper -BypassesPath $tempBypass -DisplayName "Test Game" -ShortcutLnkPath $shortcutPath
    $cmdText = Get-Content -LiteralPath $wrapperPath -Raw -Encoding ASCII
    if ($cmdText -notmatch 'start') { throw "Shortcut wrapper must use start" }
    if ($cmdText -notmatch 'Sysnative') { throw "Shortcut wrapper must prefer Sysnative cmd for Wow64 Playnite" }
    if ($cmdText -notmatch [regex]::Escape($shortcutPath)) { throw "Shortcut wrapper must reference full .lnk path" }

    $paths = New-BypassCompositeLauncherScript `
        -BypassesPath $tempBypass `
        -DisplayName "Garena Test" `
        -HelperPath $helperPath `
        -ShortcutLnkPath $shortcutPath `
        -HelperDelaySec 3
    if (-not (Test-Path -LiteralPath $paths.Ps1Path)) { throw "Composite .ps1 not written" }
    if (-not (Test-Path -LiteralPath $paths.CmdPath)) { throw "Composite .cmd not written" }
    $ps1Text = Get-Content -LiteralPath $paths.Ps1Path -Raw -Encoding UTF8
    if ($ps1Text -notmatch [regex]::Escape($helperPath)) { throw "Composite .ps1 missing helper path" }
    if ($ps1Text -notmatch [regex]::Escape($shortcutPath)) { throw "Composite .ps1 missing shortcut path" }
    if ($ps1Text -notmatch 'Sysnative') { throw "Composite .ps1 must prefer Sysnative cmd for Wow64 Playnite" }
    if ($ps1Text -notmatch "ArgumentList \('/c start") { throw "Composite .ps1 must pass start args as one quoted string" }

    $helperLaunch = Resolve-BypassPlayniteLaunchPath -LauncherMode HelperAndApp -BypassesPath $tempBypass -DisplayName "Garena Test" -OriginalLnkPath $shortcutPath
    if ($helperLaunch -notmatch '\.cmd$') { throw "Helper composite play path must be .cmd: $helperLaunch" }

    $row = [PSCustomObject]@{ HelperPath = $helperPath; SuggestedExe = "Garena.exe"; HelperDelaySec = 2 }
    $resolved = Resolve-BypassReviewedRowLauncher -Row $row -BypassesPath $tempBypass -DisplayName "Garena Test" -ShortcutLnkPath $shortcutPath
    if ($resolved.LauncherMode -ne 'HelperAndApp') { throw "Expected HelperAndApp when helper set" }
    if ($resolved.PlayLaunchPath -notmatch '\.cmd$') { throw "Reviewed row play path must be .cmd" }

    $emptyRow = [PSCustomObject]@{ HelperPath = ""; SuggestedExe = "game.exe" }
    $appOnly = Resolve-BypassReviewedRowLauncher -Row $emptyRow -BypassesPath $tempBypass -DisplayName "Plain" -ShortcutLnkPath $shortcutPath
    if ($appOnly.LauncherMode -ne 'AppOnly' -or $appOnly.PlayLaunchPath -notmatch '\.cmd$') { throw "Empty helper must use .cmd wrapper" }
}
finally {
    if (Test-Path -LiteralPath $tempBypass) {
        Remove-Item -LiteralPath $tempBypass -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $helperPath -Force -ErrorAction SilentlyContinue
}

$steamId = $script:PlayniteSteamPluginId
$manualId = $script:PlayniteManualPluginId
$games = @(
    [PSCustomObject]@{ Id = "aaaa"; Name = "Wuthering Waves"; PluginId = $manualId; GameId = "" },
    [PSCustomObject]@{ Id = "bbbb"; Name = "Wuthering Waves"; PluginId = $steamId; GameId = "12345" }
)
$store = Find-PlayniteStoreGameForBypassShortcut -Games $games -Title "Wuthering Waves" -PreferredId "aaaa"
if (-not $store -or $store.Id -ne "bbbb") {
    throw "Store game preference failed: $($store.Id)"
}

# Sync list: gameId entry falls back to title when Playnite has no matching store GameId (e.g. manual import)
$wuwaEntry = [PSCustomObject]@{
    title        = 'Wuthering Waves'
    gameId       = '2807950'
    shortcutName = 'Wuthering Waves'
    appExe       = 'Wuthering Waves.exe'
    launches     = @()
}
$manualWuwa = [PSCustomObject]@{ Id = 'cccc'; Name = 'Wuthering Waves'; PluginId = $manualId; GameId = '' }
$syncMatch = Find-PlayniteGameForSyncEntry -Entry $wuwaEntry -Games @($manualWuwa) -RepoRoot $env:TEMP
if (-not $syncMatch -or $syncMatch.Id -ne 'cccc') {
    throw "Sync entry gameId should fall back to title match: $($syncMatch.Id)"
}
$steamWuwa = [PSCustomObject]@{ Id = 'dddd'; Name = 'Wuthering Waves'; PluginId = $steamId; GameId = '2807950' }
$dupMatch = Find-PlayniteGameForSyncEntry -Entry $wuwaEntry -Games @($manualWuwa, $steamWuwa) -RepoRoot $env:TEMP
if (-not $dupMatch -or $dupMatch.Id -ne 'dddd') {
    throw "Sync entry should prefer store game when gameId matches: $($dupMatch.Id)"
}

# Nested games array (from @(Get-PlayniteGamesWithPlayActions)) must not concatenate all .Name values in hints.
$nestedGames = @(,$games)
$nestedMatch = Find-PlayniteGameForBypassShortcut -Games $nestedGames -Title "Wuthering Waves"
$nestedHint = Get-BypassShortcutReviewHint -PlayniteGame $nestedMatch
if ($nestedHint -match "Counter-Strike|Marvel Rivals") {
    throw "Nested games array leaked other titles into hint: $nestedHint"
}
if ($nestedHint -notmatch "Wuthering Waves") {
    throw "Nested games hint missing title: $nestedHint"
}

# Publish-NextGpuBypassBindingsToPlaynite
$tempInstall = Join-Path $env:TEMP ("nextgpu-bypass-test-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempInstall -Force | Out-Null
try {
    $cfg = [PSCustomObject]@{
        bypassesPath = 'Z:\Game Shortcuts'
        bindings     = @(
            [PSCustomObject]@{
                playniteId = "11111111-1111-1111-1111-111111111111"
                title      = "Genshin Impact"
                launchPath = 'Z:\Game Shortcuts\Genshin Impact.lnk'
                syncType   = "InAllowlist"
                nameId     = "10000301"
            }
        )
    }
    Publish-NextGpuBypassBindingsToPlaynite -InstallDir $tempInstall -Config $cfg
    $publishedPath = Join-Path $tempInstall "ExtensionsData\NextGPU\bypass-bindings.json"
    if (-not (Test-Path -LiteralPath $publishedPath)) {
        throw "Published bypass-bindings.json missing"
    }
    $published = Get-Content -LiteralPath $publishedPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-Equal 'Z:\Game Shortcuts' $published.bypassesPath "Published bypassesPath"
    Assert-Equal "InAllowlist" $published.bindings[0].syncType "Published syncType"
    Assert-Equal 'Z:\Game Shortcuts\Genshin Impact.lnk' $published.bindings[0].launchPath "Published launchPath"
}
finally {
    if (Test-Path -LiteralPath $tempInstall) {
        Remove-Item -LiteralPath $tempInstall -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Sunshine export: bypass binding match by playniteId when play path is .lnk (C7)
$exportGames = @(
    [PSCustomObject]@{
        Id               = "11111111-1111-1111-1111-111111111111"
        Name             = "Genshin Impact"
        PrimaryPlayPath  = "Z:\Game Shortcuts\Genshin Impact.lnk"
        InstallDirectory = "Z:\Game Shortcuts"
        GameId           = ""
    }
)
$exportAllow = [PSCustomObject]@{ Title = "Genshin Impact"; Exe = "GenshinImpact.exe"; NameId = "10000301"; Type = "ThirdParty" }
$exportBindings = @(
    [PSCustomObject]@{
        playniteId = "11111111-1111-1111-1111-111111111111"
        title      = "Genshin Impact"
        nameId     = "10000301"
        launchPath = "Z:\Game Shortcuts\Genshin Impact.lnk"
        syncType   = "InAllowlist"
    }
)
$exportBinding = @($exportBindings) | Where-Object {
    ($_.nameId -and $exportAllow.NameId -and $_.nameId -ieq $exportAllow.NameId) -or
    ($_.title -and $exportAllow.Title -and $_.title -ieq $exportAllow.Title)
} | Select-Object -First 1
$exportMatch = Get-SinglePlayniteGameRecord -Game ($exportGames | Where-Object { $_.Id -ieq $exportBinding.playniteId } | Select-Object -First 1)
if (-not $exportMatch -or $exportMatch.PrimaryPlayPath -notmatch '\.lnk$') {
    throw "Export bypass binding match failed (C7)"
}

# Sync list: filtered seed copy (2 listed, 5 in seed -> 2 copied)
$tempRepo = Join-Path $env:TEMP ("nextgpu-sync-list-" + [guid]::NewGuid().ToString("N"))
$seedDir = Join-Path $tempRepo "templates\bypass\Game Shortcuts"
$destDir = Join-Path $tempRepo "host\Game Shortcuts"
$configDir = Join-Path $tempRepo "config\playnite"
New-Item -ItemType Directory -Path $seedDir -Force | Out-Null
New-Item -ItemType Directory -Path $configDir -Force | Out-Null
foreach ($name in @('A', 'B', 'C', 'D', 'E')) {
    Set-Content -LiteralPath (Join-Path $seedDir "$name.lnk") -Value '' -Encoding ASCII
}
Copy-Item -LiteralPath (Join-Path $scriptRoot "config\playnite\bypass-sync-list.json.template") `
    -Destination (Join-Path $configDir "bypass-sync-list.json") -Force
$syncDoc = Get-Content -LiteralPath (Join-Path $configDir "bypass-sync-list.json") -Raw | ConvertFrom-Json
$syncDoc.apps = @(
    [PSCustomObject]@{ title = 'Game A'; gameId = '1'; appExe = 'a.exe'; shortcutName = 'A'; launches = @() },
    [PSCustomObject]@{ title = 'Game B'; gameId = '2'; appExe = 'b.exe'; shortcutName = 'B'; launches = @() }
)
$syncDoc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $configDir "bypass-sync-list.json") -Encoding UTF8
try {
    $copyResult = Copy-BypassGameShortcutsForSyncList -ShortcutsSeedPath $seedDir -BypassesPath $destDir -RepoRoot $tempRepo
    if ($copyResult.Copied -ne 2) { throw "Expected 2 copied, got $($copyResult.Copied)" }
    $destLnks = @(Get-ChildItem -LiteralPath $destDir -Filter '*.lnk' -File)
    if ($destLnks.Count -ne 2) { throw "Expected 2 dest lnks, got $($destLnks.Count)" }
}
finally {
    if (Test-Path -LiteralPath $tempRepo) {
        Remove-Item -LiteralPath $tempRepo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Sync list: primary + prelaunch .lnk both copied from seed
$tempRepoPre = Join-Path $env:TEMP ("nextgpu-sync-pre-" + [guid]::NewGuid().ToString("N"))
$seedDirPre = Join-Path $tempRepoPre "templates\bypass\Game Shortcuts"
$destDirPre = Join-Path $tempRepoPre "host\Game Shortcuts"
$configDirPre = Join-Path $tempRepoPre "config\playnite"
New-Item -ItemType Directory -Path $seedDirPre -Force | Out-Null
New-Item -ItemType Directory -Path $configDirPre -Force | Out-Null
foreach ($name in @('Garena FC Online', 'Garena Platform', 'Extra')) {
    Set-Content -LiteralPath (Join-Path $seedDirPre "$name.lnk") -Value '' -Encoding ASCII
}
Copy-Item -LiteralPath (Join-Path $scriptRoot "config\playnite\bypass-sync-list.json.template") `
    -Destination (Join-Path $configDirPre "bypass-sync-list.json") -Force
$syncDocPre = Get-Content -LiteralPath (Join-Path $configDirPre "bypass-sync-list.json") -Raw | ConvertFrom-Json
$syncDocPre.apps = @(
    [PSCustomObject]@{
        title        = 'Garena FC Online'
        nameId       = '10000304'
        shortcutName = 'Garena FC Online'
        launches     = @(
            [PSCustomObject]@{ path = 'Z:\Game Shortcuts\Garena Platform.lnk'; delaySec = 2 }
            [PSCustomObject]@{ path = 'Z:\Garena\Garena\Garena.exe'; delaySec = 1 }
        )
    }
)
$syncDocPre | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $configDirPre "bypass-sync-list.json") -Encoding UTF8
try {
    $copyPre = Copy-BypassGameShortcutsForSyncList -ShortcutsSeedPath $seedDirPre -BypassesPath $destDirPre -RepoRoot $tempRepoPre
    if ($copyPre.Copied -ne 2) { throw "Expected primary+prelaunch 2 copied, got $($copyPre.Copied)" }
    $destPreLnks = @(Get-ChildItem -LiteralPath $destDirPre -Filter '*.lnk' -File | Select-Object -ExpandProperty Name)
    if ($destPreLnks.Count -ne 2) { throw "Expected 2 dest lnks (not Extra), got $($destPreLnks.Count)" }
    if ($destPreLnks -notcontains 'Garena FC Online.lnk') { throw 'Missing Garena FC Online.lnk' }
    if ($destPreLnks -notcontains 'Garena Platform.lnk') { throw 'Missing Garena Platform.lnk (prelaunch)' }
}
finally {
    if (Test-Path -LiteralPath $tempRepoPre) {
        Remove-Item -LiteralPath $tempRepoPre -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Sync list: filtered RNT import subset (FileName must match seed shortcut base names)
$tempRnt = Join-Path $env:TEMP ("nextgpu-rnt-" + [guid]::NewGuid().ToString("N") + ".rnt")
@'
[RunAsTool_Item]
FileName=Wuthering Waves
FilePath=Z:\Games\Wuthering Waves.exe

[RunAsTool_Item]
FileName=Other Game
FilePath=Z:\Games\Other.exe
'@ | Set-Content -LiteralPath $tempRnt -Encoding UTF8
$entries = @(
    [PSCustomObject]@{ title = 'Wuthering Waves'; gameId = '2807950'; appExe = 'Wuthering Waves.exe'; shortcutName = 'Wuthering Waves'; launches = @() }
)
$filtered = New-FilteredRunAsToolRnt -RntPath $tempRnt -SyncListEntries $entries
if ($filtered.IncludedCount -ne 1) { throw "Filtered RNT expected 1 item, got $($filtered.IncludedCount)" }
Remove-Item -LiteralPath $tempRnt -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $filtered.Path -Force -ErrorAction SilentlyContinue

# Sync list: RNT import matches seed shortcuts (primary + prelaunch .lnk), not title-only extras
$tempRnt2 = Join-Path $env:TEMP ("nextgpu-rnt2-" + [guid]::NewGuid().ToString("N") + ".rnt")
@'
[RunAsTool_Item]
FileName=Garena FC Online
FilePath=Z:\Garena\gxxapphelper.exe

[RunAsTool_Item]
FileName=Garena Platform
FilePath=Z:\Garena\Garena.exe

[RunAsTool_Item]
FileName=Wuthering Waves
FilePath=Z:\Steam\Wuthering Waves.exe

[RunAsTool_Item]
FileName=Steam
FilePath=Z:\Steam\steam.exe

[RunAsTool_Item]
FileName=Other Game
FilePath=Z:\Games\Other.exe
'@ | Set-Content -LiteralPath $tempRnt2 -Encoding UTF8
$entriesSeed = @(
    [PSCustomObject]@{
        title        = 'Wuthering Waves'
        gameId       = '2807950'
        shortcutName = 'Steam'
        launches     = @()
    },
    [PSCustomObject]@{
        title        = 'Garena FC Online'
        nameId       = '10000304'
        shortcutName = 'Garena FC Online'
        launches     = @(
            [PSCustomObject]@{ path = 'Z:\Game Shortcuts\Garena Platform.lnk'; delaySec = 2 }
        )
    }
)
$filteredSeed = New-FilteredRunAsToolRnt -RntPath $tempRnt2 -SyncListEntries $entriesSeed
if ($filteredSeed.IncludedCount -ne 3) {
    throw "Seed-aligned RNT expected 3 items (Steam, Garena FC Online, Garena Platform), got $($filteredSeed.IncludedCount)"
}
$filteredText = Get-Content -LiteralPath $filteredSeed.Path -Raw -Encoding UTF8
if ($filteredText -notmatch 'FileName=Garena Platform') { throw 'Seed-aligned RNT missing Garena Platform' }
if ($filteredText -notmatch 'FileName=Steam') { throw 'Seed-aligned RNT missing Steam' }
if ($filteredText -notmatch 'FileName=Garena FC Online') { throw 'Seed-aligned RNT missing Garena FC Online' }
if ($filteredText -match 'FileName=Wuthering Waves') { throw 'Seed-aligned RNT must not include title-only Wuthering Waves' }
if ($filteredText -match 'FileName=Other Game') { throw 'Seed-aligned RNT must not include Other Game' }
Remove-Item -LiteralPath $tempRnt2 -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $filteredSeed.Path -Force -ErrorAction SilentlyContinue

# Sync list review rows ignore extra .lnk in folder
$tempBypass = Join-Path $env:TEMP ("nextgpu-review-sync-" + [guid]::NewGuid().ToString("N"))
$tempRepo2 = Join-Path $env:TEMP ("nextgpu-review-repo-" + [guid]::NewGuid().ToString("N"))
$configDir2 = Join-Path $tempRepo2 "config\playnite"
New-Item -ItemType Directory -Path $tempBypass -Force | Out-Null
New-Item -ItemType Directory -Path $configDir2 -Force | Out-Null
Set-Content -LiteralPath (Join-Path $tempBypass "Listed.lnk") -Value '' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $tempBypass "Extra.lnk") -Value '' -Encoding ASCII
@{
    _comment = 'test'
    apps     = @(
        @{ title = 'Listed Game'; gameId = '99'; appExe = 'listed.exe'; shortcutName = 'Listed'; launches = @() }
    )
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $configDir2 "bypass-sync-list.json") -Encoding UTF8
try {
    $rows = Get-BypassShortcutReviewRowsFromSyncList -BypassesPath $tempBypass -RepoRoot $tempRepo2 -InstallDir $env:TEMP
    if (@($rows).Count -ne 1) { throw "Sync list review rows expected 1, got $(@($rows).Count)" }
    if ($rows[0].DisplayName -ne 'Listed') { throw "Unexpected review row name: $($rows[0].DisplayName)" }
}
catch {
    if ($_.Exception.Message -notmatch 'Playnite library database not found|games\.db') {
        throw
    }
}
finally {
    Remove-Item -LiteralPath $tempBypass -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRepo2 -Recurse -Force -ErrorAction SilentlyContinue
}

# Sync list: helperPath migrates to launches[] on normalize
$legacyEntry = [PSCustomObject]@{
    title        = 'Legacy Garena'
    nameId       = '10000304'
    shortcutName = 'Garena FC Online'
    exe          = 'Garena.exe'
    helperPath   = 'Z:\Garena\Garena\gxxapphelper.exe'
}
$normLegacy = Normalize-BypassSyncListEntry -Entry $legacyEntry
if (@($normLegacy.launches).Count -ne 1) { throw "Expected helperPath -> 1 launch, got $(@($normLegacy.launches).Count)" }
if ((Get-BypassSyncListAppExe -Entry $legacyEntry) -ne 'Garena.exe') { throw "Expected exe -> appExe migration on read" }

$garenaEntry = [PSCustomObject]@{
    title        = 'Garena FC Online'
    nameId       = '10000304'
    shortcutName = 'Garena FC Online'
    launches     = @([PSCustomObject]@{ path = 'Z:\Garena\Garena\gxxapphelper.exe'; delaySec = 2 })
}
if ((Get-BypassSyncListBindingExe -Entry $garenaEntry) -ne 'gxxapphelper.exe') {
    throw "Binding exe should derive from first pre-launch path"
}
$normGarena = Normalize-BypassSyncListEntry -Entry $garenaEntry
if ($normGarena.PSObject.Properties.Name -contains 'appExe') {
    throw "Normalized entry should not emit appExe when unset"
}

# Multi-launch script: 3 pre-launches + shortcut
$tempBypass2 = Join-Path $env:TEMP ("nextgpu-multilaunch-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempBypass2 -Force | Out-Null
$pre1 = Join-Path $env:TEMP ("pre1-" + [guid]::NewGuid().ToString("N") + ".exe")
$pre2 = Join-Path $env:TEMP ("pre2-" + [guid]::NewGuid().ToString("N") + ".exe")
$pre3 = Join-Path $env:TEMP ("pre3-" + [guid]::NewGuid().ToString("N") + ".exe")
$shortcutPath2 = Join-Path $tempBypass2 "Multi Test.lnk"
try {
    Set-Content -LiteralPath $pre1 -Value '' -Encoding ASCII
    Set-Content -LiteralPath $pre2 -Value '' -Encoding ASCII
    Set-Content -LiteralPath $pre3 -Value '' -Encoding ASCII
    Set-Content -LiteralPath $shortcutPath2 -Value '' -Encoding ASCII
    $preLaunches = @(
        [PSCustomObject]@{ path = $pre1; delaySec = 1 },
        [PSCustomObject]@{ path = $pre2; delaySec = 2 },
        [PSCustomObject]@{ path = $pre3; delaySec = 1 }
    )
    $paths = New-BypassMultiLaunchScript -BypassesPath $tempBypass2 -DisplayName "Multi Test" -PreLaunches $preLaunches -ShortcutLnkPath $shortcutPath2
    $ps1Text = Get-Content -LiteralPath $paths.Ps1Path -Raw -Encoding UTF8
    if ($ps1Text -notmatch [regex]::Escape($pre1)) { throw "Multi-launch .ps1 missing pre1" }
    if ($ps1Text -notmatch [regex]::Escape($pre2)) { throw "Multi-launch .ps1 missing pre2" }
    if ($ps1Text -notmatch [regex]::Escape($pre3)) { throw "Multi-launch .ps1 missing pre3" }
    if ($ps1Text -notmatch [regex]::Escape($shortcutPath2)) { throw "Multi-launch .ps1 missing shortcut" }
    if ($ps1Text -notmatch 'Start-Process -FilePath \$prePath -WindowStyle Hidden') {
        throw "Multi-launch .ps1 must Start-Process .exe prelaunches directly"
    }

    $preLnk = Join-Path $tempBypass2 "Pre Launch.lnk"
    Set-Content -LiteralPath $preLnk -Value '' -Encoding ASCII
    $pathsLnk = New-BypassMultiLaunchScript `
        -BypassesPath $tempBypass2 `
        -DisplayName "Multi Lnk" `
        -PreLaunches @([PSCustomObject]@{ path = $preLnk; delaySec = 2 }) `
        -ShortcutLnkPath $shortcutPath2
    $ps1Lnk = Get-Content -LiteralPath $pathsLnk.Ps1Path -Raw -Encoding UTF8
    if ($ps1Lnk -notmatch [regex]::Escape($preLnk)) { throw "Multi-launch .ps1 missing prelaunch .lnk" }
    if ($ps1Lnk -notmatch 'Sysnative') { throw "Multi-launch .ps1 must use Sysnative for prelaunch .lnk" }
    if ($ps1Lnk -match 'Start-Process -FilePath \$prePath -WindowStyle Hidden') {
        throw "Multi-launch .ps1 must not Start-Process .lnk prelaunches directly"
    }
    if ($ps1Lnk -notmatch "ArgumentList \('/c start") { throw "Multi-launch .ps1 must cmd-start prelaunch .lnk" }

    $emptyRow = [PSCustomObject]@{ PreLaunches = @(); SuggestedExe = "game.exe" }
    $appOnly = Resolve-BypassReviewedRowLauncher -Row $emptyRow -BypassesPath $tempBypass2 -DisplayName "Plain" -ShortcutLnkPath $shortcutPath2
    if ($appOnly.LauncherMode -ne 'AppOnly' -or $appOnly.PlayLaunchPath -notmatch '\.cmd$') { throw "Empty launches must use AppOnly .cmd wrapper" }
}
finally {
    if (Test-Path -LiteralPath $tempBypass2) {
        Remove-Item -LiteralPath $tempBypass2 -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $pre1 -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pre2 -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $pre3 -Force -ErrorAction SilentlyContinue
}

Write-Host "Test-BypassShortcutReview: all passed."
