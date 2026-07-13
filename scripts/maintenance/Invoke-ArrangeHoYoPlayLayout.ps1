#Requires -Version 5.1
# Dot-sourced by Arrange-GamesApps.ps1 — deploy Cognosphere to Default user Roaming from HoYoPlay sync.

function Write-ArrangeHoYoPlayLog {
    param([string]$LogPath, [string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
}

function Write-ArrangeHoYoPlayWarn {
    param([string]$LogPath, [string]$Message)
    Write-ArrangeHoYoPlayLog -LogPath $LogPath -Message "WARN $Message"
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Test-DirectoryHasFiles {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Confirm-HoYoPlayArrangeDeploy {
    param(
        [Parameter(Mandatory)][string]$SourceFolder,
        [Parameter(Mandatory)][string]$DestFolder,
        [bool]$ReplaceExisting = $false,
        [bool]$UseGui = $true
    )
    $msg = if ($ReplaceExisting) {
        "Replace existing Cognosphere in Default user Roaming?`n`nFrom:`n$SourceFolder`n`nTo (will overwrite):`n$DestFolder"
    }
    else {
        "Deploy Cognosphere to Default user Roaming?`n`nFrom:`n$SourceFolder`n`nTo:`n$DestFolder"
    }
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        return ([System.Windows.Forms.MessageBox]::Show($msg, 'Arrange HoYoPlay', 'YesNo', 'Question') -eq 'Yes')
    }
    $prompt = if ($ReplaceExisting) { 'Replace existing Cognosphere in Default Roaming? [y/N]' } else { 'Move Cognosphere to Default Roaming? [y/N]' }
    $ans = Read-Host $prompt
    return ($ans -match '^(y|yes)$')
}

function Remove-HoYoPlayDeployDestination {
    param(
        [Parameter(Mandatory)][string]$DestFolder,
        [Parameter(Mandatory)][string]$LogPath
    )
    if (-not (Test-Path -LiteralPath $DestFolder)) { return $false }
    Write-ArrangeHoYoPlayLog -LogPath $LogPath -Message "Removing existing Cognosphere at $DestFolder"
    Write-Host "[*] Removing existing install: $DestFolder" -ForegroundColor Cyan
    Remove-Item -LiteralPath $DestFolder -Recurse -Force -ErrorAction Stop
    return $true
}

function Invoke-HoYoPlayArrangeDeploy {
    param(
        [Parameter(Mandatory)]$SourceFolder,
        [Parameter(Mandatory)]$DestFolder,
        [Parameter(Mandatory)][string]$LogPath,
        [bool]$UseGui = $true
    )

    $sourceFolder = Resolve-ManifestExtractPathString -Path $SourceFolder
    $destFolder = Resolve-ManifestExtractPathString -Path $DestFolder
    if ([string]::IsNullOrWhiteSpace($sourceFolder)) {
        throw 'Cognosphere source folder path is empty.'
    }
    if ([string]::IsNullOrWhiteSpace($destFolder)) {
        throw 'Cognosphere destination folder path is empty.'
    }

    try {
        $sourceFolder = [System.IO.Path]::GetFullPath($sourceFolder)
        $destFolder = [System.IO.Path]::GetFullPath($destFolder)
    }
    catch {
        throw "Invalid Cognosphere folder path: $($_.Exception.Message)"
    }

    $sourceExists = Test-Path -LiteralPath $sourceFolder -PathType Container
    if (-not $sourceExists) {
        if (Test-CognosphereInstalledInDefaultUser -or (Test-Path -LiteralPath $destFolder -PathType Container)) {
            if (Test-DirectoryHasFiles -Dir $destFolder) {
                Write-ArrangeHoYoPlayLog -LogPath $LogPath -Message "Cognosphere already in Default Roaming; no sync source to deploy."
                return [pscustomobject]@{ Moved = $false; AlreadyInstalled = $true }
            }
            Write-ArrangeHoYoPlayWarn -LogPath $LogPath -Message "Cognosphere destination exists but is empty: $destFolder"
        }
        throw "Cognosphere source folder not found: $sourceFolder (re-sync HoYoPlay.7z)"
    }

    $replaceExisting = Test-Path -LiteralPath $destFolder -PathType Container
    if ($replaceExisting -and (Test-DirectoryHasFiles -Dir $destFolder)) {
        Write-ArrangeHoYoPlayLog -LogPath $LogPath -Message "Existing Cognosphere at $destFolder will be replaced."
    }

    if (-not (Confirm-HoYoPlayArrangeDeploy -SourceFolder $sourceFolder -DestFolder $destFolder -ReplaceExisting:$replaceExisting -UseGui:$UseGui)) {
        Write-ArrangeHoYoPlayLog -LogPath $LogPath -Message 'User cancelled HoYoPlay deploy.'
        return [pscustomobject]@{ Moved = $false; Cancelled = $true }
    }

    if ($replaceExisting) {
        $null = Remove-HoYoPlayDeployDestination -DestFolder $destFolder -LogPath $LogPath
    }

    $destParent = Split-Path -Parent $destFolder
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    Move-Item -LiteralPath $sourceFolder -Destination $destFolder -Force
    Write-ArrangeHoYoPlayLog -LogPath $LogPath -Message "MOVE Cognosphere -> $destFolder"
    return [pscustomobject]@{ Moved = $true; Replaced = $replaceExisting }
}

function Invoke-ArrangeHoYoPlayLayout {
    param([switch]$NoGui)

    $UseGui = -not $NoGui.IsPresent
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    $logPath = Get-ArrangeGamesAppsLogPath
    Write-ArrangeHoYoPlayLog -LogPath $logPath -Message '=== Arrange HoYoPlay layout started ==='

    $manifestPath = Get-ResolvedDownloadManifestPath
    Write-Host "Manifest: $manifestPath" -ForegroundColor Cyan
    Write-ArrangeHoYoPlayLog -LogPath $logPath -Message "Manifest: $manifestPath"

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath. Run Sync Game/Apps Officially first."
    }

    $entries = ConvertTo-ObjectArray (Read-DownloadManifestEntries -ManifestPath $manifestPath)
    $extractPath = Resolve-ManifestExtractPathString -Path (Ensure-HoYoPlayForArrange -Entries $entries -LogPath $logPath -UseGui:$UseGui)
    if ([string]::IsNullOrWhiteSpace($extractPath)) {
        throw 'Could not resolve HoYoPlay extract path from manifest or install.'
    }
    Write-ArrangeHoYoPlayLog -LogPath $logPath -Message "HoYoPlay extract: $extractPath"

    $cognosphereSource = Resolve-ManifestExtractPathString -Path (Find-CognosphereFolderUnderExtract -ExtractPath $extractPath)
    if (-not $cognosphereSource) {
        if (Test-CognosphereInstalledInDefaultUser) {
            Write-ArrangeHoYoPlayWarn -LogPath $logPath -Message "Cognosphere not in sync extract but already present in Default Roaming."
            $destOnly = Get-DefaultUserRoamingCognospherePath
            if ($UseGui) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    ("Cognosphere is already deployed to Default user Roaming.`n`n$destOnly`n`nLog: {0}" -f $logPath),
                    'Arrange HoYoPlay', 'OK', 'Information')
            }
            Write-ArrangeHoYoPlayLog -LogPath $logPath -Message '=== Finished moved=False already_installed=True ==='
            return 0
        }
        throw "Cognosphere folder not found under synced extract path: $extractPath (re-sync HoYoPlay.7z)"
    }
    Write-ArrangeHoYoPlayLog -LogPath $logPath -Message "Cognosphere source: $cognosphereSource"

    $defaultDest = Get-DefaultUserRoamingCognospherePath
    if (-not $defaultDest) {
        throw 'Could not resolve Default user Roaming Cognosphere path.'
    }

    $result = Invoke-HoYoPlayArrangeDeploy `
        -SourceFolder $cognosphereSource `
        -DestFolder $defaultDest `
        -LogPath $logPath `
        -UseGui:$UseGui

    if ($result.Cancelled) {
        return 0
    }

    Write-Host ''
    if ($result.Moved) {
        Write-Host '[OK] Cognosphere deployed to Default user Roaming.' -ForegroundColor Green
    }
    elseif ($result.AlreadyInstalled) {
        Write-Host '[OK] Cognosphere already in Default user Roaming.' -ForegroundColor Green
    }
    Write-ArrangeHoYoPlayLog -LogPath $logPath -Message ("=== Finished moved={0} ===" -f $result.Moved)

    if ($UseGui) {
        $summary = if ($result.Moved) { 'Cognosphere moved to Default user Roaming.' } else { 'Cognosphere already in Default user Roaming.' }
        [void][System.Windows.Forms.MessageBox]::Show(
            ("{0}`n`nLog: {1}" -f $summary, $logPath),
            'Arrange HoYoPlay', 'OK', 'Information')
    }

    return 0
}
