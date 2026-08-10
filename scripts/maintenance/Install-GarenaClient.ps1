#Requires -Version 5.1
# Dot-sourced by GamesApps-Manifest.ps1 after shared helpers are defined.

$script:GarenaBundleArchiveName = 'Garena.7z'
$script:GarenaBundleFolderNames = @('Garena')
$script:GarenaClientExeName = 'Garena.exe'
$script:GarenaClientSubfolderName = 'Garena'

function Stop-GarenaClientProcesses {
    foreach ($name in @('Garena', 'gxxcef', 'GxxSDK', 'gxxsvc', 'GarenaTV')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 400
}

function Get-GarenaBundleArchiveName {
    return $script:GarenaBundleArchiveName
}

function Test-GarenaBundleManifestLeaf {
    param([string]$LeafName)
    if ([string]::IsNullOrWhiteSpace($LeafName)) { return $false }
    foreach ($name in $script:GarenaBundleFolderNames) {
        if ($LeafName -ieq $name) { return $true }
    }
    return $false
}

function Write-GarenaInstallLog {
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

function Get-GarenaConfigFolderSourcePath {
    param([Parameter(Mandatory)][string]$BundleRoot)
    $configRoot = Join-Path $BundleRoot 'Config'
    if (-not (Test-Path -LiteralPath $configRoot -PathType Container)) { return $null }

    foreach ($child in @(Get-ChildItem -LiteralPath $configRoot -Directory -ErrorAction SilentlyContinue)) {
        # Only accept folders nested directly under Config\ (e.g. Config\Garena), never bundle-root\Garena.
        $gxxDat = Join-Path $child.FullName 'gxx\config\gxx.dat'
        if (Test-Path -LiteralPath $gxxDat -PathType Leaf) {
            return [System.IO.Path]::GetFullPath($child.FullName)
        }
    }

    return $null
}

function Test-GarenaPathIsUnderConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BundleRoot
    )
    try {
        $configRoot = [System.IO.Path]::GetFullPath((Join-Path $BundleRoot 'Config')).TrimEnd('\')
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch { return $false }
    if ($full -ieq $configRoot) { return $true }
    return $full.StartsWith(($configRoot + '\'), [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-GarenaClientDirUnderBundle {
    param([Parameter(Mandatory)][string]$BundleRoot)
    if ([string]::IsNullOrWhiteSpace($BundleRoot)) { return $null }
    if (-not (Test-Path -LiteralPath $BundleRoot -PathType Container)) { return $null }

    # Find Garena.exe under the bundle, but never under Config\ (that tree is session/config data only).
    $hit = Get-ChildItem -LiteralPath $BundleRoot -Filter $script:GarenaClientExeName -File -Recurse -Depth 6 -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-GarenaPathIsUnderConfig -Path $_.DirectoryName -BundleRoot $BundleRoot) } |
        Sort-Object { $_.FullName.Length } |
        Select-Object -First 1
    if ($hit) {
        return [System.IO.Path]::GetFullPath($hit.DirectoryName)
    }
    return $null
}

function Test-GarenaBundleLayout {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    # Cheap gate: require Config before searching for client exe.
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'Config') -PathType Container)) { return $false }
    if (-not (Get-GarenaConfigFolderSourcePath -BundleRoot $Dir)) { return $false }
    return [bool](Resolve-GarenaClientDirUnderBundle -BundleRoot $Dir)
}

function Find-GarenaBundleRootUnderExtract {
    param([Parameter(Mandatory)]$ExtractPath)
    if (Get-Command Resolve-ManifestExtractPathString -ErrorAction SilentlyContinue) {
        $ExtractPath = Resolve-ManifestExtractPathString -Path $ExtractPath
    }
    else {
        $ExtractPath = [string]$ExtractPath
        if (-not [string]::IsNullOrWhiteSpace($ExtractPath)) {
            $ExtractPath = $ExtractPath.Trim().Trim('"').TrimEnd('\')
        }
    }
    if ([string]::IsNullOrWhiteSpace($ExtractPath)) { return $null }
    if (-not (Test-Path -LiteralPath $ExtractPath -PathType Container)) { return $null }
    if (Test-GarenaBundleLayout -Dir $ExtractPath) {
        return [System.IO.Path]::GetFullPath($ExtractPath)
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $ExtractPath -Directory -ErrorAction SilentlyContinue)) {
        if (Test-GarenaBundleLayout -Dir $child.FullName) {
            return [System.IO.Path]::GetFullPath($child.FullName)
        }
    }
    return $null
}

function Get-GarenaGxxSourcePath {
    param([Parameter(Mandatory)][string]$BundleRoot)
    $configFolder = Get-GarenaConfigFolderSourcePath -BundleRoot $BundleRoot
    if (-not $configFolder) { return $null }
    return Join-Path $configFolder 'gxx'
}

