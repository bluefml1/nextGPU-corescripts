#Requires -Version 5.1
<#
.SYNOPSIS
    Read Playnite games.db and output library rows as JSON for NextGPU UI.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [string]$PlayniteInstallDir = ""
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Playnite-Common.ps1')

$moduleRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
}
else {
    $RepoRoot.TrimEnd('\')
}

$installDir = Resolve-PlayniteInstallDir -PreferredDir $(Resolve-PlayniteInstallPathFromConfig -RepoRoot $moduleRoot -OverrideDir $PlayniteInstallDir)
if (-not $installDir) {
    throw 'Playnite install folder is not set. Run Setup-PlayniteSteam.bat first.'
}

$allowlist = @()
try {
    $allowlist = Get-DesktopAppAllowlist -RepoRoot $moduleRoot
}
catch { }

$games = @()
try {
    $games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $installDir)
}
catch {
    if ($_.Exception.Message -notmatch 'locked|being used by another process') {
        throw
    }
    Ensure-PlayniteLibraryDatabaseUnlocked -InstallDir $installDir
    $games = Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $installDir)
}
$rows = New-Object System.Collections.Generic.List[object]

foreach ($game in $games) {
    if (-not $game) { continue }

    $source = Get-PlayniteGameLibraryKindLabel -Game $game
    if ($source -eq 'library') {
        if ($game.PluginId -ieq $script:PlayniteEpicPluginId) {
            $source = 'Epic'
        }
        elseif ($game.PluginId -ieq $script:PlayniteSteamPluginId) {
            $source = 'Steam'
        }
        else {
            $source = 'Manual'
        }
    }

    $gameId = if ($game.GameId) { $game.GameId.ToString().Trim() } else { '' }
    $nameId = ''
    $exe = ''
    $playPath = if ($game.PrimaryPlayPath) { $game.PrimaryPlayPath.ToString().Trim() } else { '' }
    if ($playPath -match '\.exe$') {
        $exe = [System.IO.Path]::GetFileName($playPath)
    }

    if ($source -eq 'Manual' -or $game.PluginId -ieq $script:PlayniteManualPluginId) {
        $allow = Find-AllowlistEntryByExeOrTitle -RepoRoot $moduleRoot -Exe $exe -Title $game.Name
        if (-not $allow -and $allowlist.Count -gt 0) {
            $titleKey = if ($game.Name) { $game.Name.Trim().ToLowerInvariant() } else { '' }
            $allow = $allowlist | Where-Object {
                $_.Title -and $_.Title.Trim().ToLowerInvariant() -eq $titleKey
            } | Select-Object -First 1
        }
        if ($allow) {
            $nameId = $allow.NameId
            if ([string]::IsNullOrWhiteSpace($exe)) {
                $exe = $allow.Exe
            }
        }
        $gameId = ''
    }

    [void]$rows.Add([PSCustomObject]@{
            name       = if ($game.Name) { $game.Name } else { '' }
            source     = $source
            gameId     = $gameId
            nameId     = $nameId
            playniteId = $game.Id
            playPath   = $playPath
            exe        = $exe
        })
}

$result = [PSCustomObject]@{
    installDir = $installDir
    count      = $rows.Count
    games      = $rows.ToArray()
}
$json = $result | ConvertTo-Json -Depth 6 -Compress
[Console]::Out.WriteLine($json)
