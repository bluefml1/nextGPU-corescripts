#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Playnite portable with disk-scan Steam/Epic import (no Playnite UI).
.DESCRIPTION
    Downloads official Playnite portable (e.g. 10.55.7z from GitHub) into a folder you choose.
    Extraction supports .zip/.7z/.rar using available tools (built-in ZIP, 7-Zip, or WinRAR/UnRAR).
    Install path is saved to PlayniteInstall.path in this repo folder.
    Library and settings live in the install folder - all Windows users share the same Playnite when using that path.
    Default run: portable install, Steam/Epic disk-scan config, and --updatelibraries only.
    Steam discovery: machine registry/paths first, then R2 sync manifest (sync-games-apps-downloaded.txt).
    Sunshine/Moonlight export and PlayNiteWatcher are separate; use -WithSunshine to include them in setup.
    With -WithSunshine, also pushes the Moonlight app list to AWS using domain.txt after export.
.PARAMETER WithSunshine
    Also run headless Sunshine export and PlayNiteWatcher install (and copy SunshineAppExport when -FullSetup).
.PARAMETER SkipInstall
    Do not download/extract Playnite.
.PARAMETER FullSetup
    Same as default plus Steam path detect and library/games.db stats. Sunshine extension/export only with -WithSunshine.
.PARAMETER SkipLibraryUpdate
    Do not run --updatelibraries.
.PARAMETER SkipSunshineExport
    Do not run Export-SunshineFromPlaynite.ps1.
.PARAMETER SkipWatcherInstall
    Do not run Install-PlayniteWatcher.ps1.
.PARAMETER SkipAwsPush
    Do not push Moonlight games to AWS after Sunshine export (default: push when -WithSunshine).
.PARAMETER SunshineConfigDir
    Sunshine config folder (default: C:\Program Files\Sunshine\config).
.PARAMETER LaunchPlaynite
    Open Playnite desktop at the end (default: off for zero-UI flow).
.PARAMETER PortablePackagePath
    Use a local portable archive (.7z/.zip/.rar) instead of downloading from GitHub.
.PARAMETER PlayniteInstallDir
    Install folder. If omitted, uses PlayniteInstall.path or the folder picker. A Playnite subfolder is always appended to the chosen path.
.PARAMETER PickInstallFolder
    Show install folder picker even if PlayniteInstall.path exists.
.PARAMETER SkipLegacyCleanup
    Do not remove AppData junctions, installer artifacts, or obsolete PlayniteProfile.path.
.PARAMETER SkipDesktopImport
    Do not run headless desktop app import from desktop-apps.allowlist.json (default: run when -WithSunshine).
.PARAMETER AllowlistPath
    Path to desktop-apps.allowlist.json (default: config\playnite\desktop-apps.allowlist.json).
.PARAMETER DesktopImportScanMode
    Desktop scan scope: Prompt (dialog), PickPath (drive or folder), PickFolder (alias), AllDrives (non-system only), or Default.
.PARAMETER DesktopScanPath
    Drive or folder to scan when DesktopImportScanMode is PickPath (skips picker).
.PARAMETER SkipEverythingInstall
    Do not use es.exe for allowlist search; use directory walk only. Otherwise setup downloads es.exe if needed and starts Everything.exe (-startup) when IPC is not ready.
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = "",
    [string]$SteamInstallPath = "",
    [switch]$SkipInstall,
    [switch]$FullSetup,
    [switch]$SkipLibraryUpdate,
    [switch]$WithSunshine,
    [switch]$SkipSunshineExport,
    [switch]$SkipWatcherInstall,
    [switch]$SkipAwsPush,
    [switch]$SkipSunshineExtension,
    [switch]$SkipDesktopImport,
    [switch]$LaunchPlaynite,
    [switch]$PickInstallFolder,
    [switch]$SkipLegacyCleanup,
    [string]$PortablePackagePath = "",
    [string]$SteamApiKey = "",
    [string]$SteamUserId = "",
    [string]$SunshineConfigDir = "",
    [string]$AllowlistPath = "",
    [ValidateSet('Prompt', 'PickPath', 'PickFolder', 'AllDrives', 'Default')]
    [string]$DesktopImportScanMode = "Prompt",
    [string]$DesktopScanPath = "",
    [switch]$SkipEverythingInstall,
    [int]$MaxWaitMinutes = 15
)

$ErrorActionPreference = "Stop"

$script:SetupScriptRoot = $PSScriptRoot
$bootstrapCommon = Join-Path $script:SetupScriptRoot "..\Playnite-Common.ps1"
# Walk up the directory tree until Playnite-Common.ps1 is found
if (-not (Test-Path -LiteralPath $bootstrapCommon)) {
    $checkPath = Split-Path -Path $script:SetupScriptRoot -Parent
    while ($checkPath) {
        $candidate = Join-Path $checkPath "Playnite-Common.ps1"
        if (Test-Path -LiteralPath $candidate) {
            $bootstrapCommon = $candidate
            break
        }
        $checkPath = Split-Path -Path $checkPath -Parent
    }
}

. $bootstrapCommon

$script:PlayNiteWatcherRepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $script:SetupScriptRoot

# Playnite-only by default; Sunshine/Moonlight is handled separately unless -WithSunshine.
# SunshineAppExport copy is enabled by default unless explicitly skipped.
if ($WithSunshine) {
    if (-not $PSBoundParameters.ContainsKey('SkipSunshineExport')) { $SkipSunshineExport = $false }
    if (-not $PSBoundParameters.ContainsKey('SkipWatcherInstall')) { $SkipWatcherInstall = $false }
}
else {
    if (-not $PSBoundParameters.ContainsKey('SkipSunshineExport')) { $SkipSunshineExport = $true }
    if (-not $PSBoundParameters.ContainsKey('SkipWatcherInstall')) { $SkipWatcherInstall = $true }
}
if (-not $PSBoundParameters.ContainsKey('SkipSunshineExtension')) { $SkipSunshineExtension = $false }

if ($WithSunshine) {
    if (-not $PSBoundParameters.ContainsKey('SkipDesktopImport')) { $SkipDesktopImport = $false }
}
else {
    if (-not $PSBoundParameters.ContainsKey('SkipDesktopImport')) { $SkipDesktopImport = $true }
}

$script:RunSunshinePipeline = (-not $SkipSunshineExport) -or (-not $SkipWatcherInstall)
$script:RunDesktopImport = (-not $SkipDesktopImport)
$script:RunAwsPush = $WithSunshine -and (-not $SkipAwsPush)

$script:SteamPluginId = "CB91DFC9-B977-43BF-8E70-55F46E410FAB"
$script:EpicPluginId = "00000002-DBD1-46C6-B5D0-B1BA559D10E4"
$script:PlayniteAppData = $null
$script:LogFile = Join-Path $script:PlayNiteWatcherRepoRoot "Setup-PlayniteSteam.log"
$script:PlayniteInstallPathFile = Join-Path $script:PlayNiteWatcherRepoRoot "PlayniteInstall.path"
$script:LegacyPlayniteProfilePathFile = Join-Path $script:PlayNiteWatcherRepoRoot "PlayniteProfile.path"

function Write-SetupLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
}

