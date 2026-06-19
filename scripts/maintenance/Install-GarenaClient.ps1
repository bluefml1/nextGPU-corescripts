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

function Test-GarenaBundleLayout {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    $clientExe = Join-Path $Dir (Join-Path $script:GarenaClientSubfolderName $script:GarenaClientExeName)
    $gxxDat = Join-Path $Dir 'Config\Garena\gxx\config\gxx.dat'
    return (Test-Path -LiteralPath $clientExe -PathType Leaf) -and (Test-Path -LiteralPath $gxxDat -PathType Leaf)
}

function Find-GarenaBundleRootUnderExtract {
    param([Parameter(Mandatory)]$ExtractPath)
    $ExtractPath = Resolve-ManifestExtractPathString -Path $ExtractPath
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
    return Join-Path $BundleRoot 'Config\Garena\gxx'
}

function Get-GarenaClientSourcePath {
    param([Parameter(Mandatory)][string]$BundleRoot)
    return Join-Path $BundleRoot $script:GarenaClientSubfolderName
}

function Get-GarenaProgramDataGxxPath {
    if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { return $null }
    return Join-Path $env:ProgramData 'Garena\gxx'
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
        $Entries = @(Read-DownloadManifestEntries)
    }
    $hit = Get-GarenaManifestEntry -Entries $Entries
    if (-not $hit) { return $null }
    $extractPath = Resolve-ManifestExtractPathString -Path $hit.ExtractPath
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

function Get-ResolvedGarenaClientExePath {
    param([object[]]$Entries = @())
    $pathFile = Get-GarenaInstallPathFile
    if (Test-Path -LiteralPath $pathFile) {
        $line = (Get-Content -LiteralPath $pathFile -ErrorAction SilentlyContinue | Select-Object -First 1)
        if (-not [string]::IsNullOrWhiteSpace($line)) {
            try {
                $exe = Join-Path ([System.IO.Path]::GetFullPath($line.Trim().Trim('"'))) 'Garena\Garena.exe'
                if (Test-Path -LiteralPath $exe) { return $exe }
            }
            catch { }
        }
    }
    if ($null -eq $Entries -or $Entries.Count -eq 0) {
        $Entries = @(Read-DownloadManifestEntries)
    }
    $syncPath = Find-ExistingGarenaSyncPath -Entries $Entries
    if ($syncPath) {
        $root = Find-GarenaBundleRootUnderExtract -ExtractPath $syncPath
        if ($root) {
            $exe = Join-Path (Get-GarenaClientSourcePath -BundleRoot $root) $script:GarenaClientExeName
            if (Test-Path -LiteralPath $exe) { return $exe }
        }
    }
    $driveLetter = Get-GamesDriveLetter -Entries $Entries
    if ($driveLetter) {
        $exe = Join-Path "${driveLetter}:\Garena\Garena" $script:GarenaClientExeName
        if (Test-Path -LiteralPath $exe) { return $exe }
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
        throw 'Garena install finished but extract path was not found in manifest or on disk.'
    }

    $extractPath = Resolve-ManifestExtractPathString -Path $extractPath
    Write-GarenaInstallLog -LogPath $LogPath -Message "Garena synced at: $extractPath"
    return $extractPath
}
