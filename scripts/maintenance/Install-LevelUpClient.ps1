#Requires -Version 5.1
# Dot-sourced by GamesApps-Manifest.ps1 after shared helpers are defined.

$script:LevelUpBundleArchiveName = 'VNG.7z'
# Manifest extract folder names for the Level Up launcher bundle (VNG is current; LevelUp is legacy).
$script:LevelUpBundleFolderNames = @('VNG', 'LevelUp')
$script:LevelUpAppExeName = 'Level Up.exe'
$script:LevelUpAppFolderName = 'Level Up'

function Get-LevelUpBundleArchiveName {
    return $script:LevelUpBundleArchiveName
}

function Test-LevelUpBundleManifestLeaf {
    param([string]$LeafName)
    if ([string]::IsNullOrWhiteSpace($LeafName)) { return $false }
    foreach ($name in $script:LevelUpBundleFolderNames) {
        if ($LeafName -ieq $name) { return $true }
    }
    return $false
}

function Write-LevelUpInstallLog {
    param(
        [string]$LogPath,
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'FAIL')]
        [string]$Level = 'INFO'
    )
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    if ($LogPath) {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

function Test-LevelUpConfigFolder {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    $configDir = Join-Path $Dir 'config'
    if (-not (Test-Path -LiteralPath $configDir -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $configDir 'games.json') -PathType Leaf) `
        -or (Test-Path -LiteralPath (Join-Path $configDir 'app-settings.json') -PathType Leaf)
}

function Test-LevelUpLauncherClientFolder {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Dir $script:LevelUpAppExeName) -PathType Leaf)
}

function Find-LevelUpDeployFolderUnderExtract {
    <#
        Level Up AppData payload is the folder that contains config\ (games.json), not the
        nested Electron client folder that also ships Level Up.exe under VNG/LevelUp extract.
        Example: move Z:\VNG\Level Up\  (config only), not Z:\VNG\LevelUp\LevelUp\Level Up\.
    #>
    param([Parameter(Mandatory)]$ExtractPath)
    $ExtractPath = Resolve-ManifestExtractPathString -Path $ExtractPath
    if ([string]::IsNullOrWhiteSpace($ExtractPath)) { return $null }
    if (-not (Test-Path -LiteralPath $ExtractPath -PathType Container)) { return $null }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($configDir in @(Get-ChildItem -LiteralPath $ExtractPath -Recurse -Directory -Filter 'config' -ErrorAction SilentlyContinue)) {
        $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $configDir.FullName))
        if (-not (Test-LevelUpConfigFolder -Dir $parent)) { continue }
        if (Test-LevelUpLauncherClientFolder -Dir $parent) { continue }
        $depth = @($parent.Split([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) | Where-Object { $_ }).Count
        [void]$candidates.Add([pscustomobject]@{
            Path  = $parent
            Depth = $depth
        })
    }

    if ($candidates.Count -eq 0) { return $null }
    return @($candidates | Sort-Object Depth, Path | Select-Object -First 1).Path
}

function Find-LevelUpAppFolderUnderExtract {
    param([Parameter(Mandatory)]$ExtractPath)
    return Find-LevelUpDeployFolderUnderExtract -ExtractPath $ExtractPath
}

function Get-LevelUpLocalAppDataPath {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
    return Join-Path $env:LOCALAPPDATA $script:LevelUpAppFolderName
}

function Test-LevelUpInstalled {
    $localApp = Get-LevelUpLocalAppDataPath
    if (-not $localApp) { return $false }
    return (Test-LevelUpConfigFolder -Dir $localApp)
}

function Get-LevelUpManifestEntry {
    param([object[]]$Entries = @())
    $latest = $null
    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        $extract = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        $leaf = [System.IO.Path]::GetFileName($extract.Trim().TrimEnd('\'))
        if (Test-LevelUpBundleManifestLeaf -LeafName $leaf) {
            $latest = [pscustomobject]@{
                ExtractPath = [System.IO.Path]::GetFullPath((Resolve-ManifestExtractPathString -Path $extract))
                Entry       = $e
            }
        }
    }
    return $latest
}

function Find-ExistingLevelUpSyncPath {
    param([object[]]$Entries = @())
    if ($null -eq $Entries -or $Entries.Count -eq 0) {
        $Entries = @(Read-DownloadManifestEntries)
    }
    $hit = Get-LevelUpManifestEntry -Entries $Entries
    if (-not $hit) { return $null }
    $extractPath = Resolve-ManifestExtractPathString -Path $hit.ExtractPath
    if ([string]::IsNullOrWhiteSpace($extractPath)) { return $null }
    if (-not (Test-Path -LiteralPath $extractPath -PathType Container)) { return $null }
    if (-not (Find-LevelUpDeployFolderUnderExtract -ExtractPath $extractPath)) { return $null }
    return $extractPath
}

function Resolve-LevelUpSyncTargetFolder {
    param([object[]]$Entries = @())
    $configured = Get-ConfiguredSyncTargetPath
    if ($configured) {
        return [System.IO.Path]::GetFullPath($configured.TrimEnd('\'))
    }
    $hit = Get-LevelUpManifestEntry -Entries $Entries
    if ($hit) {
        $parent = Split-Path -Parent $hit.ExtractPath
        if ($parent) { return [System.IO.Path]::GetFullPath($parent) }
    }
    $driveLetter = Get-GamesDriveLetter -Entries $Entries
    if (-not $driveLetter) {
        throw 'Could not determine games drive for LevelUp install. Set NEXTGPU_SYNC_TARGET or run Sync Game/Apps first.'
    }
    return [System.IO.Path]::GetFullPath("${driveLetter}:\")
}

function Install-LevelUpClientSilent {
    param(
        [string]$TargetFolder = '',
        [string]$LogPath = '',
        [string]$ManifestPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = Get-ArrangeGamesAppsLogPath
    }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Get-ResolvedDownloadManifestPath
    }

    $entries = @(Read-DownloadManifestEntries -ManifestPath $ManifestPath)
    $existing = Find-ExistingLevelUpSyncPath -Entries $entries
    if ($existing) {
        $existing = Resolve-ManifestExtractPathString -Path $existing
        Write-LevelUpInstallLog -LogPath $LogPath -Message "LevelUp already synced at: $existing"
        return $existing
    }

    if ([string]::IsNullOrWhiteSpace($TargetFolder)) {
        $TargetFolder = Resolve-LevelUpSyncTargetFolder -Entries $entries
    }
    else {
        $TargetFolder = [System.IO.Path]::GetFullPath($TargetFolder.Trim().TrimEnd('\'))
    }

    if (-not (Test-Path -LiteralPath $TargetFolder)) {
        New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
    }

    $syncScript = Join-Path $PSScriptRoot 'Sync-GamesApps-Official.ps1'
    if (-not (Test-Path -LiteralPath $syncScript)) {
        throw "Sync script not found: $syncScript"
    }

    Write-LevelUpInstallLog -LogPath $LogPath -Message "Downloading $($script:LevelUpBundleArchiveName) to $TargetFolder via R2 sync ..."
    $syncArgs = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $syncScript,
        '-InstallArchive', $script:LevelUpBundleArchiveName,
        '-Quiet', '-NoGui'
    )
    $env:NEXTGPU_SYNC_TARGET = $TargetFolder

    & powershell.exe @syncArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "LevelUp download/extract failed (exit $LASTEXITCODE). See sync-games-apps log under ProgramData\nextGPU\logs."
    }

    $entries = @(Read-DownloadManifestEntries -ManifestPath $ManifestPath)
    $extractPath = Find-ExistingLevelUpSyncPath -Entries $entries
    if (-not $extractPath) {
        throw "LevelUp install finished but extract path was not found in manifest or on disk."
    }

    $extractPath = Resolve-ManifestExtractPathString -Path $extractPath
    Write-LevelUpInstallLog -LogPath $LogPath -Message "LevelUp synced at: $extractPath"
    return $extractPath
}
