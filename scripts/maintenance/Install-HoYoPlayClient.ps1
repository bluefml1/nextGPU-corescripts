#Requires -Version 5.1
# Dot-sourced by GamesApps-Manifest.ps1 after shared helpers are defined.

$script:HoYoPlayBundleArchiveName = 'HoYoPlay.7z'
$script:HoYoPlayBundleFolderNames = @('HoYoPlay')
$script:HoYoCognosphereFolderName = 'Cognosphere'

function Get-HoYoPlayBundleArchiveName {
    return $script:HoYoPlayBundleArchiveName
}

function Test-HoYoPlayBundleManifestLeaf {
    param([string]$LeafName)
    if ([string]::IsNullOrWhiteSpace($LeafName)) { return $false }
    foreach ($name in $script:HoYoPlayBundleFolderNames) {
        if ($LeafName -ieq $name) { return $true }
    }
    return $false
}

function Write-HoYoPlayInstallLog {
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

function Test-HoYoPlayBundleLayout {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    return [bool](Find-CognosphereFolderUnderExtract -ExtractPath $Dir)
}

function Find-CognosphereFolderUnderExtract {
    param([Parameter(Mandatory)]$ExtractPath)
    $ExtractPath = Resolve-ManifestExtractPathString -Path $ExtractPath
    if ([string]::IsNullOrWhiteSpace($ExtractPath)) { return $null }
    if (-not (Test-Path -LiteralPath $ExtractPath -PathType Container)) { return $null }

    $direct = Join-Path $ExtractPath $script:HoYoCognosphereFolderName
    if (Test-Path -LiteralPath $direct -PathType Container) {
        return [System.IO.Path]::GetFullPath($direct)
    }

    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($dir in @(Get-ChildItem -LiteralPath $ExtractPath -Recurse -Directory -Filter $script:HoYoCognosphereFolderName -ErrorAction SilentlyContinue)) {
        if ($dir.Name -ine $script:HoYoCognosphereFolderName) { continue }
        $full = [System.IO.Path]::GetFullPath($dir.FullName)
        $depth = @($full.Split([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) | Where-Object { $_ }).Count
        [void]$candidates.Add([pscustomobject]@{
            Path  = $full
            Depth = $depth
        })
    }

    if ($candidates.Count -eq 0) { return $null }
    return @($candidates | Sort-Object Depth, Path | Select-Object -First 1).Path
}

function Get-DefaultUserRoamingCognospherePath {
    $drive = if ([string]::IsNullOrWhiteSpace($env:SystemDrive)) { 'C:' } else { $env:SystemDrive.TrimEnd('\') }
    return Join-Path $drive 'Users\Default\AppData\Roaming\Cognosphere'
}

function Test-CognosphereInstalledInDefaultUser {
    $dest = Get-DefaultUserRoamingCognospherePath
    if (-not $dest) { return $false }
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Get-HoYoPlayManifestEntry {
    param([object[]]$Entries = @())
    $latest = $null
    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        $extract = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        $leaf = [System.IO.Path]::GetFileName($extract.Trim().TrimEnd('\'))
        if (Test-HoYoPlayBundleManifestLeaf -LeafName $leaf) {
            $latest = [pscustomobject]@{
                ExtractPath = [System.IO.Path]::GetFullPath((Resolve-ManifestExtractPathString -Path $extract))
                Entry       = $e
            }
        }
    }
    return $latest
}

function Find-ExistingHoYoPlaySyncPath {
    param([object[]]$Entries = @())
    if ($null -eq $Entries -or $Entries.Count -eq 0) {
        $Entries = @(Read-DownloadManifestEntries)
    }
    $hit = Get-HoYoPlayManifestEntry -Entries $Entries
    if (-not $hit) { return $null }
    $extractPath = Resolve-ManifestExtractPathString -Path $hit.ExtractPath
    if ([string]::IsNullOrWhiteSpace($extractPath)) { return $null }
    if (-not (Test-Path -LiteralPath $extractPath -PathType Container)) { return $null }
    return $extractPath
}

function Resolve-HoYoPlaySyncTargetFolder {
    param([object[]]$Entries = @())
    $configured = Get-ConfiguredSyncTargetPath
    if ($configured) {
        return [System.IO.Path]::GetFullPath($configured.TrimEnd('\'))
    }
    $hit = Get-HoYoPlayManifestEntry -Entries $Entries
    if ($hit) {
        $parent = Split-Path -Parent $hit.ExtractPath
        if ($parent) { return [System.IO.Path]::GetFullPath($parent) }
    }
    $driveLetter = Get-GamesDriveLetter -Entries $Entries
    if (-not $driveLetter) {
        throw 'Could not determine games drive for HoYoPlay install. Set NEXTGPU_SYNC_TARGET or run Sync Game/Apps first.'
    }
    return [System.IO.Path]::GetFullPath("${driveLetter}:\")
}

function Install-HoYoPlayClientSilent {
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
    $existing = Find-ExistingHoYoPlaySyncPath -Entries $entries
    if ($existing) {
        $existing = Resolve-ManifestExtractPathString -Path $existing
        Write-HoYoPlayInstallLog -LogPath $LogPath -Message "HoYoPlay already synced at: $existing"
        return $existing
    }

    if ([string]::IsNullOrWhiteSpace($TargetFolder)) {
        $TargetFolder = Resolve-HoYoPlaySyncTargetFolder -Entries $entries
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

    Write-HoYoPlayInstallLog -LogPath $LogPath -Message "Downloading $($script:HoYoPlayBundleArchiveName) to $TargetFolder via R2 sync ..."
    $syncArgs = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $syncScript,
        '-InstallArchive', $script:HoYoPlayBundleArchiveName,
        '-Quiet', '-NoGui'
    )
    $env:NEXTGPU_SYNC_TARGET = $TargetFolder

    & powershell.exe @syncArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "HoYoPlay download/extract failed (exit $LASTEXITCODE). See sync-games-apps log under ProgramData\nextGPU\logs."
    }

    $entries = @(Read-DownloadManifestEntries -ManifestPath $ManifestPath)
    $extractPath = Find-ExistingHoYoPlaySyncPath -Entries $entries
    if (-not $extractPath) {
        throw 'HoYoPlay install finished but extract path was not found in manifest or on disk.'
    }

    $extractPath = Resolve-ManifestExtractPathString -Path $extractPath
    if (-not (Test-HoYoPlayBundleLayout -Dir $extractPath)) {
        throw "HoYoPlay synced at $extractPath but Cognosphere folder was not found. Re-sync HoYoPlay.7z."
    }

    Write-HoYoPlayInstallLog -LogPath $LogPath -Message "HoYoPlay synced at: $extractPath"
    return $extractPath
}