function Get-GarenaClientSourcePath {
    param([Parameter(Mandatory)][string]$BundleRoot)
    $resolved = Resolve-GarenaClientDirUnderBundle -BundleRoot $BundleRoot
    if ($resolved) { return $resolved }
    return $null
}

function Get-GarenaBundleLeafName {
    return [System.IO.Path]::GetFileNameWithoutExtension($script:GarenaBundleArchiveName)
}

function Get-GarenaProgramDataRootPath {
    param([string]$BundleRoot = '')

    $folderName = $null
    $roots = @()
    if (-not [string]::IsNullOrWhiteSpace($BundleRoot)) { $roots += $BundleRoot }
    try {
        $onDisk = Find-GarenaBundleRootOnDisk
        if ($onDisk) { $roots += $onDisk }
    }
    catch { }

    foreach ($root in $roots) {
        $cfg = Get-GarenaConfigFolderSourcePath -BundleRoot $root
        if ($cfg) {
            $folderName = Split-Path -Leaf $cfg
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($folderName)) {
        $folderName = Get-GarenaBundleLeafName
    }
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { return $null }
    return Join-Path $env:ProgramData $folderName
}

function Get-GarenaProgramDataGxxPath {
    param([string]$BundleRoot = '')
    $root = Get-GarenaProgramDataRootPath -BundleRoot $BundleRoot
    if (-not $root) { return $null }
    return Join-Path $root 'gxx'
}

function Get-GarenaManifestEntry {
    param([object[]]$Entries = @())
    $latest = $null
    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        $extract = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        $leaf = [System.IO.Path]::GetFileName($extract.Trim().TrimEnd('\'))
        if (Test-GarenaBundleManifestLeaf -LeafName $leaf) {
            $latest = [pscustomobject]@{
                ExtractPath = [System.IO.Path]::GetFullPath((Resolve-ManifestExtractPathString -Path $extract))
                Entry       = $e
            }
        }
    }
    return $latest
}

function Find-ExistingGarenaSyncPath {
    param([object[]]$Entries = @())
    if ($null -eq $Entries -or $Entries.Count -eq 0) {
        if (Get-Command Read-DownloadManifestEntries -ErrorAction SilentlyContinue) {
            try {
                $Entries = @(Read-DownloadManifestEntries)
            }
            catch {
                $Entries = @()
            }
        }
        else {
            $Entries = @()
        }
    }
    $hit = Get-GarenaManifestEntry -Entries $Entries
    if (-not $hit) { return $null }
    $extractPath = if (Get-Command Resolve-ManifestExtractPathString -ErrorAction SilentlyContinue) {
        Resolve-ManifestExtractPathString -Path $hit.ExtractPath
    }
    else {
        [string]$hit.ExtractPath
    }
    if ([string]::IsNullOrWhiteSpace($extractPath)) { return $null }
    if (-not (Test-Path -LiteralPath $extractPath -PathType Container)) { return $null }
    if (-not (Find-GarenaBundleRootUnderExtract -ExtractPath $extractPath)) { return $null }
    return $extractPath
}

function Resolve-GarenaSyncTargetFolder {
    param([object[]]$Entries = @())
    $configured = Get-ConfiguredSyncTargetPath
    if ($configured) {
        return [System.IO.Path]::GetFullPath($configured.TrimEnd('\'))
    }
    $hit = Get-GarenaManifestEntry -Entries $Entries
    if ($hit) {
        $parent = Split-Path -Parent $hit.ExtractPath
        if ($parent) { return [System.IO.Path]::GetFullPath($parent) }
    }
    $driveLetter = Get-GamesDriveLetter -Entries $Entries
    if (-not $driveLetter) {
        throw 'Could not determine games drive for Garena install. Set NEXTGPU_SYNC_TARGET or run Sync Game/Apps first.'
    }
    return [System.IO.Path]::GetFullPath("${driveLetter}:\")
}

function Get-GarenaInstallPathFile {
    return Join-Path $PSScriptRoot 'GarenaInstall.path'
}

function Read-SavedGarenaInstallRoot {
    $pathFile = Get-GarenaInstallPathFile
    if (-not (Test-Path -LiteralPath $pathFile)) { return $null }
    $line = (Get-Content -LiteralPath $pathFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($line.Trim().Trim('"'))
    }
    catch { return $null }
}

function Find-GarenaBundleRootOnDisk {
    param([object[]]$Entries = @())

    $saved = Read-SavedGarenaInstallRoot
    if ($saved) {
        $fromSaved = Find-GarenaBundleRootUnderExtract -ExtractPath $saved
        if ($fromSaved) { return $fromSaved }
    }

    if (Get-Command Find-ExistingGarenaSyncPath -ErrorAction SilentlyContinue) {
        try {
            $syncPath = Find-ExistingGarenaSyncPath -Entries $Entries
            if ($syncPath) {
                $fromSync = Find-GarenaBundleRootUnderExtract -ExtractPath $syncPath
                if ($fromSync) { return $fromSync }
            }
        }
        catch { }
    }

    $bundleLeaf = Get-GarenaBundleLeafName
    foreach ($letter in @('Z', 'H', 'D', 'E', 'G', 'F', 'C')) {
        $driveRoot = "${letter}:\"
        if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) { continue }

        $preferred = Join-Path $driveRoot $bundleLeaf
        if (Test-Path -LiteralPath $preferred -PathType Container) {
            $fromPreferred = Find-GarenaBundleRootUnderExtract -ExtractPath $preferred
            if ($fromPreferred) { return $fromPreferred }
        }

        foreach ($child in @(Get-ChildItem -LiteralPath $driveRoot -Directory -ErrorAction SilentlyContinue)) {
            if ($child.Name -ieq $bundleLeaf) { continue }
            if (-not (Test-Path -LiteralPath (Join-Path $child.FullName 'Config') -PathType Container)) { continue }
            $fromChild = Find-GarenaBundleRootUnderExtract -ExtractPath $child.FullName
            if ($fromChild) { return $fromChild }
        }
    }

    return $null
}

function Get-ResolvedGarenaClientExePath {
    param([object[]]$Entries = @())
    $pathFile = Get-GarenaInstallPathFile
    if (Test-Path -LiteralPath $pathFile) {
        $line = (Get-Content -LiteralPath $pathFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try {
                $savedRoot = [System.IO.Path]::GetFullPath($line.Trim().Trim('"'))
                $clientDir = Resolve-GarenaClientDirUnderBundle -BundleRoot $savedRoot
                if (-not $clientDir) {
                    $bundle = Find-GarenaBundleRootUnderExtract -ExtractPath $savedRoot
                    if ($bundle) { $clientDir = Resolve-GarenaClientDirUnderBundle -BundleRoot $bundle }
                }
                if ($clientDir) {
                    $exe = Join-Path $clientDir $script:GarenaClientExeName
                    if (Test-Path -LiteralPath $exe) { return $exe }
                }
            }
            catch { }
        }
    }

    $bundleRoot = $null
    try {
        $bundleRoot = Find-GarenaBundleRootOnDisk -Entries $Entries
    }
    catch { }
    if ($bundleRoot) {
        $clientDir = Get-GarenaClientSourcePath -BundleRoot $bundleRoot
        if ($clientDir) {
            $exe = Join-Path $clientDir $script:GarenaClientExeName
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }

    return $null
}

function Install-GarenaClientSilent {
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
    $existing = Find-ExistingGarenaSyncPath -Entries $entries
    if ($existing) {
        $existing = Resolve-ManifestExtractPathString -Path $existing
        Write-GarenaInstallLog -LogPath $LogPath -Message "Garena already synced at: $existing"
        return $existing
    }

    if ([string]::IsNullOrWhiteSpace($TargetFolder)) {
        $TargetFolder = Resolve-GarenaSyncTargetFolder -Entries $entries
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

    Write-GarenaInstallLog -LogPath $LogPath -Message "Downloading $($script:GarenaBundleArchiveName) to $TargetFolder via R2 sync ..."
    $syncArgs = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $syncScript,
        '-InstallArchive', $script:GarenaBundleArchiveName,
        '-Quiet', '-NoGui'
    )
    $env:NEXTGPU_SYNC_TARGET = $TargetFolder

    & powershell.exe @syncArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Garena download/extract failed (exit $LASTEXITCODE). See sync-games-apps log under ProgramData\nextGPU\logs."
    }

    $entries = @(Read-DownloadManifestEntries -ManifestPath $ManifestPath)
    $extractPath = Find-ExistingGarenaSyncPath -Entries $entries
    if (-not $extractPath) {
        $bundleRoot = Find-GarenaBundleRootOnDisk -Entries $entries
        if ($bundleRoot) {
            $extractPath = $bundleRoot
        }
    }
    if (-not $extractPath) {
        $guessLeaf = Get-GarenaBundleLeafName
        $guess = Join-Path $TargetFolder $guessLeaf
        if (Test-Path -LiteralPath $guess -PathType Container) {
            $bundleRoot = Find-GarenaBundleRootUnderExtract -ExtractPath $guess
            if ($bundleRoot) { $extractPath = $bundleRoot }
        }
        if (-not $extractPath -and (Test-Path -LiteralPath $TargetFolder -PathType Container)) {
            foreach ($child in @(Get-ChildItem -LiteralPath $TargetFolder -Directory -ErrorAction SilentlyContinue)) {
                $bundleRoot = Find-GarenaBundleRootUnderExtract -ExtractPath $child.FullName
                if ($bundleRoot) {
                    $extractPath = $bundleRoot
                    break
                }
            }
        }
    }
    if (-not $extractPath) {
        throw 'Garena install finished but extract path was not found in manifest or on disk.'
    }

    $extractPath = Resolve-ManifestExtractPathString -Path $extractPath
    Write-GarenaInstallLog -LogPath $LogPath -Message "Garena synced at: $extractPath"
    return $extractPath
}