function Write-SetupStep {
    param(
        [int]$Step,
        [int]$Total,
        [string]$Name
    )
    Write-SetupLog "--- Step ${Step}/${Total}: $Name ---"
}

function Get-SavedPlayniteInstallPath {
    return Read-SavedPlayniteInstallPath -RepoRoot $script:PlayNiteWatcherRepoRoot
}

function Resolve-PlayniteInstallDirectory {
    if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDir)) {
        $expanded = Expand-PlayniteInstallDirectory -Path $PlayniteInstallDir
        Write-SetupLog "Install folder: $expanded"
        return $expanded
    }

    if (-not $PickInstallFolder) {
        $saved = Get-SavedPlayniteInstallPath
        if ($saved) {
            return $saved
        }
    }

    $defaultStart = ""
    $savedForDialog = Get-SavedPlayniteInstallPath
    if ($savedForDialog) {
        $defaultStart = $savedForDialog
    }

    Write-SetupLog "Choose a folder for Playnite portable (program + library data)."
    $picked = Show-PlayniteInstallFolderDialog `
        -InitialDirectory $defaultStart `
        -AnchorInitialToDriveRoot
    if ($picked) {
        if (Test-PlayniteInstallParentInsideWatcherScripts -ParentPath $picked -WatcherScriptsRoot $script:SetupScriptRoot) {
            throw @"
Playnite cannot be installed inside the PlayNiteWatcher scripts folder.
Pick a parent folder on a local drive (for example C:\Playnite or Z:\Playnite), then run setup again.
"@
        }

        $expanded = Expand-PlayniteInstallDirectory -Path $picked
        Write-SetupLog "Selected: $picked -> Install folder: $expanded"
        return $expanded
    }

    throw "Install folder picker cancelled. Run Setup-PlayniteSteam.bat again and choose a folder."
}

function Ensure-PlayniteDrivePaths {
    param(
        [string]$InstallDir,
        [string]$DownloadDir
    )

    foreach ($path in @($InstallDir, $DownloadDir)) {
        $root = [System.IO.Path]::GetPathRoot($path)
        if ($root -and -not (Test-Path -LiteralPath $root)) {
            throw "Drive not available: $root (required for Playnite path: $path)"
        }
    }

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Write-SetupLog "Created install folder: $InstallDir"
    }

    if (-not (Test-Path -LiteralPath $DownloadDir)) {
        New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
        Write-SetupLog "Created download folder: $DownloadDir"
    }
}

function Get-PlaynitePortableReleaseAsset {
    param(
        $ReleaseAssets,
        [string]$TagName
    )

    # Current releases use version.7z (e.g. 10.55.7z - not a .zip file)
    $asset = $ReleaseAssets | Where-Object { $_.name -match '^\d+(\.\d+)+\.7z$' } | Select-Object -First 1
    if ($asset) { return $asset }

    if (-not [string]::IsNullOrWhiteSpace($TagName)) {
        $expectedName = "$TagName.7z"
        $asset = $ReleaseAssets | Where-Object { $_.name -ieq $expectedName } | Select-Object -First 1
        if ($asset) { return $asset }
    }

    # Older GitHub releases used Playnite1044.zip etc.
    $asset = $ReleaseAssets | Where-Object { $_.name -match '^Playnite\d+\.zip$' } | Select-Object -First 1
    if ($asset) { return $asset }

    return $null
}

function Get-PlaynitePortableDownloadUrl {
    param([string]$TagName)

    if ([string]::IsNullOrWhiteSpace($TagName)) {
        return $null
    }
    $name = "$TagName.7z"
    return "https://github.com/JosefNemec/Playnite/releases/download/$TagName/$name"
}

function Invoke-SetupRestMethod {
    param(
        [string]$Uri,
        [hashtable]$Headers = @{},
        [int]$MaxAttempts = 4
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($attempt -gt 1) {
                Write-SetupLog "API request attempt ${attempt}/${MaxAttempts}: $Uri"
            }
            return Invoke-RestMethod -Uri $Uri -Headers $Headers -UseBasicParsing
        }
        catch {
            $lastError = $_
            if ($attempt -eq $MaxAttempts) { break }
            $delay = [math]::Min(45, [math]::Pow(2, $attempt))
            Write-SetupLog ("Request failed: " + $_.Exception.Message + " - retry in ${delay}s") "WARN"
            Start-Sleep -Seconds $delay
        }
    }

    throw $lastError.Exception
}

function Test-PlaynitePortablePackageFile {
    param(
        [string]$Path,
        [long]$MinBytes = 10485760
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    $length = (Get-Item -LiteralPath $Path).Length
    return ($length -ge $MinBytes)
}

function Invoke-SetupFileDownload {
    param(
        [string]$Uri,
        [string]$OutFile,
        [int]$MaxAttempts = 5,
        [long]$MinBytes = 10485760
    )

    if (Test-PlaynitePortablePackageFile -Path $OutFile -MinBytes $MinBytes) {
        $sizeMb = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 1)
        Write-SetupLog "Using existing download ($sizeMb MB): $OutFile"
        return
    }

    if (Test-Path -LiteralPath $OutFile) {
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    }

    $outDir = Split-Path -Path $OutFile -Parent
    if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-SetupLog "Download attempt ${attempt}/${MaxAttempts}: $Uri"

        try {
            if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
                try {
                    Start-BitsTransfer -Source $Uri -Destination $OutFile -TransferType Download -ErrorAction Stop
                    if (Test-PlaynitePortablePackageFile -Path $OutFile -MinBytes $MinBytes) {
                        Write-SetupLog "Download complete (BITS): $OutFile"
                        return
                    }
                }
                catch {
                    Write-SetupLog ("BITS download failed: " + $_.Exception.Message) "WARN"
                    if (Test-Path -LiteralPath $OutFile) {
                        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
                    }
                }
            }

            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add('User-Agent', 'PlayNiteWatcher-Setup')
            try {
                $webClient.DownloadFile($Uri, $OutFile)
            }
            finally {
                $webClient.Dispose()
            }

            if (Test-PlaynitePortablePackageFile -Path $OutFile -MinBytes $MinBytes) {
                Write-SetupLog "Download complete: $OutFile"
                return
            }

            throw "Downloaded file is missing or smaller than expected ($MinBytes bytes minimum)."
        }
        catch {
            $lastError = $_
            if (Test-Path -LiteralPath $OutFile) {
                Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            }
            if ($attempt -eq $MaxAttempts) { break }

            $delay = [math]::Min(60, [math]::Pow(2, $attempt))
            Write-SetupLog ("Download failed: " + $_.Exception.Message + " - retry in ${delay}s") "WARN"
            Start-Sleep -Seconds $delay
        }
    }

    $hint = @"
GitHub download failed after $MaxAttempts attempt(s). Use a local archive instead:
  Setup-PlayniteSteam.bat -PortablePackagePath "C:\path\to\10.56.7z"
Or place the .7z under the Playnite install Download folder and run with -SkipInstall.
"@
    Write-SetupLog $hint "ERROR"
    throw $lastError.Exception
}

