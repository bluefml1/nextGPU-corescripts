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

Write-Host "Test-BypassShortcutReview: all passed."
