#Requires -Version 5.1
# Dot-sourced by Arrange-GamesApps.ps1 — deploy Level Up to AppData and patch games.json from manifest.

function Write-ArrangeLevelUpLog {
    param([string]$LogPath, [string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
}

function Write-ArrangeLevelUpWarn {
    param([string]$LogPath, [string]$Message)
    Write-ArrangeLevelUpLog -LogPath $LogPath -Message "WARN $Message"
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-ManifestGamePathMap {
    param([Parameter(Mandatory)][object[]]$Entries)
    $map = @{}
    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        if (Test-ManifestEntryIsSteamClient -Entry $e) { continue }
        $type = Get-ManifestEntryType -Entry $e
        if ($type -ieq 'steam') { continue }

        $extract = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($extract.TrimEnd('\'))
        }
        catch { continue }
        $full = Resolve-ManifestExtractPathString -Path $full
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        $leaf = [System.IO.Path]::GetFileName($full)
        if (Get-Command Test-LevelUpBundleManifestLeaf -ErrorAction SilentlyContinue) {
            if (Test-LevelUpBundleManifestLeaf -LeafName $leaf) { continue }
        }
        elseif ($leaf -ieq 'LevelUp') { continue }
        if (Get-Command Test-HoYoPlayBundleManifestLeaf -ErrorAction SilentlyContinue) {
            if (Test-HoYoPlayBundleManifestLeaf -LeafName $leaf) { continue }
        }
        elseif ($leaf -ieq 'HoYoPlay') { continue }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        # Manifest is append-only; later sessions win for the same game folder name.
        $map[$leaf] = $full
    }
    return $map
}

function Format-LevelUpJsonPath {
    param([Parameter(Mandatory)]$Path)
    $normalized = Resolve-ManifestExtractPathString -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) { return '' }
    # Return plain Windows path; ConvertTo-Json handles JSON escaping.
    return $normalized.TrimEnd('\')
}

function Get-LevelUpGameNameFromRootPath {
    param([AllowNull()]$RootFolderPath)
    $path = Resolve-ManifestExtractPathString -Path $RootFolderPath
    if ([string]::IsNullOrWhiteSpace($path)) { return '' }
    return [System.IO.Path]::GetFileName($path.Trim().TrimEnd('\'))
}

function Update-LevelUpGamesJson {
    param(
        [Parameter(Mandatory)]$GamesJsonPath,
        [Parameter(Mandatory)][hashtable]$GamePathMap,
        [Parameter(Mandatory)][string]$LogPath
    )

    $GamesJsonPath = Resolve-ManifestExtractPathString -Path $GamesJsonPath
    if ([string]::IsNullOrWhiteSpace($GamesJsonPath)) {
        throw 'games.json path is empty.'
    }
    if (-not (Test-Path -LiteralPath $GamesJsonPath -PathType Leaf)) {
        throw "games.json not found: $GamesJsonPath"
    }

    $raw = Get-Content -LiteralPath $GamesJsonPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-ArrangeLevelUpWarn -LogPath $LogPath -Message "games.json is empty: $GamesJsonPath"
        return 0
    }

    $doc = $null
    try {
        $doc = $raw | ConvertFrom-Json
    }
    catch {
        throw "Could not parse games.json: $GamesJsonPath ($($_.Exception.Message))"
    }

    if (-not $doc -or -not $doc.games) {
        Write-ArrangeLevelUpWarn -LogPath $LogPath -Message "No games object in $GamesJsonPath"
        return 0
    }

    $updated = 0
    $props = @($doc.games.PSObject.Properties)
    foreach ($prop in $props) {
        $game = $prop.Value
        if (-not $game) { continue }

        $gameName = Get-LevelUpGameNameFromRootPath -RootFolderPath $game.rootFolderPath
        if ([string]::IsNullOrWhiteSpace($gameName)) { continue }

        $matchKey = $null
        foreach ($key in @($GamePathMap.Keys)) {
            if ($key -ieq $gameName) {
                $matchKey = [string]$key
                break
            }
        }
        if (-not $matchKey) {
            Write-ArrangeLevelUpWarn -LogPath $LogPath -Message "No manifest extract for game: $gameName"
            continue
        }

        $manifestPath = Resolve-ManifestExtractPathString -Path $GamePathMap[$matchKey]
        if ([string]::IsNullOrWhiteSpace($manifestPath)) {
            Write-ArrangeLevelUpWarn -LogPath $LogPath -Message "Manifest path invalid for game: $gameName"
            continue
        }

        $newPath = Format-LevelUpJsonPath -Path $manifestPath
        if ([string]::IsNullOrWhiteSpace($newPath)) { continue }

        $oldPath = Resolve-ManifestExtractPathString -Path $game.rootFolderPath
        if (-not $oldPath) { $oldPath = [string]$game.rootFolderPath }
        if ($oldPath -ceq $newPath) { continue }

        $game | Add-Member -NotePropertyName rootFolderPath -NotePropertyValue $newPath -Force
        $updated++
        Write-ArrangeLevelUpLog -LogPath $LogPath -Message "PATCH games.json $gameName : $oldPath -> $newPath"
    }

    if ($updated -gt 0) {
        $json = $doc | ConvertTo-Json -Depth 10
        Set-Content -LiteralPath $GamesJsonPath -Value $json -Encoding UTF8
    }
    return $updated
}

function Test-DirectoryHasFiles {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Confirm-LevelUpArrangeDeploy {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestFolder,
        [bool]$ReplaceExisting = $false,
        [bool]$UseGui = $true
    )
    $msg = if ($ReplaceExisting) {
        "Replace existing Level Up install?`n`nFrom:`n$SourceFolder`n`nTo (will overwrite):`n$DestFolder"
    }
    else {
        "Deploy Level Up app?`n`nFrom:`n$SourceFolder`n`nTo:`n$DestFolder"
    }
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        return ([System.Windows.Forms.MessageBox]::Show($msg, 'Arrange LevelUp', 'YesNo', 'Question') -eq 'Yes')
    }
    $prompt = if ($ReplaceExisting) { 'Replace existing Level Up in AppData Local? [y/N]' } else { 'Move Level Up folder to AppData Local? [y/N]' }
    $ans = Read-Host $prompt
    return ($ans -match '^(y|yes)$')
}

function Remove-LevelUpDeployDestination {
    param(
        [Parameter(Mandatory)][string]$DestFolder,
        [Parameter(Mandatory)][string]$LogPath
    )
    if (-not (Test-Path -LiteralPath $DestFolder)) { return $false }
    Write-ArrangeLevelUpLog -LogPath $LogPath -Message "Removing existing Level Up at $DestFolder"
    Write-Host "[*] Removing existing install: $DestFolder" -ForegroundColor Cyan
    Remove-Item -LiteralPath $DestFolder -Recurse -Force -ErrorAction Stop
    return $true
}

function Invoke-LevelUpArrangeDeploy {
    param(
        [Parameter(Mandatory)]$SourceFolder,
        [Parameter(Mandatory)]$DestFolder,
        [Parameter(Mandatory)][hashtable]$GamePathMap,
        [Parameter(Mandatory)][string]$LogPath,
        [bool]$UseGui = $true
    )

    $sourceFolder = Resolve-ManifestExtractPathString -Path $SourceFolder
    $destFolder = Resolve-ManifestExtractPathString -Path $DestFolder
    if ([string]::IsNullOrWhiteSpace($sourceFolder)) {
        throw 'Level Up source folder path is empty.'
    }
    if ([string]::IsNullOrWhiteSpace($destFolder)) {
        throw 'Level Up destination folder path is empty.'
    }

    try {
        $sourceFolder = [System.IO.Path]::GetFullPath($sourceFolder)
        $destFolder = [System.IO.Path]::GetFullPath($destFolder)
    }
    catch {
        throw "Invalid Level Up folder path: $($_.Exception.Message)"
    }

    $sourceGamesJson = Join-Path $sourceFolder 'config\games.json'
    if (Test-Path -LiteralPath $sourceGamesJson) {
        $null = Update-LevelUpGamesJson -GamesJsonPath $sourceGamesJson -GamePathMap $GamePathMap -LogPath $LogPath
    }

    $sourceExists = Test-Path -LiteralPath $sourceFolder -PathType Container
    if (-not $sourceExists) {
        if (Test-LevelUpInstalled -or (Test-Path -LiteralPath $destFolder -PathType Container)) {
            $destGamesJson = Join-Path $destFolder 'config\games.json'
            if (Test-Path -LiteralPath $destGamesJson) {
                $null = Update-LevelUpGamesJson -GamesJsonPath $destGamesJson -GamePathMap $GamePathMap -LogPath $LogPath
                Write-ArrangeLevelUpLog -LogPath $LogPath -Message "Level Up in AppData; updated games.json (no sync source to deploy)."
            }
            else {
                Write-ArrangeLevelUpWarn -LogPath $LogPath -Message "Level Up in AppData but games.json missing: $destGamesJson"
            }
            return [pscustomobject]@{ Moved = $false; UpdatedConfig = $true }
        }
        throw "Level Up source folder not found: $sourceFolder"
    }

    $replaceExisting = Test-Path -LiteralPath $destFolder -PathType Container
    if ($replaceExisting -and (Test-DirectoryHasFiles -Dir $destFolder)) {
        Write-ArrangeLevelUpLog -LogPath $LogPath -Message "Existing Level Up at $destFolder will be replaced."
    }

    if (-not (Confirm-LevelUpArrangeDeploy -SourceFolder $sourceFolder -DestFolder $destFolder -ReplaceExisting:$replaceExisting -UseGui:$UseGui)) {
        Write-ArrangeLevelUpLog -LogPath $LogPath -Message 'User cancelled Level Up deploy.'
        return [pscustomobject]@{ Moved = $false; UpdatedConfig = $false; Cancelled = $true }
    }

    if ($replaceExisting) {
        $null = Remove-LevelUpDeployDestination -DestFolder $destFolder -LogPath $LogPath
    }

    $destParent = Split-Path -Parent $destFolder
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    Move-Item -LiteralPath $sourceFolder -Destination $destFolder -Force
    Write-ArrangeLevelUpLog -LogPath $LogPath -Message "MOVE Level Up -> $destFolder"
    return [pscustomobject]@{ Moved = $true; UpdatedConfig = $true; Replaced = $replaceExisting }
}

function Invoke-ArrangeLevelUpLayout {
    param([switch]$NoGui)

    $UseGui = -not $NoGui.IsPresent
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    $logPath = Get-ArrangeGamesAppsLogPath
    Write-ArrangeLevelUpLog -LogPath $logPath -Message '=== Arrange LevelUp layout started ==='

    $manifestPath = Get-ResolvedDownloadManifestPath
    Write-Host "Manifest: $manifestPath" -ForegroundColor Cyan
    Write-ArrangeLevelUpLog -LogPath $logPath -Message "Manifest: $manifestPath"

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath. Run Sync Game/Apps Officially first."
    }

    $entries = ConvertTo-ObjectArray (Read-DownloadManifestEntries -ManifestPath $manifestPath)
    $extractPath = Resolve-ManifestExtractPathString -Path (Ensure-LevelUpForArrange -Entries $entries -LogPath $logPath -UseGui:$UseGui)
    if ([string]::IsNullOrWhiteSpace($extractPath)) {
        throw 'Could not resolve LevelUp extract path from manifest or install.'
    }
    $entries = ConvertTo-ObjectArray (Read-DownloadManifestEntries -ManifestPath $manifestPath)

    $appFolder = Resolve-ManifestExtractPathString -Path (Find-LevelUpDeployFolderUnderExtract -ExtractPath $extractPath)
    if (-not $appFolder) {
        throw "Level Up config folder not found under synced extract path: $extractPath (expected a folder with config\games.json, not the Level Up.exe client)."
    }
    Write-ArrangeLevelUpLog -LogPath $logPath -Message "Level Up config folder: $appFolder"

    $gamePathMap = Get-ManifestGamePathMap -Entries $entries
    Write-Host 'Manifest game paths:' -ForegroundColor DarkGray
    foreach ($key in @($gamePathMap.Keys | Sort-Object)) {
        Write-Host ("  {0} -> {1}" -f $key, $gamePathMap[$key]) -ForegroundColor DarkGray
        Write-ArrangeLevelUpLog -LogPath $logPath -Message "MAP $key -> $($gamePathMap[$key])"
    }

    $localDest = Get-LevelUpLocalAppDataPath
    if (-not $localDest) {
        throw 'LOCALAPPDATA is not set for the current user.'
    }

    $result = Invoke-LevelUpArrangeDeploy `
        -SourceFolder $appFolder `
        -DestFolder $localDest `
        -GamePathMap $gamePathMap `
        -LogPath $logPath `
        -UseGui:$UseGui

    if ($result.Cancelled) {
        return 0
    }

    Write-Host ''
    if ($result.Moved) {
        Write-Host '[OK] Level Up deployed to AppData Local.' -ForegroundColor Green
    }
    else {
        Write-Host '[OK] Level Up config updated.' -ForegroundColor Green
    }
    Write-ArrangeLevelUpLog -LogPath $logPath -Message ("=== Finished moved={0} updated={1} ===" -f $result.Moved, $result.UpdatedConfig)

    if ($UseGui) {
        $summary = if ($result.Moved) { 'Level Up moved to AppData Local.' } else { 'games.json updated in AppData Local.' }
        [void][System.Windows.Forms.MessageBox]::Show(
            ("{0}`n`nLog: {1}" -f $summary, $logPath),
            'Arrange LevelUp', 'OK', 'Information')
    }

    return 0
}