function Get-WinRarExecutable {
    $candidates = @(
        "${env:ProgramFiles}\WinRAR\WinRAR.exe",
        "${env:ProgramFiles}\WinRAR\UnRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\UnRAR.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    foreach ($cmd in @("winrar", "unrar", "rar")) {
        $fromPath = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($fromPath) {
            return $fromPath.Source
        }
    }
    return $null
}

function Invoke-ExternalArchiveExtract {
    param(
        [string]$ExtractorPath,
        [string]$ArchivePath,
        [string]$ExtractDir
    )

    $name = [System.IO.Path]::GetFileName($ExtractorPath).ToLowerInvariant()
    if ($name -eq "7z.exe" -or $name -eq "7z") {
        Write-SetupLog "Extracting with 7-Zip: $ExtractorPath"
        $proc = Start-Process -FilePath $ExtractorPath -ArgumentList @("x", $ArchivePath, "-o$ExtractDir", "-y") -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "7-Zip extraction failed (exit $($proc.ExitCode))."
        }
        return
    }

    if ($name -eq "winrar.exe") {
        Write-SetupLog "Extracting with WinRAR: $ExtractorPath"
        $target = $ExtractDir.TrimEnd('\') + "\"
        $proc = Start-Process -FilePath $ExtractorPath -ArgumentList @("x", "-ibck", "-y", $ArchivePath, $target) -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "WinRAR extraction failed (exit $($proc.ExitCode))."
        }
        return
    }

    if ($name -eq "unrar.exe" -or $name -eq "unrar" -or $name -eq "rar.exe" -or $name -eq "rar") {
        Write-SetupLog "Extracting with UnRAR/RAR: $ExtractorPath"
        $target = $ExtractDir.TrimEnd('\') + "\"
        $proc = Start-Process -FilePath $ExtractorPath -ArgumentList @("x", "-o+", $ArchivePath, $target) -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0) {
            throw "UnRAR/RAR extraction failed (exit $($proc.ExitCode))."
        }
        return
    }

    throw "Unsupported extractor: $ExtractorPath"
}

function Expand-PlaynitePortableArchive {
    param(
        [string]$ArchivePath,
        [string]$ExtractDir
    )

    if (-not (Test-Path -LiteralPath $ExtractDir)) {
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    }

    $ext = [System.IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()

    # Built-in ZIP extraction first.
    if ($ext -eq ".zip") {
        try {
            Write-SetupLog "Extracting ZIP with built-in Expand-Archive: $ArchivePath"
            Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDir -Force
            return
        }
        catch {
            Write-SetupLog "Expand-Archive failed; trying external extractor..." "WARN"
        }
    }

    # External extractor fallback for .zip/.7z/.rar
    $extractor = Get-7ZipExecutable
    if (-not $extractor) {
        $extractor = Get-WinRarExecutable
    }
    if (-not $extractor) {
        throw "No archive extractor found. Install 7-Zip or WinRAR/UnRAR to extract .zip/.7z/.rar archives."
    }

    if ($ext -notin @(".zip", ".7z", ".rar")) {
        Write-SetupLog "Unknown archive extension ($ext); attempting extraction with $extractor" "WARN"
    }

    Invoke-ExternalArchiveExtract -ExtractorPath $extractor -ArchivePath $ArchivePath -ExtractDir $ExtractDir
}

function Copy-PlaynitePortablePayload {
    param(
        [string]$ExtractDir,
        [string]$InstallDir
    )

    $sourceDir = $ExtractDir
    $nested = Get-ChildItem -LiteralPath $ExtractDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-PlayniteInstalledAt -InstallDir $_.FullName } |
        Select-Object -First 1

    if ($nested) {
        $sourceDir = $nested.FullName
        Write-SetupLog "Using nested portable folder: $sourceDir"
    }
    elseif (-not (Test-PlayniteInstalledAt -InstallDir $ExtractDir)) {
        throw "Playnite.DesktopApp.exe not found under extracted path: $ExtractDir"
    }

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }

    Write-SetupLog "Copying portable files to: $InstallDir"
    Get-ChildItem -LiteralPath $sourceDir -Force | ForEach-Object {
        $dest = Join-Path $InstallDir $_.Name
        if ($_.PSIsContainer) {
            if (Test-Path -LiteralPath $dest) {
                Remove-Item -LiteralPath $dest -Recurse -Force
            }
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Recurse -Force
        }
        else {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        }
    }
}

function Install-PlaynitePortableFromGitHub {
    param(
        [string]$InstallDir,
        [string]$LocalPackagePath
    )

    Write-SetupLog "Install-PlaynitePortable: target $InstallDir"
    $downloadDir = Get-PlayniteDownloadDir -InstallDir $InstallDir
    Ensure-PlayniteDrivePaths -InstallDir $InstallDir -DownloadDir $downloadDir

    if (Test-PlayniteInstalledAt -InstallDir $InstallDir) {
        if (Test-PlaynitePortableLayout -InstallDir $InstallDir) {
            Write-SetupLog "Playnite portable already present at $InstallDir"
            return
        }
        Write-SetupLog "Playnite found but installer artifacts detected; legacy cleanup will remove unins000.*" "WARN"
    }

    $package = $LocalPackagePath
    if ([string]::IsNullOrWhiteSpace($package)) {
        Write-SetupLog "Fetching latest Playnite portable release from GitHub..."
        $release = Invoke-SetupRestMethod -Uri "https://api.github.com/repos/JosefNemec/Playnite/releases/latest" -Headers @{
            "User-Agent" = "PlayNiteWatcher-Setup"
            Accept         = "application/vnd.github+json"
        }

        $asset = Get-PlaynitePortableReleaseAsset -ReleaseAssets $release.assets -TagName $release.tag_name
        if ($asset) {
            $package = Join-Path $downloadDir $asset.name
            $downloadUrl = $asset.browser_download_url
            Write-SetupLog "Portable package: $($asset.name)"
        }
        else {
            $fallbackName = "$($release.tag_name).7z"
            $downloadUrl = Get-PlaynitePortableDownloadUrl -TagName $release.tag_name
            if (-not $downloadUrl) {
                throw "No Playnite portable .7z found on release $($release.tag_name) (expected e.g. 10.55.7z)."
            }
            $package = Join-Path $downloadDir $fallbackName
            Write-SetupLog "Portable package (fallback URL): $fallbackName"
        }

        Write-SetupLog "Downloading from: $downloadUrl"
        Invoke-SetupFileDownload -Uri $downloadUrl -OutFile $package
    }
    elseif (-not (Test-Path -LiteralPath $package)) {
        throw "Portable package not found: $package"
    }

    $extractDir = Join-Path $downloadDir ("extract_" + [Guid]::NewGuid().ToString("N"))
    try {
        Expand-PlaynitePortableArchive -ArchivePath $package -ExtractDir $extractDir
        Copy-PlaynitePortablePayload -ExtractDir $extractDir -InstallDir $InstallDir
    }
    finally {
        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-PlayniteInstalledAt -InstallDir $InstallDir)) {
        throw "Playnite.DesktopApp.exe not found under $InstallDir after portable install."
    }
    if (-not (Test-PlaynitePortableLayout -InstallDir $InstallDir)) {
        Write-SetupLog "Warning: unins000.exe still present - Playnite may run as installed edition, not portable." "WARN"
    }
    else {
        Write-SetupLog "Playnite portable installed at $InstallDir"
    }
}

function Remove-LegacyPlayniteArtifacts {
    param([string]$InstallDir)

    Write-SetupLog "Remove-LegacyPlayniteArtifacts: cleaning old installer/junction artifacts"

    if (Test-Path -LiteralPath $script:LegacyPlayniteProfilePathFile) {
        Remove-Item -LiteralPath $script:LegacyPlayniteProfilePathFile -Force
        Write-SetupLog "Removed obsolete: $script:LegacyPlayniteProfilePathFile"
    }

    $appDataPlaynite = Join-Path $env:APPDATA "Playnite"
    if (Test-PathIsDirectoryJunction -Path $appDataPlaynite) {
        cmd.exe /c rmdir `"$appDataPlaynite`" 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $appDataPlaynite)) {
            Write-SetupLog "Removed AppData Playnite junction: $appDataPlaynite"
        }
        else {
            Write-SetupLog ('Could not remove AppData junction (run: rmdir ' + $appDataPlaynite + ')') "WARN"
        }
    }
    elseif (Test-Path -LiteralPath $appDataPlaynite) {
        Write-SetupLog "Per-user data still at $appDataPlaynite - copy into $InstallDir manually if needed (see readme)." "WARN"
    }

    $localPlaynite = $script:LocalPlayniteInstallDir
    if ((Test-Path -LiteralPath $localPlaynite) -and ($localPlaynite -ine $InstallDir)) {
        Write-SetupLog "Legacy per-user program folder exists: $localPlaynite (not removed)." "WARN"
    }

    foreach ($legacyFile in @("unins000.exe", "unins000.dat")) {
        $path = Join-Path $InstallDir $legacyFile
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Write-SetupLog "Removed installer artifact: $path"
        }
    }

    if (Test-Path -LiteralPath $script:LegacyPlayniteProfilePathFile) {
        $legacyProfile = (Get-Content -LiteralPath $script:LegacyPlayniteProfilePathFile -TotalCount 1 -ErrorAction SilentlyContinue)
        if (-not [string]::IsNullOrWhiteSpace($legacyProfile)) {
            $legacyProfile = Expand-PlayniteInstallDirectory -Path $legacyProfile.Trim()
            if ($legacyProfile -and ($legacyProfile -ine $InstallDir) -and (Test-Path -LiteralPath $legacyProfile)) {
                Write-SetupLog "Old shared profile folder still exists: $legacyProfile - merge into $InstallDir manually if needed." "WARN"
            }
        }
    }
}

function Set-PlayniteAppDataFromInstallDir {
    param([string]$InstallDir)
    $script:PlayniteAppData = Get-PlayniteDataDirectory -InstallDir $InstallDir
    Write-SetupLog "Playnite data directory (portable): $script:PlayniteAppData"
}

function Merge-JsonSettingsFile {
    param(
        [string]$TargetPath,
        [string]$TemplatePath,
        [hashtable]$Overrides = @{}
    )

    $template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $target = $null
    if (Test-Path -LiteralPath $TargetPath) {
        try {
            $target = Get-Content -LiteralPath $TargetPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            Write-SetupLog "Could not parse existing $TargetPath; recreating from template." "WARN"
        }
    }
    if (-not $target) {
        $target = $template
    }

    foreach ($prop in $template.PSObject.Properties) {
        $target.$($prop.Name) = $prop.Value
    }
    foreach ($key in $Overrides.Keys) {
        $target.$key = $Overrides[$key]
    }

    $dir = Split-Path -Path $TargetPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $json = $target | ConvertTo-Json -Depth 20
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($TargetPath, $json, $utf8NoBom)
}

function Initialize-PlayniteUserData {
    param([string]$PlayniteExe)

    Write-SetupLog "Initialize-PlayniteUserData: $script:PlayniteAppData"

    $libraryDb = Get-PlayniteLibraryGamesDbPath -DataDirectory $script:PlayniteAppData
    if (Test-Path -LiteralPath $libraryDb) {
        Write-SetupLog "Playnite library database already present; skipping bootstrap launch."
        return
    }

    $libraryDir = Split-Path -Path $libraryDb -Parent
    if (-not (Test-Path -LiteralPath $libraryDir)) {
        New-Item -ItemType Directory -Path $libraryDir -Force | Out-Null
    }

    Write-SetupLog "Bootstrap launch to create library database (safe mode, wizard skipped via config)..."
    $initArgs = @("--startdesktop", "--hidesplashscreen", "--safestartup", "--nolibupdate")
    $init = Start-PlayniteProcess -PlayniteExe $PlayniteExe -ArgumentList $initArgs -PassThru

    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-Path -LiteralPath $libraryDb) {
            Write-SetupLog "Library database created: $libraryDb"
            break
        }
        if ($init.HasExited) {
            Write-SetupLog "Playnite exited during bootstrap."
            break
        }
    }

    Stop-PlayniteProcess -PlayniteExe $PlayniteExe
    if (-not $init.HasExited) {
        try { $init.WaitForExit(10000) } catch { }
    }

    if (-not (Test-Path -LiteralPath $libraryDb)) {
        Write-SetupLog "Library database was not created. Playnite may need a one-time manual launch." "WARN"
    }
    else {
        Write-SetupLog "Bootstrap launch finished."
    }
}

function Stop-PlayniteProcess {
    param([string]$PlayniteExe)
    Stop-PlayniteApplication -PlayniteExe $PlayniteExe
}

function Install-SunshineAppExportExtension {
    param([string]$PlayniteExe)

    Write-SetupLog "Install-SunshineAppExport: copying from repo into Playnite Extensions folder"

    $source = Join-Path $script:PlayNiteWatcherRepoRoot "SunshineAppExport"
    $playniteRoot = Split-Path -Path $PlayniteExe -Parent
    $dest = Join-Path $playniteRoot "Extensions\SunshineAppExport"
    $legacyAppDataExt = Join-Path $env:APPDATA "Playnite\Extensions\SunshineAppExport"

    if (-not (Test-Path -LiteralPath (Join-Path $source "SunshineAppExport.psm1"))) {
        Write-SetupLog "SunshineAppExport not found beside script: $source" "WARN"
        return
    }

    Stop-PlayniteProcess -PlayniteExe $PlayniteExe

    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }

    $destParent = Split-Path -Path $dest -Parent
    if (-not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    try {
        Get-ChildItem -LiteralPath $source -Force | Where-Object { $_.Name -ne '.git' } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $dest $_.Name) -Recurse -Force
        }
    }
    catch {
        Write-SetupLog "Could not copy Sunshine App Export to $dest. Run as Administrator if needed." "ERROR"
        throw
    }

    Write-SetupLog "Copied Sunshine App Export to: $dest"

    if (Test-Path -LiteralPath $legacyAppDataExt) {
        Remove-Item -LiteralPath $legacyAppDataExt -Recurse -Force -ErrorAction SilentlyContinue
        Write-SetupLog "Removed legacy AppData extension copy: $legacyAppDataExt"
    }
}

function Set-PlayniteBootstrapConfig {
    param(
        [string]$SteamUserIdParam,
        [string]$SteamApiKeyParam
    )

    Write-SetupLog "Set-PlayniteBootstrapConfig: disk-scan mode (installed games only, no Steam/Epic login)"

    $configTemplate = Join-Path $script:PlayNiteWatcherRepoRoot "config\playnite\config.template.json"
    $steamTemplate = Join-Path $script:PlayNiteWatcherRepoRoot "config\playnite\steam-config.template.json"
    $epicTemplate = Join-Path $script:PlayNiteWatcherRepoRoot "config\playnite\epic-config.template.json"
    foreach ($path in @($configTemplate, $steamTemplate, $epicTemplate)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Missing template: $path"
        }
    }

    $playniteConfig = Join-Path $script:PlayniteAppData "config.json"
    Merge-JsonSettingsFile -TargetPath $playniteConfig -TemplatePath $configTemplate

    $steamOverrides = @{}
    if (-not [string]::IsNullOrWhiteSpace($SteamUserIdParam)) {
        $steamOverrides["UserId"] = $SteamUserIdParam.Trim()
        $steamOverrides["ConnectAccount"] = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($SteamApiKeyParam)) {
        $steamOverrides["IsPrivateAccount"] = $true
        $steamOverrides["ConnectAccount"] = $true
        if ([string]::IsNullOrWhiteSpace($SteamUserIdParam)) {
            Write-SetupLog "SteamApiKey set without SteamUserId; private-account import may fail until UserId is set in Playnite." "WARN"
        }
        Write-SetupLog "Steam API key provided for online library sync. Save the key once in Playnite UI if prompted." "WARN"
    }

    $steamConfigDir = Join-Path $script:PlayniteAppData "ExtensionsData\$($script:SteamPluginId)"
    $steamConfigPath = Join-Path $steamConfigDir "config.json"
    Merge-JsonSettingsFile -TargetPath $steamConfigPath -TemplatePath $steamTemplate -Overrides $steamOverrides

    $epicConfigDir = Join-Path $script:PlayniteAppData "ExtensionsData\$($script:EpicPluginId)"
    $epicConfigPath = Join-Path $epicConfigDir "config.json"
    Merge-JsonSettingsFile -TargetPath $epicConfigPath -TemplatePath $epicTemplate

    Write-SetupLog "Wrote Playnite config: $playniteConfig"
    Write-SetupLog "Wrote Steam library config: $steamConfigPath"
    Write-SetupLog "Wrote Epic library config: $epicConfigPath"
}

function Start-PlayniteDesktop {
    param([string]$PlayniteExe)

    Write-SetupLog "Start-PlayniteDesktop: opening Playnite"
    if (Test-IsAdministrator) {
        Write-SetupLog "Setup is elevated; launching Playnite at limited (non-admin) run level."
    }

    Stop-PlayniteProcess -PlayniteExe $PlayniteExe

    $args = @("--startdesktop", "--hidesplashscreen")
    Write-SetupLog "Launching: $PlayniteExe $($args -join ' ')"
    Start-PlayniteProcess -PlayniteExe $PlayniteExe -ArgumentList $args | Out-Null
    Write-SetupLog "Playnite started. All Windows users should launch this same path for one shared library."
}

function Start-PlayniteLibraryUpdate {
    param(
        [string]$PlayniteExe,
        [int]$WaitMinutes,
        [string]$SteamInstallPathParam = ""
    )

    Write-SetupLog "Start-PlayniteLibraryUpdate: waiting up to $WaitMinutes minute(s) for Steam/Epic import in playnite.log"

    $steamLog = { param($Message, $Level) Write-SetupLog $Message $Level }
    $steamResolved = Ensure-PlayniteSteamForLibraryScan `
        -WatcherRoot $script:PlayNiteWatcherRepoRoot `
        -OverridePath $SteamInstallPathParam `
        -LogAction $steamLog
    if ($steamResolved) {
        Write-SetupLog "Steam ready for library scan ($($steamResolved.Source)): $($steamResolved.Path)"
    }

    Stop-PlayniteProcess -PlayniteExe $PlayniteExe

    $playniteLog = Join-Path $script:PlayniteAppData "playnite.log"
    $startedAfter = Get-Date
    $args = @("--startdesktop", "--hidesplashscreen", "--updatelibraries")
    Write-SetupLog "Starting library update: $PlayniteExe $($args -join ' ')"
    Start-PlayniteProcess -PlayniteExe $PlayniteExe -ArgumentList $args | Out-Null

    $logAction = { param($Message, $Level) Write-SetupLog $Message $Level }
    $importOk = Wait-PlayniteLibraryImportInLog -LogPath $playniteLog -StartedAfter $startedAfter `
        -TimeoutMinutes $WaitMinutes -LogAction $logAction

    Stop-PlayniteProcess -PlayniteExe $PlayniteExe

    if (-not $importOk) {
        Write-SetupLog "Steam/Epic disk import did not complete in log. Ensure Steam/Epic are installed with games on disk, then run Update-PlayniteLibraries.ps1." "WARN"
    }
}

function Get-PlayniteLibraryStats {
    Write-SetupLog "Get-PlayniteLibraryStats: checking library LiteDB (games.db)"

    try {
        return Get-PlayniteLibraryGameStats -DataDirectory $script:PlayniteAppData
    }
    catch {
        Write-SetupLog ('library read failed: ' + $_.Exception.Message) "WARN"
        $dbPath = Get-PlayniteLibraryGamesDbPath -DataDirectory $script:PlayniteAppData
        return @{
            DbExists   = (Test-Path -LiteralPath $dbPath)
            TotalGames = -1
            SteamGames = -1
            EpicGames  = -1
            DbSizeKb   = if (Test-Path -LiteralPath $dbPath) {
                [math]::Round((Get-Item -LiteralPath $dbPath).Length / 1KB, 1)
            }
            else { 0 }
        }
    }
}

function Invoke-HeadlessSunshinePipeline {
    param(
        [string]$PlayniteInstallDirParam,
        [string]$SunshineConfigDirParam,
        [string]$AllowlistPathParam = ""
    )

    $exportScript = Join-Path $script:PlayNiteWatcherRepoRoot "Export-SunshineFromPlaynite.ps1"
    $installScript = Join-Path $script:PlayNiteWatcherRepoRoot "Install-PlayniteWatcher.ps1"
    $alreadyAdmin = Test-IsAdministrator

    if (-not $SkipSunshineExport) {
        if (-not (Test-Path -LiteralPath $exportScript)) {
            throw "Missing script: $exportScript"
        }
        Write-SetupLog "Running headless Sunshine export (in-process)..."
        if (-not (Get-Command Invoke-SunshineExportFromPlaynite -ErrorAction SilentlyContinue)) {
            . $exportScript
        }
        $exportParams = @{}
        if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDirParam)) {
            $exportParams.PlayniteInstallDir = $PlayniteInstallDirParam
        }
        if (-not [string]::IsNullOrWhiteSpace($SunshineConfigDirParam)) {
            $exportParams.SunshineConfigDir = $SunshineConfigDirParam
        }
        if (-not [string]::IsNullOrWhiteSpace($AllowlistPathParam)) {
            $exportParams.AllowlistPath = $AllowlistPathParam
        }
        $exportParams.SkipWatcherInstall = $true
        Invoke-SunshineExportFromPlaynite @exportParams
    }
    else {
        Write-SetupLog "Skipped (-SkipSunshineExport)."
    }

    if (-not $SkipWatcherInstall) {
        if (-not (Test-Path -LiteralPath $installScript)) {
            throw "Missing script: $installScript"
        }
        Write-SetupLog "Running headless PlayNiteWatcher install (in-process)..."
        if (-not (Get-Command Invoke-PlayniteWatcherInstall -ErrorAction SilentlyContinue)) {
            . $installScript
        }
        $installParams = @{
            SkipExport = $true
        }
        if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDirParam)) {
            $installParams.PlayniteInstallDir = $PlayniteInstallDirParam
        }
        if (-not [string]::IsNullOrWhiteSpace($SunshineConfigDirParam)) {
            $installParams.SunshineConfigDir = $SunshineConfigDirParam
        }
        if (-not [string]::IsNullOrWhiteSpace($AllowlistPathParam)) {
            $installParams.AllowlistPath = $AllowlistPathParam
        }
        if ($alreadyAdmin) {
            $installParams.NoElevate = $true
        }
        Invoke-PlayniteWatcherInstall @installParams
    }
    else {
        Write-SetupLog "Skipped (-SkipWatcherInstall)."
    }
}

function Invoke-PushMoonlightGamesToAws {
    $coreRepo = Get-NextGpuCoreRepoRootFromWatcher -WatcherRoot $script:PlayNiteWatcherRepoRoot
    if (-not $coreRepo) {
        Write-SetupLog "AWS game push skipped: could not resolve nextGPU repo root." "WARN"
        return $false
    }

    $domainFile = Join-Path $coreRepo "domain.txt"
    if (-not (Test-Path -LiteralPath $domainFile)) {
        Write-SetupLog "AWS game push skipped: domain.txt not found (run RegisterMachine first)." "WARN"
        return $false
    }

    $computerName = $null
    $publicIp = $null
    foreach ($line in Get-Content -LiteralPath $domainFile) {
        if (-not $computerName -and $line -match "^COMPUTER_NAME=(.+)") { $computerName = $matches[1].Trim() }
        if (-not $publicIp -and $line -match "^PUBLIC_IP=(.+)") { $publicIp = $matches[1].Trim() }
    }

    if ([string]::IsNullOrWhiteSpace($computerName) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        Write-SetupLog "AWS game push skipped: domain.txt missing COMPUTER_NAME or PUBLIC_IP." "WARN"
        return $false
    }

    $updateScript = Join-Path $coreRepo "scripts\maintenance\Update-Games.ps1"
    if (-not (Test-Path -LiteralPath $updateScript)) {
        Write-SetupLog "AWS game push skipped: Update-Games.ps1 not found at $updateScript" "WARN"
        return $false
    }

    $mlSvc = Get-Service -Name 'moonlight-web' -ErrorAction SilentlyContinue
    if (-not $mlSvc -or $mlSvc.Status -ne 'Running') {
        Write-SetupLog "AWS game push skipped: moonlight-web service is not running." "WARN"
        return $false
    }

    $env:NEXTGPU_REPO_ROOT = $coreRepo
    Write-SetupLog "Pushing Moonlight games to AWS (computer_name=$computerName, publicIP=$publicIp)..."

    # Sunshine restart during export can lag Moonlight's app cache; wait and force refresh.
    Start-Sleep -Seconds 5

    $maxAttempts = 3
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        if ($attempt -gt 1) {
            Write-SetupLog "Retrying AWS game push (attempt $attempt/$maxAttempts)..." "WARN"
            Start-Sleep -Seconds 5
        }

        & $updateScript -ComputerName $computerName -PublicIP $publicIp -ForceMoonlightRefresh
        if ($LASTEXITCODE -eq 0) {
            Write-SetupLog "Moonlight games pushed to AWS successfully." "INFO"
            return $true
        }
    }

    Write-SetupLog "AWS game push failed after $maxAttempts attempt(s). Re-run Push Moonlight Games to AWS from the User Experience tab." "WARN"
    return $false
}

function Invoke-SetupDesktopAppImport {
    param(
        [string]$PlayniteInstallDir,
        [string]$AllowlistPathParam,
        [string]$ScanModeParam,
        [string]$ScanPathParam,
        [switch]$SkipEverythingInstallParam
    )

    $logAction = { param($Message, $Level) Write-SetupLog $Message $Level }

    $pickerStart = ""
    if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDir)) {
        $pickerStart = Split-Path -Path $PlayniteInstallDir -Parent
    }

    $scanRoots = Resolve-DesktopAppImportScanRoots `
        -Mode $ScanModeParam `
        -ScanPath $ScanPathParam `
        -PickerInitialDirectory $pickerStart `
        -RepoRoot $script:PlayNiteWatcherRepoRoot `
        -LogAction $logAction

    if (-not $scanRoots -or $scanRoots.Count -eq 0) {
        Write-SetupLog "Desktop allowlist import: no scan roots; skipped."
        return
    }

    $result = Invoke-HeadlessDesktopAppImport `
        -InstallDir $PlayniteInstallDir `
        -RepoRoot $script:PlayNiteWatcherRepoRoot `
        -AllowlistPath $AllowlistPathParam `
        -ScanRoots $scanRoots `
        -SkipEverythingInstall:$SkipEverythingInstallParam `
        -LogAction $logAction

    Write-SetupLog ("Desktop allowlist import: scanned {0} root(s), added {1}, updated {2}" -f `
            $result.RootsScanned, $result.Added, $result.Updated)
}

function Invoke-RegisterPlayniteLogonTask {
    param([string]$PlayniteInstallDirParam = '')

    if (-not (Test-IsAdministrator)) {
        Write-SetupLog "Skipped Playnite logon task registration (requires elevated setup)." "WARN"
        return
    }

    $registerScript = Join-Path $script:PlayNiteWatcherRepoRoot 'Register-PlayniteLogonTask.ps1'
    if (-not (Test-Path -LiteralPath $registerScript)) {
        Write-SetupLog "Register-PlayniteLogonTask.ps1 not found: $registerScript" "WARN"
        return
    }

    try {
        $regParams = @{}
        if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDirParam)) {
            $regParams.PlayniteInstallDir = $PlayniteInstallDirParam
        }
        & $registerScript @regParams
        Write-SetupLog "Registered nextGPU-PlayniteLogon (Playnite starts at user logon)."
    }
    catch {
        Write-SetupLog "Playnite logon task registration failed: $($_.Exception.Message)" "WARN"
    }
}

function Show-DiskScanNextSteps {
    param(
        [string]$PlayniteExe,
        [hashtable]$Stats
    )

    $text = @"
=== Setup complete (Playnite) ===
Playnite path: $PlayniteExe
Logon task: nextGPU-PlayniteLogon (Playnite DesktopApp at user logon)
Re-scan after new installs: .\Update-PlayniteLibraries.ps1
Optional online library sync: Add-ons - Extension settings - Libraries - Steam/Epic - Log in
"@
    if ($script:RunDesktopImport) {
        $text += @"

Desktop apps: imported from config\playnite\desktop-apps.allowlist.json (Everything search + drive/folder or all-drives scan during setup).
"@
    }
    if ($script:RunSunshinePipeline) {
        $text += @"

Sunshine/Moonlight (ran during setup): desktop + Steam/Epic export and PlayNiteWatcher install completed.
"@
        if ($script:RunAwsPush) {
            $text += @"
AWS: Moonlight game list was pushed to nextGPU servers using domain.txt.
"@
        }
    }
    else {
        $text += @"

Sunshine/Moonlight (optional, not run by default): .\Export-SunshineFromPlaynite.ps1 and .\Install-PlayniteWatcher.ps1
"@
    }
    Write-SetupLog $text "INFO"

    if ($Stats.TotalGames -eq 0) {
        Write-SetupLog "No games imported yet. Ensure Steam/Epic clients are installed and games have valid install manifests on disk." "WARN"
    }
}

# --- Main ---
$script:SetupPlayniteExe = $null
try {
    if (Test-Path -LiteralPath $script:LogFile) {
        Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
    }

    Write-SetupLog "=== Setup-PlayniteSteam started (portable) ==="
    Write-SetupLog "Repo root: $script:PlayNiteWatcherRepoRoot"
    Write-SetupLog "Log file: $script:LogFile"
    Write-SetupLog "Windows user: $env:USERNAME"
    Write-SetupLog "Parameters: SkipInstall=$SkipInstall FullSetup=$FullSetup SkipLegacyCleanup=$SkipLegacyCleanup PickInstallFolder=$PickInstallFolder"

    if (-not $FullSetup) {
        $script:SetupStepTotal = 7
        if ($script:RunDesktopImport) { $script:SetupStepTotal++ }
        if (-not $SkipSunshineExtension) { $script:SetupStepTotal++ }
        if ($script:RunSunshinePipeline) { $script:SetupStepTotal++ }
        if ($script:RunAwsPush) { $script:SetupStepTotal++ }
        if ($LaunchPlaynite) { $script:SetupStepTotal++ }
        $script:SetupStepTotal++ # Register Playnite logon task
        $step = 1

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Resolve Playnite portable install folder"
        $step++
        $playniteTargetDir = Resolve-PlayniteInstallDirectory
        $savedPath = Save-PlayniteInstallPath -RepoRoot $script:PlayNiteWatcherRepoRoot -InstallDir $playniteTargetDir
        Write-SetupLog "Saved install path: $script:PlayniteInstallPathFile -> $savedPath"
        Set-PlayniteAppDataFromInstallDir -InstallDir $playniteTargetDir

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Install Playnite portable"
        $step++
        if ($SkipInstall) {
            Write-SetupLog "Skipped (-SkipInstall)."
        }
        else {
            Install-PlaynitePortableFromGitHub -InstallDir $playniteTargetDir -LocalPackagePath $PortablePackagePath
            if (-not $SkipLegacyCleanup) {
                Remove-LegacyPlayniteArtifacts -InstallDir $playniteTargetDir
            }
        }

        $playniteDir = Resolve-PlayniteInstallDir -PreferredDir $playniteTargetDir
        $playniteExe = Get-PlayniteDesktopExe -InstallDir $playniteDir
        $script:SetupPlayniteExe = $playniteExe
        Set-PlayniteAppDataFromInstallDir -InstallDir $playniteDir
        Write-SetupLog "Using Playnite executable: $playniteExe"

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Grant Playnite rental access"
        $step++
        $aclOk = Grant-PlayniteRentalAccess -InstallDir $playniteDir -LogAction { param($Message, $Level) Write-SetupLog $Message $Level }
        if (-not $aclOk) {
            Write-SetupLog "Playnite rental ACL grant failed or skipped (requires elevated setup)." "WARN"
        }

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Write disk-scan Steam/Epic plugin config"
        $step++
        Set-PlayniteBootstrapConfig -SteamUserIdParam $SteamUserId -SteamApiKeyParam $SteamApiKey

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Install NextGPU Steam + Epic library extensions"
        $step++
        $extLogAction = { param($Message, $Level) Write-SetupLog $Message $Level }
        Install-PlayniteBuiltinLibraryExtensions -InstallDir $playniteDir -RepoRoot $script:PlayNiteWatcherRepoRoot -LogAction $extLogAction

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Initialize Playnite library database"
        $step++
        Initialize-PlayniteUserData -PlayniteExe $playniteExe

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Update game libraries (disk scan)"
        $step++
        if ($SkipLibraryUpdate) {
            Write-SetupLog "Skipped (-SkipLibraryUpdate)."
        }
        else {
            Start-PlayniteLibraryUpdate -PlayniteExe $playniteExe -WaitMinutes $MaxWaitMinutes -SteamInstallPathParam $SteamInstallPath
        }
        Stop-PlayniteProcess -PlayniteExe $playniteExe

        if ($script:RunDesktopImport) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Import desktop apps (drive/folder or all drives)"
            $step++
            Invoke-SetupDesktopAppImport `
                -PlayniteInstallDir $playniteDir `
                -AllowlistPathParam $AllowlistPath `
                -ScanModeParam $DesktopImportScanMode `
                -ScanPathParam $DesktopScanPath `
                -SkipEverythingInstallParam:$SkipEverythingInstall
        }
        else {
            Write-SetupLog "Skipped desktop allowlist import (-SkipDesktopImport or setup without -WithSunshine)."
        }

        if (-not $SkipSunshineExtension) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Copy Sunshine App Export extension"
            $step++
            Install-SunshineAppExportExtension -PlayniteExe $playniteExe
        }
        else {
            Write-SetupLog "Skipped Sunshine App Export extension (-SkipSunshineExtension)."
        }

        if ($script:RunSunshinePipeline) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Export to Sunshine and install PlayNiteWatcher"
            $step++
            Invoke-HeadlessSunshinePipeline -PlayniteInstallDirParam $playniteDir -SunshineConfigDirParam $SunshineConfigDir -AllowlistPathParam $AllowlistPath
        }
        else {
            Write-SetupLog "Skipped Sunshine/Moonlight steps (use -WithSunshine to include export + PlayNiteWatcher)."
        }

        if ($script:RunAwsPush) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Push Moonlight games to AWS"
            $step++
            Invoke-PushMoonlightGamesToAws | Out-Null
        }

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Register Playnite logon task"
        $step++
        Invoke-RegisterPlayniteLogonTask -PlayniteInstallDirParam $playniteDir

        Stop-PlayniteProcess -PlayniteExe $playniteExe
        Write-SetupLog "Ensured Playnite is closed so games.db is not locked (only one instance may use the library)."

        if ($LaunchPlaynite) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Launch Playnite"
            $step++
            Start-PlayniteDesktop -PlayniteExe $playniteExe
        }
        else {
            Write-SetupLog "Skipped Playnite UI launch (use -LaunchPlaynite to open desktop app)."
        }

        $stats = Get-PlayniteLibraryStats
        Show-DiskScanNextSteps -PlayniteExe $playniteExe -Stats $stats

        Write-SetupLog "=== All steps finished ==="
        Write-SetupLog "Playnite setup completed. All users launch: $playniteExe" "INFO"
    }
    else {
        $script:SetupStepTotal = 9
        if ($script:RunDesktopImport) { $script:SetupStepTotal++ }
        if (-not $SkipSunshineExtension) { $script:SetupStepTotal++ }
        if ($script:RunSunshinePipeline) { $script:SetupStepTotal++ }
        if ($script:RunAwsPush) { $script:SetupStepTotal++ }
        $script:SetupStepTotal++ # Register Playnite logon task
        $step = 1

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Resolve Playnite portable install folder"
        $step++
        $playniteTargetDir = Resolve-PlayniteInstallDirectory
        $savedPath = Save-PlayniteInstallPath -RepoRoot $script:PlayNiteWatcherRepoRoot -InstallDir $playniteTargetDir
        Write-SetupLog "Saved install path: $script:PlayniteInstallPathFile -> $savedPath"
        Set-PlayniteAppDataFromInstallDir -InstallDir $playniteTargetDir

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Detect Steam"
        $step++
        $steamResolved = Ensure-PlayniteSteamForLibraryScan `
            -WatcherRoot $script:PlayNiteWatcherRepoRoot `
            -OverridePath $SteamInstallPath `
            -LogAction { param($Message, $Level) Write-SetupLog $Message $Level }
        if ($steamResolved) {
            Write-SetupLog "Steam install path ($($steamResolved.Source)): $($steamResolved.Path)"
        }
        else {
            Write-SetupLog "Steam not detected on machine or in R2 manifest. Installed-game import may be limited." "WARN"
        }

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Install Playnite portable"
        $step++
        if ($SkipInstall) {
            Write-SetupLog "Skipped (-SkipInstall)."
        }
        else {
            Install-PlaynitePortableFromGitHub -InstallDir $playniteTargetDir -LocalPackagePath $PortablePackagePath
            if (-not $SkipLegacyCleanup) {
                Remove-LegacyPlayniteArtifacts -InstallDir $playniteTargetDir
            }
        }

        $playniteDir = Resolve-PlayniteInstallDir -PreferredDir $playniteTargetDir
        $playniteExe = Get-PlayniteDesktopExe -InstallDir $playniteDir
        $script:SetupPlayniteExe = $playniteExe
        Set-PlayniteAppDataFromInstallDir -InstallDir $playniteDir
        Write-SetupLog "Using Playnite executable: $playniteExe"

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Grant Playnite rental access"
        $step++
        $aclOk = Grant-PlayniteRentalAccess -InstallDir $playniteDir -LogAction { param($Message, $Level) Write-SetupLog $Message $Level }
        if (-not $aclOk) {
            Write-SetupLog "Playnite rental ACL grant failed or skipped (requires elevated setup)." "WARN"
        }

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Write disk-scan Steam/Epic plugin config"
        $step++
        Set-PlayniteBootstrapConfig -SteamUserIdParam $SteamUserId -SteamApiKeyParam $SteamApiKey

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Install NextGPU Steam + Epic library extensions"
        $step++
        $extLogAction = { param($Message, $Level) Write-SetupLog $Message $Level }
        Install-PlayniteBuiltinLibraryExtensions -InstallDir $playniteDir -RepoRoot $script:PlayNiteWatcherRepoRoot -LogAction $extLogAction

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Initialize Playnite library database"
        $step++
        Initialize-PlayniteUserData -PlayniteExe $playniteExe

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Update game libraries (disk scan)"
        $step++
        if ($SkipLibraryUpdate) {
            Write-SetupLog "Skipped (-SkipLibraryUpdate)."
        }
        else {
            Start-PlayniteLibraryUpdate -PlayniteExe $playniteExe -WaitMinutes $MaxWaitMinutes -SteamInstallPathParam $SteamInstallPath
        }
        Stop-PlayniteProcess -PlayniteExe $playniteExe

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Verify library import"
        $step++
        $stats = Get-PlayniteLibraryStats
        Write-SetupLog "library/games.db exists: $($stats.DbExists) (size $($stats.DbSizeKb) KB)"
        if ($stats.TotalGames -ge 0) {
            Write-SetupLog "Games in library/games.db: $($stats.TotalGames) total, $($stats.SteamGames) Steam, $($stats.EpicGames) Epic"
        }
        else {
            Write-SetupLog "Could not read game counts from library/games.db (LiteDB read failed)." "WARN"
        }

        if ($script:RunDesktopImport) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Import desktop apps (drive/folder or all drives)"
            $step++
            Invoke-SetupDesktopAppImport `
                -PlayniteInstallDir $playniteDir `
                -AllowlistPathParam $AllowlistPath `
                -ScanModeParam $DesktopImportScanMode `
                -ScanPathParam $DesktopScanPath `
                -SkipEverythingInstallParam:$SkipEverythingInstall
        }
        else {
            Write-SetupLog "Skipped desktop allowlist import (-SkipDesktopImport or setup without -WithSunshine)."
        }

        Show-DiskScanNextSteps -PlayniteExe $playniteExe -Stats $stats

        if (-not $SkipSunshineExtension) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Copy Sunshine App Export extension"
            $step++
            Install-SunshineAppExportExtension -PlayniteExe $playniteExe
        }
        else {
            Write-SetupLog "Skipped Sunshine App Export extension (-SkipSunshineExtension)."
        }

        if ($script:RunSunshinePipeline) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Export to Sunshine and install PlayNiteWatcher"
            $step++
            Invoke-HeadlessSunshinePipeline -PlayniteInstallDirParam $playniteDir -SunshineConfigDirParam $SunshineConfigDir -AllowlistPathParam $AllowlistPath
        }
        else {
            Write-SetupLog "Skipped Sunshine/Moonlight steps (use -WithSunshine to include export + PlayNiteWatcher)."
        }

        if ($script:RunAwsPush) {
            Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Push Moonlight games to AWS"
            $step++
            Invoke-PushMoonlightGamesToAws | Out-Null
        }

        Write-SetupStep -Step $step -Total $script:SetupStepTotal -Name "Register Playnite logon task"
        $step++
        Invoke-RegisterPlayniteLogonTask -PlayniteInstallDirParam $playniteDir

        Stop-PlayniteProcess -PlayniteExe $playniteExe
        Write-SetupLog "Ensured Playnite is closed so games.db is not locked (only one instance may use the library)."

        if ($LaunchPlaynite) {
            Start-PlayniteDesktop -PlayniteExe $playniteExe
        }

        Write-SetupLog "=== All steps finished ==="
        if ($stats.TotalGames -gt 0 -or $stats.DbSizeKb -gt 100) {
            Write-SetupLog "FullSetup completed (zero Playnite UI)." "INFO"
        }
        else {
            Write-SetupLog "FullSetup finished but library may be empty. Ensure Steam/Epic games are installed on disk, then re-run with -SkipInstall or Update-PlayniteLibraries.ps1." "WARN"
        }
    }
}
catch {
    Write-SetupLog "=== Setup failed ===" "ERROR"
    Write-SetupLog $_.Exception.Message "ERROR"
    if ($_.ScriptStackTrace) {
        Write-SetupLog $_.ScriptStackTrace "ERROR"
    }
    exit 1
}
finally {
    if ($script:SetupPlayniteExe -and -not $LaunchPlaynite) {
        Stop-PlayniteProcess -PlayniteExe $script:SetupPlayniteExe
        Write-SetupLog "Released games.db lock (stopped Playnite background instance)." "INFO"
    }
}
