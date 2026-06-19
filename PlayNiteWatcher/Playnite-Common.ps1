#Requires -Version 5.1
<#
.SYNOPSIS
    Shared Playnite portable path and install helpers for PlayNiteWatcher scripts.
#>

$script:PlaynitePortableFolderName = "Playnite"
$script:LiteDbAssemblyLoadedFrom = $null
$script:LocalPlayniteInstallDir = Join-Path $env:LOCALAPPDATA "Playnite"
$script:PlayniteInstallPathFileName = "PlayniteInstall.path"

function Get-NormalizedDirectoryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $trimmed = $Path.Trim().TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') {
        return "$($trimmed)\"
    }
    if (-not (Test-Path -LiteralPath $trimmed)) {
        return $trimmed
    }
    return ([System.IO.Path]::GetFullPath($trimmed)).TrimEnd('\')
}

function Expand-PlayniteInstallDirectory {
    param([string]$Path)

    $normalized = Get-NormalizedDirectoryPath -Path $Path
    if (-not $normalized) {
        return $null
    }

    $folderName = $script:PlaynitePortableFolderName
    if ((Split-Path -Path $normalized -Leaf) -ieq $folderName) {
        return $normalized
    }

    return [System.IO.Path]::Combine("$normalized\", $folderName).TrimEnd('\')
}

function Get-PlayniteInstallPathFile {
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw "RepoRoot is required."
    }
    return Join-Path $RepoRoot $script:PlayniteInstallPathFileName
}

function Read-SavedPlayniteInstallPath {
    param([string]$RepoRoot)

    $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $pathFile)) {
        return $null
    }

    $line = (Get-Content -LiteralPath $pathFile -TotalCount 1 -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $null
    }

    return Expand-PlayniteInstallDirectory -Path $line.Trim()
}

function Resolve-PlayniteInstallPathFromConfig {
    param(
        [string]$RepoRoot,
        [string]$OverrideDir = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($OverrideDir)) {
        return Expand-PlayniteInstallDirectory -Path $OverrideDir
    }

    return Read-SavedPlayniteInstallPath -RepoRoot $RepoRoot
}

function Test-PlayniteInstalledAt {
    param([string]$InstallDir)
    return Test-Path -LiteralPath (Join-Path $InstallDir "Playnite.DesktopApp.exe")
}

function Test-PlaynitePortableLayout {
    param([string]$InstallDir)

    if (-not (Test-PlayniteInstalledAt -InstallDir $InstallDir)) {
        return $false
    }
    $unins = Join-Path $InstallDir "unins000.exe"
    if (Test-Path -LiteralPath $unins) {
        return $false
    }
    return $true
}

function Get-7ZipExecutable {
    $candidates = @(
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    $fromPath = Get-Command 7z -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }
    return $null
}

function Get-PlayniteDownloadDir {
    param([string]$InstallDir)
    return Join-Path $InstallDir "Download"
}

function Normalize-FolderPickerPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $trimmed = $Path.Trim().TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') {
        return "$trimmed\"
    }

    if (Test-Path -LiteralPath $trimmed) {
        return ([System.IO.Path]::GetFullPath($trimmed)).TrimEnd('\')
    }

    return $trimmed
}

function Test-FolderPickerPathIsDriveRoot {
    param([string]$Path)

    $normalized = Normalize-FolderPickerPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    return ($normalized -match '^[A-Za-z]:\\$')
}

function Get-PlayniteFolderPickerInitialDirectory {
    param(
        [string]$PreferredPath,
        [switch]$AnchorToDriveRoot
    )

    if ($AnchorToDriveRoot -and -not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $driveRoot = [System.IO.Path]::GetPathRoot($PreferredPath)
        if ($driveRoot -and (Test-Path -LiteralPath $driveRoot)) {
            return $driveRoot.TrimEnd('\')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        if (Test-Path -LiteralPath $PreferredPath) {
            return (Normalize-FolderPickerPath -Path $PreferredPath)
        }

        $parent = Split-Path -Path $PreferredPath -Parent
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            return (Normalize-FolderPickerPath -Path $parent)
        }
    }

    $systemDrive = $env:SystemDrive
    if ($systemDrive -and (Test-Path -LiteralPath $systemDrive)) {
        return $systemDrive.TrimEnd('\')
    }

    return [Environment]::GetFolderPath('MyDocuments')
}

function Get-CommittedFolderBrowserPath {
    param(
        [System.Windows.Forms.FolderBrowserDialog]$Dialog
    )

    $path = $Dialog.SelectedPath
    $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    $field = $Dialog.GetType().GetField('selectedPath', $flags)
    if ($field) {
        $internalPath = [string]$field.GetValue($Dialog)
        if (-not [string]::IsNullOrWhiteSpace($internalPath)) {
            $path = $internalPath
        }
    }

    return Normalize-FolderPickerPath -Path $path
}

function Show-PlayniteFolderBrowserDialog {
    param(
        [string]$Description,
        [string]$InitialDirectory = "",
        [bool]$ShowNewFolderButton = $false,
        [switch]$AnchorInitialToDriveRoot
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    $start = Get-PlayniteFolderPickerInitialDirectory `
        -PreferredPath $InitialDirectory `
        -AnchorToDriveRoot:$AnchorInitialToDriveRoot

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $ShowNewFolderButton
    $dialog.RootFolder = [Environment+SpecialFolder]::MyComputer

    if (-not [string]::IsNullOrWhiteSpace($start)) {
        $selected = $start
        if (Test-FolderPickerPathIsDriveRoot -Path $selected) {
            $selected = Normalize-FolderPickerPath -Path $selected
        }
        if ((Test-Path -LiteralPath $selected) -or (Test-FolderPickerPathIsDriveRoot -Path $selected)) {
            $dialog.SelectedPath = $selected
        }
    }

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return Get-CommittedFolderBrowserPath -Dialog $dialog
}

function Test-PlayniteInstallParentInsideWatcherScripts {
    param(
        [string]$ParentPath,
        [string]$WatcherScriptsRoot
    )

    if ([string]::IsNullOrWhiteSpace($ParentPath) -or [string]::IsNullOrWhiteSpace($WatcherScriptsRoot)) {
        return $false
    }

    try {
        $parent = Normalize-FolderPickerPath -Path $ParentPath
        $watcher = Normalize-FolderPickerPath -Path $WatcherScriptsRoot
        if (-not $parent -or -not $watcher) {
            return $false
        }

        return $parent.Equals($watcher, [StringComparison]::OrdinalIgnoreCase) -or
            $parent.StartsWith("$watcher\", [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Show-PlayniteInstallFolderDialog {
    param(
        [string]$InitialDirectory = "",
        [switch]$AnchorInitialToDriveRoot
    )

    return Show-PlayniteFolderBrowserDialog `
        -Description "Select a parent folder for Playnite portable. A Playnite subfolder is created automatically inside your selection." `
        -InitialDirectory $InitialDirectory `
        -ShowNewFolderButton $true `
        -AnchorInitialToDriveRoot:$AnchorInitialToDriveRoot
}

function Resolve-PlayniteInstallDir {
    <#
        Resolves only the path from PlayniteInstall.path, -PlayniteInstallDir, or caller override.
        Does not fall back to %LocalAppData%\Playnite or Program Files.
    #>
    param([string]$PreferredDir)

    if ([string]::IsNullOrWhiteSpace($PreferredDir)) {
        return $null
    }

    $dir = Expand-PlayniteInstallDirectory -Path $PreferredDir
    if (Test-PlayniteInstalledAt -InstallDir $dir) {
        return $dir
    }

    return $dir
}

function Save-PlayniteInstallPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$InstallDir
    )

    $normalized = Expand-PlayniteInstallDirectory -Path $InstallDir
    if (-not $normalized) {
        throw "Invalid Playnite install path: $InstallDir"
    }
    $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
    Set-Content -LiteralPath $pathFile -Value $normalized -Encoding utf8 -NoNewline
    return $normalized
}

function Get-PlayniteDesktopExe {
    param([string]$InstallDir)

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw "Playnite install directory is not set. Run Setup-PlayniteSteam.bat and choose an install folder."
    }

    $exe = Join-Path $InstallDir "Playnite.DesktopApp.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Playnite.DesktopApp.exe not found at: $exe"
    }
    return $exe
}

function Get-PlayniteInstallRootFromExe {
    param([string]$PlayniteExe)

    if ([string]::IsNullOrWhiteSpace($PlayniteExe)) {
        throw "PlayniteExe is required."
    }
    if (-not (Test-Path -LiteralPath $PlayniteExe)) {
        throw "Playnite executable not found: $PlayniteExe"
    }
    return (Split-Path -Path $PlayniteExe -Parent)
}

function Start-PlayniteProcess {
    <#
        Launch Playnite with install folder as working directory.
        Uses Push-Location because Start-Process -WorkingDirectory requires PowerShell 6+.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlayniteExe,
        [string[]]$ArgumentList = @(),
        [ValidateSet('Normal', 'Hidden', 'Minimized', 'Maximized')]
        [string]$WindowStyle,
        [switch]$PassThru,
        [switch]$Wait
    )

    $playniteRoot = Get-PlayniteInstallRootFromExe -PlayniteExe $PlayniteExe
    Push-Location -LiteralPath $playniteRoot
    try {
        $params = @{
            FilePath = $PlayniteExe
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $params.ArgumentList = $ArgumentList
        }
        if ($PassThru) {
            $params.PassThru = $true
        }
        if ($Wait) {
            $params.Wait = $true
        }
        if ($PSBoundParameters.ContainsKey('WindowStyle')) {
            $params.WindowStyle = $WindowStyle
        }
        return Start-Process @params
    }
    finally {
        Pop-Location
    }
}

function Get-PlayniteDesktopExeFromConfig {
    param(
        [string]$RepoRoot,
        [string]$OverrideDir = ""
    )

    $installDir = Resolve-PlayniteInstallPathFromConfig -RepoRoot $RepoRoot -OverrideDir $OverrideDir
    if (-not $installDir) {
        $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
        throw "Playnite install path is not configured. Run Setup-PlayniteSteam.bat -PickInstallFolder or create: $pathFile"
    }

    return Get-PlayniteDesktopExe -InstallDir $installDir
}

function Get-PlayniteDataDirectory {
    param([string]$InstallDir)
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw "InstallDir is required."
    }
    return $InstallDir.TrimEnd('\')
}

function Test-PathIsDirectoryJunction {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

$script:PlayniteSteamPluginId = "CB91DFC9-B977-43BF-8E70-55F46E410FAB"
$script:PlayniteEpicPluginId = "00000002-DBD1-46C6-B5D0-B1BA559D10E4"
$script:PlayniteManualPluginId = "00000000-0000-0000-0000-000000000000"
$script:DesktopAppAllowlistFileName = "desktop-apps.allowlist.json"
# Used only when directory-walking the system/boot drive (e.g. C:\). Not applied to es.exe hits on other drives.
$script:DesktopScanSkipDirNames = @(
    'Windows', '$Recycle.Bin', 'node_modules', 'AppData', 'Packages',
    'Microsoft', 'WinSxS', 'System Volume Information'
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultSunshineConfigPath {
    return Join-Path $env:ProgramW6432 "Sunshine\config"
}

function Get-SqliteToolsDirectory {
    return Join-Path $PSScriptRoot "tools\sqlite"
}

function Get-SqliteToolsWinX64DownloadUrl {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $page = Invoke-WebRequest -Uri "https://www.sqlite.org/download.html" -UseBasicParsing
    $content = $page.Content

    $patterns = @(
        'href="(https://www\.sqlite\.org/\d+/sqlite-tools-win-x64-\d+\.zip)"',
        "'(\d{4}/sqlite-tools-win-x64-\d+\.zip)'",
        '(\d{4}/sqlite-tools-win-x64-\d+\.zip)'
    )

    foreach ($pattern in $patterns) {
        $match = [regex]::Match($content, $pattern)
        if ($match.Success) {
            $relativeOrAbsolute = $match.Groups[1].Value
            if ($relativeOrAbsolute -match '^https?://') {
                return $relativeOrAbsolute
            }
            return "https://www.sqlite.org/$relativeOrAbsolute"
        }
    }

    throw "Could not find sqlite-tools-win-x64 download link on sqlite.org."
}

function Install-Sqlite3ToolsPortable {
    param(
        [scriptblock]$LogAction
    )

    $toolsDir = Get-SqliteToolsDirectory
    $exePath = Join-Path $toolsDir "sqlite3.exe"
    if (Test-Path -LiteralPath $exePath) {
        return $exePath
    }

    if ($LogAction) {
        & $LogAction "Downloading SQLite tools (portable sqlite3.exe)..." "INFO"
    }

    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null

    $downloadUrl = Get-SqliteToolsWinX64DownloadUrl
    $zipPath = Join-Path $toolsDir "sqlite-tools-download.zip"
    $extractDir = Join-Path $toolsDir "_extract"

    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $sqliteExe = Get-ChildItem -Path $extractDir -Recurse -Filter "sqlite3.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $sqliteExe) {
        throw "Downloaded SQLite tools archive did not contain sqlite3.exe."
    }

    Copy-Item -LiteralPath $sqliteExe.FullName -Destination $exePath -Force

    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue

    if ($LogAction) {
        & $LogAction "Installed sqlite3.exe to: $exePath" "INFO"
    }

    return $exePath
}

function Get-Sqlite3Executable {
    param(
        [switch]$AllowBootstrap,
        [scriptblock]$LogAction
    )

    $fromPath = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }

    $bundled = Join-Path (Get-SqliteToolsDirectory) "sqlite3.exe"
    if (Test-Path -LiteralPath $bundled) {
        return $bundled
    }

    if ($AllowBootstrap) {
        return Install-Sqlite3ToolsPortable -LogAction $LogAction
    }

    return $null
}

function Ensure-Sqlite3Available {
    param(
        [scriptblock]$LogAction
    )

    $exe = Get-Sqlite3Executable -AllowBootstrap:$false -LogAction $LogAction
    if ($exe) {
        return $exe
    }

    if ($LogAction) {
        & $LogAction "sqlite3 not found on PATH; installing portable copy into tools\sqlite..." "INFO"
    }

    return Get-Sqlite3Executable -AllowBootstrap -LogAction $LogAction
}

function Expand-PlaynitePackageArchive {
    param(
        [string]$ArchivePath,
        [string]$ExtractDir,
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $ExtractDir)) {
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    }

    $ext = [System.IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()
    $archiveToExpand = $ArchivePath

    if ($ext -eq '.pext') {
        $archiveToExpand = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFileName($ArchivePath) + '.zip')
        Copy-Item -LiteralPath $ArchivePath -Destination $archiveToExpand -Force
        $ext = '.zip'
    }

    if ($ext -eq '.zip') {
        try {
            if ($LogAction) {
                & $LogAction "Extracting package: $ArchivePath"
            }
            Expand-Archive -LiteralPath $archiveToExpand -DestinationPath $ExtractDir -Force
            return
        }
        catch {
            if ($LogAction) {
                & $LogAction ('Expand-Archive failed: ' + $_.Exception.Message) 'WARN'
            }
        }
    }

    $sevenZip = Get-7ZipExecutable
    if (-not $sevenZip) {
        throw "Cannot extract $ArchivePath. Install 7-Zip or ensure .pext/.zip packages can be expanded."
    }

    if ($LogAction) {
        & $LogAction "Extracting with 7-Zip: $sevenZip"
    }
    $proc = Start-Process -FilePath $sevenZip -ArgumentList @('x', $archiveToExpand, "-o$ExtractDir", '-y') -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "7-Zip extraction failed (exit $($proc.ExitCode))."
    }
}

function Get-PlayniteExtensionPackageUrlFromManifest {
    param(
        [string]$ManifestUrl,
        [string]$FallbackPackageUrl
    )

    if ([string]::IsNullOrWhiteSpace($ManifestUrl)) {
        return $FallbackPackageUrl
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $yaml = (Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing).Content
        $urlMatches = [regex]::Matches($yaml, 'PackageUrl:\s*(\S+)')
        if ($urlMatches.Count -gt 0) {
            return $urlMatches[$urlMatches.Count - 1].Groups[1].Value
        }
    }
    catch {
        # Use pinned packageUrl from config when manifest fetch fails (offline).
    }

    return $FallbackPackageUrl
}

function Get-PlayniteExtensionManifestField {
    param(
        [string]$ManifestPath,
        [string]$FieldName
    )

    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        return $null
    }

    foreach ($line in (Get-Content -LiteralPath $ManifestPath -ErrorAction SilentlyContinue)) {
        if ($line -match ('^{0}:\s*(.+)$' -f [regex]::Escape($FieldName))) {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Test-PlayniteLibraryExtensionInstalled {
    param(
        [string]$InstallDir,
        [string]$ExtensionId = "",
        [string]$PluginId = ""
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($ExtensionId) -and [string]::IsNullOrWhiteSpace($PluginId)) {
        return $false
    }

    $extensionsDir = Join-Path $InstallDir 'Extensions'
    if (-not (Test-Path -LiteralPath $extensionsDir)) {
        return $false
    }

    if (-not [string]::IsNullOrWhiteSpace($ExtensionId)) {
        $byId = Join-Path $extensionsDir $ExtensionId
        $manifestPath = Join-Path $byId 'extension.yaml'
        if (Test-Path -LiteralPath $manifestPath) {
            $manifestId = Get-PlayniteExtensionManifestField -ManifestPath $manifestPath -FieldName 'Id'
            if ($manifestId -ieq $ExtensionId) {
                return $true
            }
        }
    }

    foreach ($folder in (Get-ChildItem -LiteralPath $extensionsDir -Directory -ErrorAction SilentlyContinue)) {
        $manifestPath = Join-Path $folder.FullName 'extension.yaml'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            continue
        }
        $manifestId = Get-PlayniteExtensionManifestField -ManifestPath $manifestPath -FieldName 'Id'
        if (-not [string]::IsNullOrWhiteSpace($ExtensionId) -and $manifestId -ieq $ExtensionId) {
            return $true
        }
        if (-not [string]::IsNullOrWhiteSpace($PluginId)) {
            $content = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction SilentlyContinue
            if ($content -and ($content -match [regex]::Escape($PluginId))) {
                return $true
            }
        }
    }

    return $false
}

function Install-PlayniteExtensionFromPextFile {
    param(
        [string]$InstallDir,
        [string]$PextPath,
        [string]$ExtensionId,
        [string]$PluginId = "",
        [scriptblock]$LogAction
    )

    if (Test-PlayniteLibraryExtensionInstalled -InstallDir $InstallDir -ExtensionId $ExtensionId -PluginId $PluginId) {
        if ($LogAction) {
            & $LogAction "Library extension already installed ($ExtensionId)."
        }
        return
    }

    if (-not (Test-Path -LiteralPath $PextPath)) {
        throw "Extension package not found: $PextPath"
    }

    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ('playnite_ext_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null

    try {
        Expand-PlaynitePackageArchive -ArchivePath $PextPath -ExtractDir $tempExtract -LogAction $LogAction

        $manifestFile = Get-ChildItem -LiteralPath $tempExtract -Filter 'extension.yaml' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $manifestFile) {
            throw "extension.yaml not found inside package: $PextPath"
        }

        $extRoot = $manifestFile.Directory.FullName
        $manifestId = Get-PlayniteExtensionManifestField -ManifestPath $manifestFile.FullName -FieldName 'Id'
        $folderName = if (-not [string]::IsNullOrWhiteSpace($manifestId)) { $manifestId } else { $ExtensionId }
        if ([string]::IsNullOrWhiteSpace($folderName)) {
            throw "Could not determine extension folder name from package: $PextPath"
        }

        $extensionsDir = Join-Path $InstallDir 'Extensions'
        if (-not (Test-Path -LiteralPath $extensionsDir)) {
            New-Item -ItemType Directory -Path $extensionsDir -Force | Out-Null
        }

        $dest = Join-Path $extensionsDir $folderName
        if (Test-Path -LiteralPath $dest) {
            Remove-Item -LiteralPath $dest -Recurse -Force
        }

        Copy-Item -LiteralPath $extRoot -Destination $dest -Recurse -Force

        if (-not (Test-PlayniteLibraryExtensionInstalled -InstallDir $InstallDir -ExtensionId $folderName -PluginId $PluginId)) {
            throw "Extension install verification failed for $folderName at $dest"
        }

        if ($LogAction) {
            & $LogAction "Installed library extension: $dest"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempExtract) {
            Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Install-PlayniteBuiltinLibraryExtensions {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw 'InstallDir is required.'
    }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw 'RepoRoot is required.'
    }

    $configPath = Join-Path $RepoRoot 'config\playnite\builtin-library-extensions.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Missing extension config: $configPath"
    }

    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.extensions) {
        throw "No extensions defined in $configPath"
    }

    $downloadDir = Get-PlayniteDownloadDir -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $downloadDir)) {
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($entry in $config.extensions) {
        $name = $entry.name
        $extensionId = $entry.extensionId.ToString()
        $pluginId = if ($entry.pluginId) { $entry.pluginId.ToString() } else { "" }
        $fallbackUrl = $entry.packageUrl
        $manifestUrl = $entry.manifestUrl

        if (Test-PlayniteLibraryExtensionInstalled -InstallDir $InstallDir -ExtensionId $extensionId -PluginId $pluginId) {
            if ($LogAction) {
                & $LogAction "$name library extension already present; skipping download."
            }
            continue
        }

        $packageUrl = Get-PlayniteExtensionPackageUrlFromManifest -ManifestUrl $manifestUrl -FallbackPackageUrl $fallbackUrl
        if ([string]::IsNullOrWhiteSpace($packageUrl)) {
            throw "No package URL for $name library extension."
        }

        $fileName = [System.IO.Path]::GetFileName(($packageUrl -split '\?')[0])
        $localPext = Join-Path $downloadDir $fileName

        if (-not (Test-Path -LiteralPath $localPext)) {
            if ($LogAction) {
                & $LogAction "Downloading $name library extension: $packageUrl"
            }
            Invoke-WebRequest -Uri $packageUrl -OutFile $localPext -UseBasicParsing
        }
        elseif ($LogAction) {
            & $LogAction "Using cached $name extension package: $localPext"
        }

        Install-PlayniteExtensionFromPextFile -InstallDir $InstallDir -PextPath $localPext `
            -ExtensionId $extensionId -PluginId $pluginId -LogAction $LogAction
    }
}

function ConvertFrom-PlayniteLogTimestamp {
    param([string]$TimestampText)

    $text = $TimestampText.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    foreach ($format in @('dd-MM HH:mm:ss.fff', 'dd-MM HH:mm:ss')) {
        try {
            $parsed = [datetime]::ParseExact($text, $format, $null)
            return Get-Date -Year (Get-Date).Year -Month $parsed.Month -Day $parsed.Day `
                -Hour $parsed.Hour -Minute $parsed.Minute -Second $parsed.Second `
                -Millisecond $parsed.Millisecond
        }
        catch {
            continue
        }
    }

    return $null
}

function Test-PlayniteLogLineIsRecent {
    param(
        [string]$Line,
        [datetime]$StartedAfter
    )

    if ($Line -notmatch '^\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}') {
        return $false
    }

    $tsText = ($Line -split '\|', 2)[0].Trim()
    $ts = ConvertFrom-PlayniteLogTimestamp -TimestampText $tsText
    if (-not $ts) {
        return $false
    }

    return ($ts -ge $StartedAfter.AddSeconds(-2))
}

function Wait-PlayniteLibraryImportInLog {
    param(
        [string]$LogPath,
        [datetime]$StartedAfter,
        [int]$TimeoutMinutes,
        [scriptblock]$LogAction
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $sawSteamImport = $false
    $sawEpicImport = $false

    $write = {
        param([string]$Message, [string]$Level = "INFO")
        if ($LogAction) {
            & $LogAction $Message $Level
        }
    }

    & $write ("Watching {0} for Steam/Epic import (up to {1} min)..." -f $LogPath, $TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (-not (Test-Path -LiteralPath $LogPath)) { continue }

        foreach ($line in (Get-Content -LiteralPath $LogPath -Tail 300 -ErrorAction SilentlyContinue)) {
            if (-not (Test-PlayniteLogLineIsRecent -Line $line -StartedAfter $StartedAfter)) {
                continue
            }

            if ($line -match 'Importing games from Steam plugin') {
                $sawSteamImport = $true
                & $write 'Steam library import started.'
            }
            if ($line -match 'Importing games from Epic plugin') {
                $sawEpicImport = $true
                & $write 'Epic library import started.'
            }

            if ($line -match 'Setting Sorting Name for \d+ new games') {
                & $write 'Library import complete (metadata and sorting names finished).'
                return $true
            }
            if ($line -match 'Steam library import finished|Steam library update finished') {
                & $write 'Steam library import finished.'
                return $true
            }
            if ($line -match 'Epic library import finished|Epic library update finished') {
                & $write 'Epic library import finished.'
                return $true
            }
            if ($line -match 'Finished Library Install Size scan' -and ($sawSteamImport -or $sawEpicImport)) {
                & $write 'Library import complete (install size scan after plugin import).'
                return $true
            }
        }
    }

    if ($sawSteamImport -or $sawEpicImport) {
        $partialMsg = 'Import started in log but completion line not seen (Steam: {0}, Epic: {1}).' -f $sawSteamImport, $sawEpicImport
        & $write -Message $partialMsg -Level 'WARN'
        return $true
    }

    $timeoutMsg = 'No Steam/Epic import activity in log within {0} minute(s).' -f $TimeoutMinutes
    & $write -Message $timeoutMsg -Level 'WARN'
    return $false
}

function Get-PlayniteLibraryGamesDbPath {
    param(
        [string]$InstallDir = "",
        [string]$DataDirectory = ""
    )

    if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
        if ([string]::IsNullOrWhiteSpace($InstallDir)) {
            throw "Get-PlayniteLibraryGamesDbPath requires InstallDir or DataDirectory."
        }
        $DataDirectory = Get-PlayniteDataDirectory -InstallDir $InstallDir
    }

    return Join-Path (Join-Path $DataDirectory "library") "games.db"
}

function Test-PlayniteLiteDbDatabase {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 6) {
            return $false
        }

        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(15, $bytes.Length))
        if ($ascii.StartsWith("SQLite format 3")) {
            return $false
        }

        # Playnite 10 stores the Game collection in LiteDB (not SQLite).
        return ($bytes[5] -eq 0xFF)
    }
    catch {
        return $false
    }
}

function Get-PlayniteLiteDbInvalidReason {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return "missing"
    }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 6) {
            return "too_small"
        }

        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(15, $bytes.Length))
        if ($ascii.StartsWith("SQLite format 3")) {
            return "sqlite"
        }

        if ($bytes[5] -ne 0xFF) {
            return "not_litedb"
        }

        return $null
    }
    catch {
        if ($_.Exception.Message -match 'being used by another process') {
            return "locked"
        }
        return "unreadable"
    }
}

function Stop-PlayniteApplication {
    param(
        [string]$PlayniteExe = "",
        [string]$InstallDir = "",
        [int]$WaitSeconds = 20,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir) -and $PlayniteExe -and (Test-Path -LiteralPath $PlayniteExe)) {
        $InstallDir = Split-Path -Path $PlayniteExe -Parent
    }

    $processNames = @("Playnite.DesktopApp", "Playnite.FullscreenApp")
    $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)

    if (-not $Force -and $running.Count -gt 0 -and $PlayniteExe -and (Test-Path -LiteralPath $PlayniteExe)) {
        try {
            Start-PlayniteProcess -PlayniteExe $PlayniteExe -ArgumentList "--shutdown" -WindowStyle Hidden | Out-Null
        }
        catch { }

        $graceDeadline = [datetime]::UtcNow.AddSeconds([Math]::Min(12, $WaitSeconds))
        while ([datetime]::UtcNow -lt $graceDeadline) {
            $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
            if ($running.Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 500
        }
    }

    Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    if ($InstallDir) {
        try {
            $installPrefix = $InstallDir.TrimEnd('\') + '\'
            Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ExecutablePath -and
                    $_.ExecutablePath.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                    $_.Name -match '^Playnite\.'
                } |
                ForEach-Object {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
        }
        catch { }
    }

    $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 500
    }

    Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Move-PlayniteLibraryDatabaseAside {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DbPath,
        [string]$PlayniteExe = "",
        [string]$InstallDir = "",
        [int]$MaxAttempts = 6,
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $DbPath)) {
        return $null
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$DbPath.invalid-$stamp"
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($LogAction -and $attempt -gt 1) {
            & $LogAction "games.db still locked; force-stopping Playnite (attempt $attempt / $MaxAttempts)..." "WARN"
        }

        Stop-PlayniteApplication -PlayniteExe $PlayniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force
        Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 8))

        try {
            Move-Item -LiteralPath $DbPath -Destination $backupPath -Force -ErrorAction Stop
            if ($LogAction) {
                & $LogAction "Backed up invalid library to: $backupPath"
            }
            return $backupPath
        }
        catch {
            $lastError = $_
            if ($_.Exception.Message -notmatch 'being used by another process') {
                throw
            }
        }
    }

    throw "Could not move locked Playnite library database after $MaxAttempts attempt(s): $DbPath. $($lastError.Exception.Message)"
}

function Invoke-PlayniteLibraryDatabaseBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,
        [int]$MaxWaitSeconds = 90,
        [scriptblock]$LogAction
    )

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    $libraryDir = Split-Path -Path $dbPath -Parent

    if (-not (Test-Path -LiteralPath $libraryDir)) {
        New-Item -ItemType Directory -Path $libraryDir -Force | Out-Null
    }

    if ($LogAction) {
        & $LogAction "Bootstrapping Playnite library database: $dbPath"
    }

    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force

    $initArgs = @("--startdesktop", "--hidesplashscreen", "--safestartup", "--nolibupdate")
    $init = Start-PlayniteProcess -PlayniteExe $playniteExe -ArgumentList $initArgs -PassThru

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-PlayniteLiteDbDatabase -Path $dbPath) {
            if ($LogAction) {
                & $LogAction "Library database created: $dbPath"
            }
            break
        }
        if ($init.HasExited) {
            if ($LogAction) {
                & $LogAction "Playnite exited during library bootstrap." "WARN"
            }
            break
        }
    }

    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force
    if (-not $init.HasExited) {
        try { $init.WaitForExit(10000) } catch { }
    }

    return (Test-PlayniteLiteDbDatabase -Path $dbPath)
}

function Repair-PlayniteLibraryDatabaseIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir

    if ($LogAction) {
        & $LogAction "Force-stopping Playnite before library database check..."
    }
    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force
    Start-Sleep -Seconds 2

    if (Test-PlayniteLiteDbDatabase -Path $dbPath) {
        if ($LogAction) {
            & $LogAction "Playnite library database is valid after ensuring Playnite is closed: $dbPath"
        }
        return [PSCustomObject]@{
            Success              = $true
            Repaired             = $false
            NeedsLibraryUpdate   = $false
            DatabasePath         = $dbPath
            InvalidReason        = $null
        }
    }

    $reason = Get-PlayniteLiteDbInvalidReason -Path $dbPath
    $reasonText = if ($reason) { $reason } else { "unknown" }

    if ($LogAction) {
        $detail = switch ($reason) {
            "sqlite" { "SQLite (pre-Playnite 10) library at $dbPath" }
            "missing" { "library database missing at $dbPath" }
            "too_small" { "library database too small or empty at $dbPath" }
            "locked" { "library database locked at $dbPath" }
            default { "invalid library database at $dbPath ($reasonText)" }
        }
        & $LogAction "Repairing Playnite library: $detail" "WARN"
    }

    if (Test-Path -LiteralPath $dbPath) {
        $backupPath = Move-PlayniteLibraryDatabaseAside `
            -DbPath $dbPath `
            -PlayniteExe $playniteExe `
            -InstallDir $InstallDir `
            -LogAction $LogAction

        if ($backupPath -match '\.invalid-(\d{8}-\d{6})$') {
            $stamp = $Matches[1]
        }
        else {
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        }

        foreach ($suffix in @("-lock", ".backup")) {
            $sidecar = "$dbPath$suffix"
            if (Test-Path -LiteralPath $sidecar) {
                $sidecarBackup = "$sidecar.invalid-$stamp"
                try {
                    Move-Item -LiteralPath $sidecar -Destination $sidecarBackup -Force -ErrorAction Stop
                }
                catch {
                    if ($LogAction) {
                        & $LogAction "Could not move sidecar file $sidecar : $($_.Exception.Message)" "WARN"
                    }
                }
            }
        }
    }

    $bootOk = Invoke-PlayniteLibraryDatabaseBootstrap -InstallDir $InstallDir -LogAction $LogAction
    return [PSCustomObject]@{
        Success              = $bootOk
        Repaired             = $true
        NeedsLibraryUpdate   = $bootOk
        DatabasePath         = $dbPath
        InvalidReason        = $reasonText
    }
}

function Initialize-LiteDbFromPlayniteInstall {
    param([string]$InstallDir)

    if ($script:LiteDbAssemblyLoadedFrom -eq $InstallDir) {
        return
    }

    $dllPath = Join-Path $InstallDir "LiteDB.dll"
    if (-not (Test-Path -LiteralPath $dllPath)) {
        throw "LiteDB.dll not found in Playnite install folder: $InstallDir"
    }

    Add-Type -Path $dllPath
    $script:LiteDbAssemblyLoadedFrom = $InstallDir
}

function Get-PlayniteLiteDbConnectionString {
    param([string]$DbPath)

    # Match Playnite ItemCollection (Exclusive, no cache) so we do not fight its mapper/locks.
    return "Filename=$DbPath;Mode=Exclusive;Cache Size=0"
}

# LiteDB + PowerShell interop (use Set-LiteDbBsonField / Add-LiteDbBsonArrayItem only):
# 1) return , $bsonDocument  -- bare "return $doc" yields the first KeyValuePair, not the document
# 2) never -Value (FuncReturningBsonDocument)  -- argument lists enumerate IEnumerable returns
# 3) New-Object BsonValue -ArgumentList @(,$doc)  -- bare -ArgumentList $doc expands fields as ctor args
# 4) never return a document/array BsonValue from a function  -- assignment unwraps to KeyValuePair/document
# 5) do not type parameters as [LiteDB.BsonArray]  -- empty arrays bind as zero arguments

function Set-LiteDbBsonField {
    param(
        # Do not type as [LiteDB.BsonDocument]: IEnumerable binding can unwrap documents.
        [Parameter(Mandatory)]
        [object]$Document,
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    if ($Document -isnot [LiteDB.BsonDocument]) {
        throw "Set-LiteDbBsonField: expected LiteDB.BsonDocument, got $($Document.GetType().FullName)."
    }

    if (-not $script:LiteDbBsonDocumentIndexer) {
        $script:LiteDbBsonDocumentIndexer = [LiteDB.BsonDocument].GetProperty('Item', [type[]]@([string]))
        if (-not $script:LiteDbBsonDocumentIndexer) {
            throw 'LiteDB.BsonDocument string indexer not found.'
        }
    }

    if ($null -eq $Value) {
        $bson = [LiteDB.BsonValue]$null
    }
    elseif ($Value -is [LiteDB.BsonValue]) {
        $bson = $Value
    }
    elseif ($Value -is [LiteDB.BsonDocument] -or $Value -is [LiteDB.BsonArray]) {
        $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $Value)
    }
    elseif ($Value -is [guid]) {
        $bson = [LiteDB.BsonValue]$Value
    }
    elseif ($Value.GetType().IsGenericType -and $Value.GetType().Name -eq 'KeyValuePair`2') {
        $rebuilt = New-Object LiteDB.BsonDocument
        Set-LiteDbBsonField -Document $rebuilt -Name ([string]$Value.Key) -Value $Value.Value
        $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $rebuilt)
    }
    else {
        $bson = [LiteDB.BsonValue]$Value
    }

    $null = $script:LiteDbBsonDocumentIndexer.SetValue($Document, $bson, $Name)
}

function Add-LiteDbBsonArrayItem {
    param(
        # Do not type as [LiteDB.BsonArray]: an empty array enumerates to zero args ("empty collection").
        [Parameter(Mandatory)]
        [object]$Array,
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$Value
    )

    if ($Array -isnot [LiteDB.BsonArray]) {
        throw "Add-LiteDbBsonArrayItem: expected LiteDB.BsonArray, got $($Array.GetType().FullName)."
    }

    if ($null -eq $Value) {
        $bson = [LiteDB.BsonValue]$null
    }
    elseif ($Value -is [LiteDB.BsonValue]) {
        $bson = $Value
    }
    elseif ($Value -is [LiteDB.BsonDocument] -or $Value -is [LiteDB.BsonArray]) {
        $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $Value)
    }
    elseif ($Value -is [guid]) {
        $bson = [LiteDB.BsonValue]$Value
    }
    elseif ($Value.GetType().IsGenericType -and $Value.GetType().Name -eq 'KeyValuePair`2') {
        $rebuilt = New-Object LiteDB.BsonDocument
        Set-LiteDbBsonField -Document $rebuilt -Name ([string]$Value.Key) -Value $Value.Value
        $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $rebuilt)
    }
    else {
        $bson = [LiteDB.BsonValue]$Value
    }

    [void]$Array.Add($bson)
}

function Get-BsonValueAsGuid {
    param($Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsNull) {
            return ""
        }
        if ($Value.IsDocument) {
            $doc = $Value.AsDocument
            if ($doc.ContainsKey('$guid')) {
                return $doc['$guid'].AsString
            }
        }
        if ($Value.IsGuid) {
            return $Value.AsGuid.ToString()
        }
        if ($Value.IsString) {
            $text = $Value.AsString
            if ($text -match '^[0-9a-fA-F-]{36}$') {
                return $text
            }
        }
    }

    $text = $Value.ToString()
    if ($text -match '"\$guid"\s*,\s*"([0-9a-fA-F-]{36})"') {
        return $Matches[1]
    }
    if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
        return $Matches[1]
    }

    return ""
}

function Get-BsonValueAsString {
    param($Value)

    if ($null -eq $Value) {
        return ""
    }

    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsNull) {
            return ""
        }
        if ($Value.IsString) {
            return $Value.AsString
        }
    }

    return $Value.ToString()
}

function Get-PlayniteGameRecordsFromLiteDb {
    param(
        [string]$InstallDir = "",
        [string]$DataDirectory = "",
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir) -and [string]::IsNullOrWhiteSpace($DataDirectory)) {
        throw "Get-PlayniteGameRecordsFromLiteDb requires InstallDir or DataDirectory."
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = $DataDirectory
    }

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir -DataDirectory $DataDirectory
    if (-not (Test-Path -LiteralPath $dbPath)) {
        throw "Playnite library database not found: $dbPath"
    }
    if (-not (Test-PlayniteLiteDbDatabase -Path $dbPath)) {
        throw "Playnite library file is not a LiteDB database (Playnite 10+ format): $dbPath"
    }

    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir

    if ($LogAction) {
        & $LogAction "Reading games from LiteDB: $dbPath"
    }

    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)
    $records = New-Object System.Collections.Generic.List[object]

    try {
        $collection = $db.GetCollection("Game")
        foreach ($doc in $collection.FindAll()) {
            $id = Get-BsonValueAsGuid -Value $doc['_id']
            if ([string]::IsNullOrWhiteSpace($id)) {
                continue
            }

            [void]$records.Add([PSCustomObject]@{
                    Id               = $id
                    GameId           = Get-BsonValueAsString -Value $doc['GameId']
                    Name             = Get-BsonValueAsString -Value $doc['Name']
                    InstallDirectory = Get-BsonValueAsString -Value $doc['InstallDirectory']
                    PluginId         = Get-BsonValueAsGuid -Value $doc['PluginId']
                })
        }
    }
    finally {
        $db.Dispose()
    }

    return $records.ToArray()
}

function Get-PlayniteLibraryGameStats {
    param(
        [string]$InstallDir = "",
        [string]$DataDirectory = ""
    )

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir -DataDirectory $DataDirectory
    $stats = @{
        DbExists   = (Test-Path -LiteralPath $dbPath)
        TotalGames = 0
        SteamGames = 0
        EpicGames  = 0
        DbSizeKb   = 0
    }

    if (-not $stats.DbExists) {
        return $stats
    }

    $stats.DbSizeKb = [math]::Round((Get-Item -LiteralPath $dbPath).Length / 1KB, 1)
    if (-not (Test-PlayniteLiteDbDatabase -Path $dbPath)) {
        return $stats
    }

    $games = Get-PlayniteGameRecordsFromLiteDb -InstallDir $InstallDir -DataDirectory $DataDirectory
    $stats.TotalGames = $games.Count
    $stats.SteamGames = @($games | Where-Object { $_.PluginId -ieq $script:PlayniteSteamPluginId }).Count
    $stats.EpicGames = @($games | Where-Object { $_.PluginId -ieq $script:PlayniteEpicPluginId }).Count
    return $stats
}

function Get-ExportablePlayniteGames {
    param(
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    $rows = Get-PlayniteGameRecordsFromLiteDb -InstallDir $InstallDir -LogAction $LogAction
    $games = New-Object System.Collections.Generic.List[object]

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row.Id)) { continue }

        $sourceLabel = $null
        if ($row.PluginId -ieq $script:PlayniteSteamPluginId) {
            $sourceLabel = "Steam"
        }
        elseif ($row.PluginId -ieq $script:PlayniteEpicPluginId) {
            $sourceLabel = "Epic"
        }
        else {
            continue
        }

        [void]$games.Add([PSCustomObject]@{
                Id               = $row.Id.ToString()
                GameId           = if ($row.GameId) { $row.GameId.ToString() } else { "" }
                Name             = if ($row.Name) { $row.Name.ToString() } else { "" }
                InstallDirectory = if ($row.InstallDirectory) { $row.InstallDirectory.ToString() } else { "" }
                SourceLabel      = $sourceLabel
            })
    }

    return $games.ToArray()
}

function Get-DesktopAppAllowlistPath {
    param(
        [string]$RepoRoot,
        [string]$OverridePath = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return $OverridePath
    }

    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $RepoRoot
    return Join-Path $RepoRoot "config\playnite\$($script:DesktopAppAllowlistFileName)"
}

function Resolve-DesktopAppAllowlistPath {
    param(
        [string]$RepoRoot,
        [string]$OverridePath = ""
    )

    $path = Get-DesktopAppAllowlistPath -RepoRoot $RepoRoot -OverridePath $OverridePath
    if (Test-Path -LiteralPath $path) {
        return $path
    }

    $template = Join-Path $RepoRoot "config\playnite\desktop-apps.allowlist.json.template"
    if (Test-Path -LiteralPath $template) {
        return $template
    }

    return $path
}

function Get-AllowlistTypeDefinitions {
    return @(
        [PSCustomObject]@{ Type = 'Adobe';      DisplayName = 'Adobe Applications';      Base = 10000000; MinId = 10000001; MaxId = 10000100; MaxSlots = 100 }
        [PSCustomObject]@{ Type = 'Autodesk';   DisplayName = 'Autodesk Applications';   Base = 10000100; MinId = 10000101; MaxId = 10000200; MaxSlots = 100 }
        [PSCustomObject]@{ Type = 'ThirdParty'; DisplayName = 'Third-Party Applications'; Base = 10000200; MinId = 10000201; MaxId = 10000300; MaxSlots = 100 }
        [PSCustomObject]@{ Type = 'Games';      DisplayName = 'Games';                   Base = 10000300; MinId = 10000301; MaxId = 10000999; MaxSlots = 699 }
    )
}

function Get-AllowlistTypeDefinition {
    param([string]$Type)
    if ([string]::IsNullOrWhiteSpace($Type)) { return $null }
    $key = $Type.Trim()
    return Get-AllowlistTypeDefinitions | Where-Object { $_.Type -ieq $key } | Select-Object -First 1
}

function Get-AllowlistTypeFromNameId {
    param([string]$NameId)
    if ([string]::IsNullOrWhiteSpace($NameId)) { return $null }
    if ($NameId -notmatch '^\d+$') { return $null }
    $numeric = [long]$NameId
    foreach ($def in Get-AllowlistTypeDefinitions) {
        if ($numeric -ge $def.MinId -and $numeric -le $def.MaxId) {
            return $def.Type
        }
    }
    return $null
}

function Test-NameIdInAllowlistTypeRange {
    param(
        [string]$NameId,
        [string]$Type = ""
    )
    if ([string]::IsNullOrWhiteSpace($NameId) -or $NameId -notmatch '^\d+$') {
        return $false
    }
    $numeric = [long]$NameId
    if (-not [string]::IsNullOrWhiteSpace($Type)) {
        $def = Get-AllowlistTypeDefinition -Type $Type
        if ($null -eq $def) { return $false }
        return ($numeric -ge $def.MinId -and $numeric -le $def.MaxId)
    }
    return ($null -ne (Get-AllowlistTypeFromNameId -NameId $NameId))
}

function Resolve-AllowlistNameId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$SlotInput
    )

    $def = Get-AllowlistTypeDefinition -Type $Type
    if ($null -eq $def) {
        throw "Unknown allowlist type: $Type"
    }

    $digits = ($SlotInput -replace '\D', '').Trim()
    if ([string]::IsNullOrWhiteSpace($digits)) {
        throw "Name ID input must contain digits."
    }

    $numeric = [long]$digits
    if ($digits.Length -ge 8 -and $numeric -ge $def.MinId -and $numeric -le $def.MaxId) {
        return $numeric.ToString()
    }

    $slot = [int]($numeric % 1000)
    $suffixBase = 10000000
    if ($def.Type -ieq 'Games') {
        if ($slot -lt 1 -or $slot -gt $def.MaxSlots) {
            throw "Slot $slot is outside Games short-ID range 1-$($def.MaxSlots) or 301-999 (nameId $($def.MinId)-$($def.MaxId))."
        }
    }
    else {
        $minSlot = [int]($def.MinId - $suffixBase)
        $maxSlot = [int]($def.MaxId - $suffixBase)
        if ($slot -lt $minSlot -or $slot -gt $maxSlot) {
            throw "Slot $slot is outside $($def.Type) short-ID range $minSlot-$maxSlot (nameId $($def.MinId)-$($def.MaxId))."
        }
    }

    $suffixCandidate = $suffixBase + $slot
    if ($suffixCandidate -ge $def.MinId -and $suffixCandidate -le $def.MaxId) {
        return $suffixCandidate.ToString()
    }

    if ($def.Type -ieq 'Games') {
        $offsetCandidate = $def.Base + $slot
        if ($offsetCandidate -ge $def.MinId -and $offsetCandidate -le $def.MaxId) {
            return $offsetCandidate.ToString()
        }
    }

    throw "Resolved nameId for slot $slot is outside $($def.Type) range $($def.MinId)-$($def.MaxId). Use the type's short-ID range (Adobe 1-100, Autodesk 101-200, ThirdParty 201-300, Games 301-999)."
}

function Get-DesktopAppAllowlist {
    param(
        [string]$RepoRoot,
        [string]$AllowlistPath = ""
    )

    $path = Resolve-DesktopAppAllowlistPath -RepoRoot $RepoRoot -OverridePath $AllowlistPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Desktop app allowlist not found: $path (copy desktop-apps.allowlist.json.template to desktop-apps.allowlist.json)"
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed -or $null -eq $parsed.apps) {
        throw "Allowlist has no apps array: $path"
    }

    $apps = @($parsed.apps)
    $nameIds = @{}
    $exes = @{}
    $normalized = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $apps) {
        if ($null -eq $entry) { continue }
        $exe = if ($entry.exe) { $entry.exe.ToString().Trim() } else { "" }
        $nameId = if ($entry.nameId) { $entry.nameId.ToString().Trim() } else { "" }
        $title = if ($entry.title) { $entry.title.ToString().Trim() } else { "" }
        $type = if ($entry.type) { $entry.type.ToString().Trim() } else { "" }

        if ([string]::IsNullOrWhiteSpace($exe) -or [string]::IsNullOrWhiteSpace($nameId)) {
            throw "Each allowlist app requires exe and nameId: $path"
        }

        if ([string]::IsNullOrWhiteSpace($type)) {
            $type = Get-AllowlistTypeFromNameId -NameId $nameId
            if ([string]::IsNullOrWhiteSpace($type)) {
                throw "nameId $nameId is outside known type ranges and entry has no type field: $path"
            }
        }
        elseif (-not (Test-NameIdInAllowlistTypeRange -NameId $nameId -Type $type)) {
            throw "nameId $nameId is outside type $type range: $path"
        }

        $exeKey = $exe.ToLowerInvariant()
        if ($exes.ContainsKey($exeKey)) {
            Write-Warning "Allowlist: '$exe' shares the same executable name as another entry (Windows is case-insensitive). Each entry is kept; use nameId to distinguish in Sunshine."
        }
        if ($nameIds.ContainsKey($nameId)) {
            throw "Duplicate nameId in allowlist: $nameId"
        }

        $exes[$exeKey] = $true
        $nameIds[$nameId] = $true

        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        }

        [void]$normalized.Add([PSCustomObject]@{
                Exe    = $exe
                NameId = $nameId
                Title  = $title
                Type   = $type
            })
    }

    return $normalized.ToArray()
}

function Show-PlayniteFolderPicker {
    param(
        [string]$Description = "Select a folder",
        [string]$InitialDirectory = "",
        [switch]$AnchorInitialToDriveRoot
    )

    return Show-PlayniteFolderBrowserDialog `
        -Description $Description `
        -InitialDirectory $InitialDirectory `
        -ShowNewFolderButton $false `
        -AnchorInitialToDriveRoot:$AnchorInitialToDriveRoot
}

function Resolve-PlayNiteWatcherRepoRoot {
    param([string]$Candidate = "")

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        $Candidate = $PSScriptRoot
    }

    $dir = $Candidate.TrimEnd('\')
    for ($i = 0; $i -lt 6; $i++) {
        $allowlist = Join-Path $dir "config\playnite\$($script:DesktopAppAllowlistFileName)"
        if (Test-Path -LiteralPath $allowlist) {
            return $dir
        }

        $parent = Split-Path -Path $dir -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) {
            break
        }
        $dir = $parent
    }

    return $Candidate.TrimEnd('\')
}

$script:GamesAppsManifestImported = $false

function Get-NextGpuCoreRepoRootFromWatcher {
    param([string]$WatcherRoot = "")
    $watcher = Resolve-PlayNiteWatcherRepoRoot -Candidate $WatcherRoot
    try {
        return (Resolve-Path -LiteralPath (Join-Path $watcher '..') -ErrorAction Stop).Path
    }
    catch {
        return $null
    }
}

function Import-NextGpuGamesAppsManifest {
    param([string]$WatcherRoot = "")
    if ($script:GamesAppsManifestImported) { return $true }

    $coreRepo = Get-NextGpuCoreRepoRootFromWatcher -WatcherRoot $WatcherRoot
    if (-not $coreRepo) { return $false }

    $manifestScript = Join-Path $coreRepo 'scripts\maintenance\GamesApps-Manifest.ps1'
    if (-not (Test-Path -LiteralPath $manifestScript)) { return $false }

    if ([string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $env:NEXTGPU_REPO_ROOT = $coreRepo
    }

    . $manifestScript
    $script:GamesAppsManifestImported = $true
    return $true
}

function Test-PlayniteSteamClientPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $steamExe = Join-Path $Path 'steam.exe'
    if (-not (Test-Path -LiteralPath $steamExe -PathType Leaf)) { return $false }
    $hasUi = (Test-Path -LiteralPath (Join-Path $Path 'package')) -or (Test-Path -LiteralPath (Join-Path $Path 'steamui'))
    $hasApps = Test-Path -LiteralPath (Join-Path $Path 'steamapps') -PathType Container
    return ($hasUi -or $hasApps)
}

function Get-PlayniteSteamPathFromRegistry {
    $keyPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    foreach ($keyPath in $keyPaths) {
        try {
            $installPath = (Get-ItemProperty -LiteralPath $keyPath -Name InstallPath -ErrorAction Stop).InstallPath
            if ($installPath -and (Test-PlayniteSteamClientPath -Path $installPath.TrimEnd('\', '/'))) {
                return $installPath.TrimEnd('\', '/')
            }
        }
        catch { }
    }
    return $null
}

function Resolve-PlayniteSteamFromR2Manifest {
    param(
        [string]$WatcherRoot = "",
        [scriptblock]$LogAction = $null
    )

    $write = if ($LogAction) { $LogAction } else { { param($Message, $Level) } }
    if (-not (Import-NextGpuGamesAppsManifest -WatcherRoot $WatcherRoot)) {
        & $write 'R2 manifest helpers not available (GamesApps-Manifest.ps1 missing).' 'WARN'
        return $null
    }

    $entries = @(Read-DownloadManifestEntries)
    if ($entries.Count -eq 0) {
        & $write 'No R2 sync manifest entries (sync-games-apps-downloaded.txt).' 'WARN'
        return $null
    }

    $steamClients = @($entries | Where-Object { Test-ManifestEntryIsSteamClient $_ })
    foreach ($entry in $steamClients) {
        $extract = Get-ManifestEntryExtractPath -Entry $entry
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        if (-not (Test-Path -LiteralPath $extract -PathType Container)) {
            & $write "R2 Steam app extract missing on disk: $extract" 'WARN'
            continue
        }
        $full = [System.IO.Path]::GetFullPath($extract)
        if (Test-PlayniteSteamClientPath -Path $full) {
            return [PSCustomObject]@{ Path = $full; Source = 'R2Manifest' }
        }
        if (Get-Command Find-SteamClientPathUnderDirectory -ErrorAction SilentlyContinue) {
            $nested = Find-SteamClientPathUnderDirectory -Root $full
            if ($nested) {
                return [PSCustomObject]@{ Path = $nested; Source = 'R2ManifestNested' }
            }
        }
        if (Test-Path -LiteralPath (Join-Path $full 'steam.exe') -PathType Leaf) {
            return [PSCustomObject]@{ Path = $full; Source = 'R2Manifest' }
        }
    }

    if (Get-Command Get-SteamInstallCandidatesFromManifest -ErrorAction SilentlyContinue) {
        foreach ($candidate in @(Get-SteamInstallCandidatesFromManifest -Entries $entries)) {
            if (Test-PlayniteSteamClientPath -Path $candidate) {
                return [PSCustomObject]@{ Path = $candidate; Source = 'R2Candidate' }
            }
        }
    }

    return $null
}

function Resolve-PlayniteSteamInstallPath {
    <#
        Prefer Steam already on the machine (registry / common folders), then R2-downloaded Steam from sync manifest.
    #>
    param(
        [string]$OverridePath = "",
        [string]$WatcherRoot = "",
        [scriptblock]$LogAction = $null
    )

    $write = if ($LogAction) { $LogAction } else { { param($Message, $Level) } }

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $override = $OverridePath.Trim().TrimEnd('\')
        if (Test-PlayniteSteamClientPath -Path $override) {
            & $write "Steam from -SteamInstallPath: $override" 'INFO'
            return [PSCustomObject]@{ Path = $override; Source = 'Override' }
        }
        & $write "Override Steam path invalid: $override" 'WARN'
    }

    $fromReg = Get-PlayniteSteamPathFromRegistry
    if ($fromReg) {
        & $write "Steam on machine (registry): $fromReg" 'INFO'
        return [PSCustomObject]@{ Path = $fromReg; Source = 'Registry' }
    }

    $commonPaths = @(
        'C:\Program Files (x86)\Steam',
        'C:\Program Files\Steam',
        'D:\Steam', 'D:\Games\Steam',
        'E:\Steam', 'E:\Games\Steam',
        'F:\Steam', 'F:\Games\Steam'
    )
    foreach ($base in $commonPaths) {
        try {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            $resolved = ([System.IO.Path]::GetFullPath($base)).TrimEnd('\')
            if (Test-PlayniteSteamClientPath -Path $resolved) {
                & $write "Steam on machine (common path): $resolved" 'INFO'
                return [PSCustomObject]@{ Path = $resolved; Source = 'CommonPath' }
            }
        }
        catch { }
    }

    & $write 'Steam not found on machine; checking R2 sync manifest...' 'INFO'
    return Resolve-PlayniteSteamFromR2Manifest -WatcherRoot $WatcherRoot -LogAction $LogAction
}

function Register-PlayniteSteamInstallPath {
    param(
        [Parameter(Mandatory)][string]$SteamPath,
        [scriptblock]$LogAction = $null
    )

    $write = if ($LogAction) { $LogAction } else { { param($Message, $Level) } }
    Import-NextGpuGamesAppsManifest | Out-Null
    if (Get-Command Register-SteamInstallPath -ErrorAction SilentlyContinue) {
        return Register-SteamInstallPath -SteamPath $SteamPath -LogAction $LogAction
    }

    $steamPath = $SteamPath.Trim().TrimEnd('\')
    if (-not (Test-PlayniteSteamClientPath -Path $steamPath)) {
        throw "Not a valid Steam client folder: $steamPath"
    }

    $keyPath = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }

    $current = $null
    try {
        $current = (Get-ItemProperty -LiteralPath $keyPath -Name InstallPath -ErrorAction Stop).InstallPath
    }
    catch { }

    if ($current -and ($current.TrimEnd('\') -ieq $steamPath)) {
        return $false
    }

    Set-ItemProperty -LiteralPath $keyPath -Name InstallPath -Value $steamPath
    & $write "Registered Steam InstallPath in registry: $steamPath" 'INFO'
    return $true
}

function Ensure-PlayniteSteamForLibraryScan {
    param(
        [string]$WatcherRoot = "",
        [string]$OverridePath = "",
        [scriptblock]$LogAction = $null
    )

    $resolved = Resolve-PlayniteSteamInstallPath -OverridePath $OverridePath -WatcherRoot $WatcherRoot -LogAction $LogAction
    if (-not $resolved -or [string]::IsNullOrWhiteSpace($resolved.Path)) {
        if ($LogAction) {
            & $LogAction 'Steam not found (machine or R2 manifest). Steam library import will be skipped.' 'WARN'
        }
        return $null
    }

    if ($resolved.Source -notin @('Registry', 'Override')) {
        try {
            Register-PlayniteSteamInstallPath -SteamPath $resolved.Path -LogAction $LogAction
        }
        catch {
            if ($LogAction) {
                & $LogAction ("Could not register Steam in registry (run as Admin?): $($_.Exception.Message)") 'WARN'
            }
        }
    }

    return $resolved
}

function Normalize-EverythingSearchPath {
    param(
        [string]$Path,
        [string]$ScanRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $normalized = "$Path".Trim().Trim('"')
    if ($normalized.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = '\' + $normalized.Substring(8)
    }
    elseif ($normalized.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }

    $normalized = $normalized -replace '/', '\'

    if (-not [System.IO.Path]::IsPathRooted($normalized) -and -not [string]::IsNullOrWhiteSpace($ScanRoot)) {
        $normalized = Join-Path $ScanRoot.TrimEnd('\') $normalized
    }

    try {
        return [System.IO.Path]::GetFullPath($normalized)
    }
    catch {
        return $normalized
    }
}

function ConvertFrom-EverythingSearchOutputLine {
    param([object]$Line)

    $text = "$Line".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    if ($text -match '^(?<path>".+\.exe")') {
        return $Matches.path.Trim('"')
    }

    if ($text -match '^(?<path>[^\t]+\.exe)\b') {
        return $Matches.path.Trim().Trim('"')
    }

    if ($text.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $text.Trim('"')
    }

    return $null
}

function Test-AllowlistedExeLeafMatch {
    param(
        [string]$CandidatePath,
        [string]$AllowlistExeName
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or [string]::IsNullOrWhiteSpace($AllowlistExeName)) {
        return $false
    }

    $leaf = ([System.IO.Path]::GetFileName($CandidatePath)).ToLowerInvariant()
    $key = $AllowlistExeName.ToLowerInvariant()
    if ($leaf -eq $key) {
        return $true
    }

    if ($leaf.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
        $targetLeaf = [System.IO.Path]::GetFileNameWithoutExtension($leaf).ToLowerInvariant()
        if ($targetLeaf -eq $key) {
            return $true
        }
    }

    return $false
}

function Test-PathUnderScanRoot {
    param(
        [string]$Path,
        [string]$ScanRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($ScanRoot)) {
        return $false
    }

    $fullPath = Normalize-EverythingSearchPath -Path $Path -ScanRoot $ScanRoot
    $fullRoot = Normalize-EverythingSearchPath -Path $ScanRoot
    if ([string]::IsNullOrWhiteSpace($fullPath) -or [string]::IsNullOrWhiteSpace($fullRoot)) {
        return $false
    }

    if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if (-not $fullRoot.EndsWith('\')) {
        $fullRoot = $fullRoot + '\'
    }

    return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-DesktopScanDirectoryName {
    param([string]$Name)
    foreach ($skip in $script:DesktopScanSkipDirNames) {
        if ($Name -ieq $skip) { return $true }
    }
    return $false
}

function Test-DesktopScanRootIsOnSystemDrive {
    param([string]$ScanRoot)

    if ([string]::IsNullOrWhiteSpace($ScanRoot)) {
        return $false
    }

    $normalized = Normalize-EverythingSearchPath -Path $ScanRoot
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    foreach ($sysRoot in (Get-ExcludedSystemDriveRoots)) {
        if (Test-PathUnderScanRoot -Path $normalized -ScanRoot $sysRoot) {
            return $true
        }
    }

    return $false
}

function Test-DesktopScanInstallerExeExcluded {
    param([string]$FullPath)

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        return $true
    }

    $leaf = [System.IO.Path]::GetFileName($FullPath)
    return ($leaf -match '(?i)^(uninstall|setup|install|update|redist|vcredist|dxsetup)')
}

function Test-DesktopScanPathOnSystemDrive {
    param([string]$FullPath)

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        return $false
    }

    $normalized = Normalize-EverythingSearchPath -Path $FullPath
    foreach ($sysRoot in (Get-ExcludedSystemDriveRoots)) {
        if (Test-PathUnderScanRoot -Path $normalized -ScanRoot $sysRoot) {
            return $true
        }
    }

    return $false
}

function Select-BestAllowlistedExeHit {
    param([object[]]$Candidates)

    $list = @($Candidates)
    if ($list.Length -eq 0) {
        return $null
    }

    $ranked = foreach ($candidate in $list) {
        $sortTime = [datetime]::MinValue
        if ($null -ne $candidate.LastWriteTime -and $candidate.LastWriteTime -is [datetime]) {
            $sortTime = $candidate.LastWriteTime
        }
        [PSCustomObject]@{
            Hit      = $candidate
            SortTime = $sortTime
        }
    }

    return ($ranked | Sort-Object SortTime -Descending | Select-Object -First 1).Hit
}

function Get-EverythingToolsDirectory {
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = $PSScriptRoot
    }
    return Join-Path $RepoRoot "tools\everything"
}

function Get-EverythingEsCandidatePaths {
    param([string]$RepoRoot = "")

    $paths = New-Object System.Collections.Generic.List[string]

    $add = {
        param([string]$Path)
        if (-not [string]::IsNullOrWhiteSpace($Path) -and $paths -notcontains $Path) {
            [void]$paths.Add($Path)
        }
    }

    & $add (Join-Path (Get-EverythingToolsDirectory -RepoRoot $RepoRoot) 'es.exe')
    & $add (Join-Path ${env:ProgramFiles} 'Everything\es.exe')
    if (${env:ProgramFiles(x86)}) {
        & $add (Join-Path ${env:ProgramFiles(x86)} 'Everything\es.exe')
    }
    if ($env:LOCALAPPDATA) {
        & $add (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\es.exe')
    }

    $appExe = Get-EverythingAppExePath -RepoRoot $RepoRoot
    if ($appExe) {
        & $add (Join-Path (Split-Path -Path $appExe -Parent) 'es.exe')
    }

    $cmd = Get-Command es.exe -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) {
        & $add $cmd.Source
    }

    return $paths.ToArray()
}

function Get-EverythingEsExePath {
    param([string]$RepoRoot = "")

    foreach ($candidate in (Get-EverythingEsCandidatePaths -RepoRoot $RepoRoot)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-EverythingAppExePath {
    param([string]$RepoRoot = "")

    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'Everything\Everything.exe')
    )
    if (${env:ProgramFiles(x86)}) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} 'Everything\Everything.exe'
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    try {
        $proc = Get-Process -Name 'Everything' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($proc -and $proc.Path -and (Test-Path -LiteralPath $proc.Path)) {
            return $proc.Path
        }
    }
    catch {
    }

    return $null
}

function Get-EverythingEsExitCodeDescription {
    param([int]$ExitCode)

    switch ($ExitCode) {
        0 { return 'OK (IPC connected)' }
        1 { return 'Failed to create search instance' }
        2 { return 'IPC unavailable' }
        3 { return 'Memory allocation failed' }
        4 { return 'Invalid parameter' }
        5 { return 'Invalid sort type' }
        6 { return 'Invalid reply' }
        7 { return 'Invalid search' }
        8 { return 'Everything is not running (IPC window not found)' }
        9 { return 'Error communicating with Everything' }
        default { return "Unknown es.exe exit code $ExitCode" }
    }
}

function Invoke-EverythingEsProbe {
    param(
        [string]$EsExePath,
        [string]$Query = 'playnitewatcher_probe',
        [int]$TimeoutMs = 3000,
        [int]$MaxResults = 1
    )

    $result = [PSCustomObject]@{
        Success     = $false
        ExitCode    = -1
        Description = 'es.exe path missing or not found'
        EsExePath   = $EsExePath
        Query       = $Query
        TimeoutMs   = $TimeoutMs
        DurationMs  = 0
        OutputLines = @()
    }

    if ([string]::IsNullOrWhiteSpace($EsExePath) -or -not (Test-Path -LiteralPath $EsExePath)) {
        return $result
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(
            & $EsExePath @('-max-results', "$MaxResults", '-timeout', "$TimeoutMs", $Query) 2>&1
        )
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = -1 }
    }
    catch {
        $sw.Stop()
        $ErrorActionPreference = $prevEap
        $result.ExitCode = -1
        $result.Description = "Probe failed: $($_.Exception.Message)"
        $result.DurationMs = [int]$sw.ElapsedMilliseconds
        $result.OutputLines = @("$($_.Exception.Message)")
        return $result
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
    $sw.Stop()

    $text = ($output | ForEach-Object { "$_" }) -join ' '
    if ($exitCode -lt 0 -and $text -match 'Error\s+(\d+)') {
        $exitCode = [int]$Matches[1]
    }

    $result.ExitCode = [int]$exitCode
    $result.Description = Get-EverythingEsExitCodeDescription -ExitCode $result.ExitCode
    $result.Success = ($result.ExitCode -eq 0)
    $result.DurationMs = [int]$sw.ElapsedMilliseconds
    $result.OutputLines = @($output | ForEach-Object { "$_" })
    return $result
}

function Write-EverythingDiagnostics {
    param(
        [string]$RepoRoot = "",
        [scriptblock]$LogAction,
        [object]$ProbeResult
    )

    if (-not $LogAction) {
        return
    }

    $write = { param($Message, $Level = 'INFO')
        & $LogAction $Message $Level
    }

    $resolvedEs = Get-EverythingEsExePath -RepoRoot $RepoRoot
    $resolvedApp = Get-EverythingAppExePath -RepoRoot $RepoRoot
    $candidatePaths = Get-EverythingEsCandidatePaths -RepoRoot $RepoRoot

    & $write "Everything debug: resolved es.exe = $(if ($resolvedEs) { $resolvedEs } else { '(not found)' })"
    foreach ($candidate in $candidatePaths) {
        $exists = Test-Path -LiteralPath $candidate
        & $write "Everything debug: es.exe candidate $(if ($exists) { 'found' } else { 'missing' }): $candidate"
    }
    & $write "Everything debug: Everything.exe = $(if ($resolvedApp) { $resolvedApp } else { '(not found)' })"

    if ($resolvedEs) {
        try {
            $ver = (Get-Item -LiteralPath $resolvedEs).VersionInfo
            if ($ver.FileVersion) {
                & $write "Everything debug: es.exe version = $($ver.FileVersion)"
            }
        }
        catch {
        }
    }

    $procs = @(Get-Process -Name 'Everything' -ErrorAction SilentlyContinue)
    if ($procs.Count -gt 0) {
        $pidList = ($procs | ForEach-Object { $_.Id }) -join ', '
        & $write "Everything debug: Everything.exe process running (PID: $pidList)"
    }
    else {
        & $write "Everything debug: Everything.exe process not running" 'WARN'
    }

    $svc = Get-Service -Name 'Everything' -ErrorAction SilentlyContinue
    if ($svc) {
        & $write "Everything debug: Windows service 'Everything' status = $($svc.Status) (start type: $($svc.StartType))"
    }
    else {
        & $write "Everything debug: Windows service 'Everything' not registered" 'WARN'
    }

    if ($ProbeResult) {
        $lineCount = 0
        if ($ProbeResult.OutputLines) { $lineCount = @($ProbeResult.OutputLines).Count }
        & $write ("Everything debug: es.exe probe query='{0}' timeout={1}ms exit={2} ({3}) duration={4}ms outputLines={5}" -f `
            $ProbeResult.Query, $ProbeResult.TimeoutMs, $ProbeResult.ExitCode, `
            $ProbeResult.Description, $ProbeResult.DurationMs, $lineCount)
        if ($lineCount -gt 0) {
            $preview = @($ProbeResult.OutputLines | Select-Object -First 3) -join ' | '
            if ($preview.Length -gt 300) { $preview = $preview.Substring(0, 300) + '...' }
            & $write "Everything debug: es.exe probe output preview: $preview"
        }
    }
}

function Test-EverythingEsResponds {
    param(
        [string]$EsExePath,
        [int]$TimeoutMs = 3000
    )

    $probe = Invoke-EverythingEsProbe -EsExePath $EsExePath -TimeoutMs $TimeoutMs
    return $probe.Success
}

function Test-EverythingReady {
    param(
        [string]$RepoRoot = "",
        [int]$TimeoutMs = 3000,
        [scriptblock]$LogAction
    )

    $esPath = Get-EverythingEsExePath -RepoRoot $RepoRoot
    if (-not $esPath) {
        if ($LogAction) {
            Write-EverythingDiagnostics -RepoRoot $RepoRoot -LogAction $LogAction
        }
        return $false
    }

    $probe = Invoke-EverythingEsProbe -EsExePath $esPath -TimeoutMs $TimeoutMs
    if ($LogAction -and -not $probe.Success) {
        Write-EverythingDiagnostics -RepoRoot $RepoRoot -LogAction $LogAction -ProbeResult $probe
    }
    return $probe.Success
}

function Get-EverythingInstallerDownloadUrl {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $page = Invoke-WebRequest -Uri "https://www.voidtools.com/downloads/" -UseBasicParsing
    $match = [regex]::Match($page.Content, 'href="(https://www\.voidtools\.com/[^"]*x64-Setup\.exe)"', 'IgnoreCase')
    if ($match.Success) {
        return $match.Groups[1].Value
    }

    $match = [regex]::Match($page.Content, 'href="(/[^"]*x64-Setup\.exe)"', 'IgnoreCase')
    if ($match.Success) {
        return "https://www.voidtools.com$($match.Groups[1].Value)"
    }

    return $null
}

function Get-EverythingEsDownloadUrl {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $archSuffix = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }

    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/voidtools/ES/releases/latest'
        foreach ($asset in $release.assets) {
            if ($asset.name -match "\.$([regex]::Escape($archSuffix))\.zip$") {
                return $asset.browser_download_url
            }
        }
    }
    catch {
    }

    try {
        $page = Invoke-WebRequest -Uri 'https://www.voidtools.com/downloads/' -UseBasicParsing
        $match = [regex]::Match(
            $page.Content,
            "href=`"(https://www\.voidtools\.com/[^`"]*es[^`"]*\.$archSuffix\.zip)`"",
            'IgnoreCase')
        if ($match.Success) {
            return $match.Groups[1].Value
        }
        $match = [regex]::Match(
            $page.Content,
            "href=`"(/[^`"]*es[^`"]*\.$archSuffix\.zip)`"",
            'IgnoreCase')
        if ($match.Success) {
            return "https://www.voidtools.com$($match.Groups[1].Value)"
        }
    }
    catch {
    }

    return $null
}

function Install-EverythingEsIfMissing {
    param(
        [string]$RepoRoot,
        [scriptblock]$LogAction
    )

    $write = { param($Message, $Level = 'INFO')
        if ($LogAction) { & $LogAction $Message $Level }
    }

    if (Get-EverythingEsExePath -RepoRoot $RepoRoot) {
        return $true
    }

    $appExe = Get-EverythingAppExePath -RepoRoot $RepoRoot
    if ($appExe) {
        $siblingEs = Join-Path (Split-Path -Path $appExe -Parent) 'es.exe'
        if (Test-Path -LiteralPath $siblingEs) {
            & $write "Found es.exe next to Everything.exe: $siblingEs"
            return $true
        }
    }

    $downloadUrl = Get-EverythingEsDownloadUrl
    if (-not $downloadUrl) {
        & $write "Could not find voidtools ES (es.exe) download URL." "WARN"
        return $false
    }

    $fileName = [System.IO.Path]::GetFileName(($downloadUrl -split '\?')[0])
    $downloadDir = Join-Path $RepoRoot 'Download'
    if (-not (Test-Path -LiteralPath $downloadDir)) {
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    }

    $zipPath = Join-Path $downloadDir $fileName
    & $write "Downloading voidtools ES (es.exe): $downloadUrl"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    }
    catch {
        & $write ("es.exe download failed: " + $_.Exception.Message) "WARN"
        return $false
    }

    $extractDir = Join-Path $downloadDir ('es-extract-' + [Guid]::NewGuid().ToString('N'))
    $installOk = $false
    try {
        try {
            Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        }
        catch {
            & $write ("es.exe extract failed: " + $_.Exception.Message) "WARN"
            return $false
        }

        $extractedEs = Get-ChildItem -LiteralPath $extractDir -Filter 'es.exe' -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $extractedEs) {
            & $write "es.exe not found inside $fileName." "WARN"
            return $false
        }

        $toolsDir = Get-EverythingToolsDirectory -RepoRoot $RepoRoot
        if (-not (Test-Path -LiteralPath $toolsDir)) {
            New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        }

        $destEs = Join-Path $toolsDir 'es.exe'
        try {
            Copy-Item -LiteralPath $extractedEs.FullName -Destination $destEs -Force
            & $write "Installed es.exe to $destEs"
        }
        catch {
            & $write ("Failed to copy es.exe to tools: " + $_.Exception.Message) "WARN"
            return $false
        }

        if ($appExe) {
            $siblingEs = Join-Path (Split-Path -Path $appExe -Parent) 'es.exe'
            try {
                Copy-Item -LiteralPath $destEs -Destination $siblingEs -Force
                & $write "Installed es.exe next to Everything.exe: $siblingEs"
            }
            catch {
                & $write "es.exe is in repo tools only (could not copy to Program Files; admin may be required)." "INFO"
            }
        }

        $installOk = [bool](Get-EverythingEsExePath -RepoRoot $RepoRoot)
    }
    finally {
        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return $installOk
}

function Install-EverythingIfMissing {
    param(
        [string]$RepoRoot,
        [scriptblock]$LogAction
    )

    $write = { param($Message, $Level = 'INFO')
        if ($LogAction) { & $LogAction $Message $Level }
    }

    if (Get-EverythingEsExePath -RepoRoot $RepoRoot) {
        return $true
    }

    if (Get-EverythingAppExePath -RepoRoot $RepoRoot) {
        & $write "Everything app is installed; es.exe is a separate CLI download."
        return (Install-EverythingEsIfMissing -RepoRoot $RepoRoot -LogAction $LogAction)
    }

    $downloadUrl = Get-EverythingInstallerDownloadUrl
    if (-not $downloadUrl) {
        & $write "Could not find Everything x64 installer URL on voidtools.com." "WARN"
        return $false
    }

    $fileName = [System.IO.Path]::GetFileName(($downloadUrl -split '\?')[0])
    $downloadDir = Join-Path $RepoRoot "Download"
    if (-not (Test-Path -LiteralPath $downloadDir)) {
        New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
    }

    $installerPath = Join-Path $downloadDir $fileName
    & $write "Downloading Everything installer: $downloadUrl"
    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
    }
    catch {
        & $write ("Everything download failed: " + $_.Exception.Message) "WARN"
        return $false
    }

    & $write "Installing Everything silently..."
    try {
        $everythingDir = Join-Path ${env:ProgramFiles} 'Everything'
        $proc = Start-Process -FilePath $installerPath -ArgumentList @(
            '/S',
            '-install-options',
            '-install-service -disable-run-as-admin -disable-update-notification',
            "/D=$everythingDir"
        ) -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -ne 0) {
            & $write "Everything installer exited with code $($proc.ExitCode)." "WARN"
        }

    }
    catch {
        & $write ("Everything install failed: " + $_.Exception.Message) "WARN"
        return $false
    }

    if (-not (Get-EverythingAppExePath -RepoRoot $RepoRoot)) {
        & $write "Everything install completed but Everything.exe was not found." "WARN"
        return $false
    }

    & $write "Everything app installed. Start the Everything tray app or service before desktop import."
    return (Install-EverythingEsIfMissing -RepoRoot $RepoRoot -LogAction $LogAction)
}

function Start-EverythingForEsIpc {
    param(
        [string]$RepoRoot = "",
        [int]$WaitSeconds = 45,
        [int]$ProbeTimeoutMs = 5000,
        [scriptblock]$LogAction
    )

    $write = { param($Message, $Level = 'INFO')
        if ($LogAction) { & $LogAction $Message $Level }
    }

    $appExe = Get-EverythingAppExePath -RepoRoot $RepoRoot
    if (-not $appExe) {
        & $write "Cannot start Everything for IPC: Everything.exe not found." "WARN"
        return $false
    }

    if (Test-EverythingReady -RepoRoot $RepoRoot -TimeoutMs $ProbeTimeoutMs) {
        return $true
    }

    & $write "Everything IPC not ready; starting Everything (-startup, minimized): $appExe"
    try {
        Start-Process -FilePath $appExe -ArgumentList '-startup' -WindowStyle Hidden -ErrorAction Stop
    }
    catch {
        & $write ("Failed to start Everything.exe: " + $_.Exception.Message) "WARN"
        return $false
    }

    $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-EverythingReady -RepoRoot $RepoRoot -TimeoutMs $ProbeTimeoutMs) {
            & $write "Everything IPC ready after starting Everything.exe."
            return $true
        }
    }

    & $write "Everything.exe started but es.exe IPC still not ready after ${WaitSeconds}s." "WARN"
    return $false
}

function Ensure-EverythingReady {
    param(
        [string]$RepoRoot,
        [switch]$SkipInstall,
        [switch]$SkipStartEverything,
        [scriptblock]$LogAction
    )

    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $RepoRoot

    $write = { param($Message, $Level = 'INFO')
        if ($LogAction) { & $LogAction $Message $Level }
    }

    & $write "Everything check: probing es.exe IPC..."
    if (Test-EverythingReady -RepoRoot $RepoRoot -LogAction $LogAction) {
        & $write "Everything is ready (es.exe IPC)."
        return $true
    }

    if ($SkipInstall) {
        & $write "Everything not ready (-SkipEverythingInstall)." "WARN"
        return $false
    }

    $esPath = Get-EverythingEsExePath -RepoRoot $RepoRoot
    if (-not $esPath) {
        & $write "Everything check: es.exe not found; downloading voidtools ES CLI..."
        if (-not (Install-EverythingIfMissing -RepoRoot $RepoRoot -LogAction $LogAction)) {
            Write-EverythingDiagnostics -RepoRoot $RepoRoot -LogAction $LogAction
            return $false
        }
        $esPath = Get-EverythingEsExePath -RepoRoot $RepoRoot
        if (-not $esPath) {
            & $write "es.exe not found after ES CLI install." "WARN"
            Write-EverythingDiagnostics -RepoRoot $RepoRoot -LogAction $LogAction
            return $false
        }
        & $write "Everything check: es.exe ready at $esPath"
    }

    & $write "Everything check: re-probing es.exe after install..."
    if (Test-EverythingReady -RepoRoot $RepoRoot -LogAction $LogAction) {
        & $write "Everything is ready (es.exe IPC)."
        return $true
    }

    if (-not $SkipStartEverything) {
        & $write "Everything check: IPC failed; attempting to start Everything for es.exe..."
        if (Start-EverythingForEsIpc -RepoRoot $RepoRoot -LogAction $LogAction) {
            & $write "Everything is ready (es.exe IPC)."
            return $true
        }
        Write-EverythingDiagnostics -RepoRoot $RepoRoot -LogAction $LogAction
    }

    & $write @(
        "es.exe cannot reach Everything IPC (Error 8). The Windows service alone is not enough:",
        "run Everything.exe in this user session (tray), or re-run setup without -SkipStartEverything.",
        "Use -SkipEverythingInstall for directory walk only."
    ) -join ' ' "WARN"
    return $false
}

function Get-EverythingSearchQueriesForAllowlistExe {
    param([string]$ExeName)

    $name = $ExeName.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) {
        return @()
    }

    return @(
        $name
        "wfn:$name"
        "=$name"
    )
}

function Invoke-EverythingEsSearchLines {
    param(
        [string]$EsExe,
        [string]$SearchQuery,
        [string]$ScanRootFull,
        [int]$MaxResults = 50,
        [int]$TimeoutMs = 15000
    )

    $argList = @('-a-d', '-max-results', "$MaxResults", '-timeout', "$TimeoutMs")
    if ($ScanRootFull) {
        $argList += @('-path', $ScanRootFull)
    }
    $argList += $SearchQuery

    $lines = @( & $EsExe @argList 2>$null | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = -1 }

    return [PSCustomObject]@{
        Lines     = $lines
        ExitCode  = [int]$exitCode
        Arguments = ($argList -join ' ')
    }
}

function Test-EverythingSearchHitCandidate {
    param(
        [string]$RawLine,
        [string]$AllowlistExeName,
        [string]$ScanRootFull,
        [ref]$RejectReason
    )

    $RejectReason.Value = $null
    $parsed = ConvertFrom-EverythingSearchOutputLine -Line $RawLine
    if (-not $parsed) {
        $RejectReason.Value = 'not an exe path line'
        return $null
    }

    $path = Normalize-EverythingSearchPath -Path $parsed -ScanRoot $ScanRootFull
    if ([string]::IsNullOrWhiteSpace($path)) {
        $RejectReason.Value = 'could not normalize path'
        return $null
    }

    if (-not $path.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        $RejectReason.Value = 'does not end with .exe'
        return $null
    }

    if (-not (Test-AllowlistedExeLeafMatch -CandidatePath $path -AllowlistExeName $AllowlistExeName)) {
        $RejectReason.Value = "filename mismatch (got $([System.IO.Path]::GetFileName($path)))"
        return $null
    }

    if (Test-DesktopScanInstallerExeExcluded -FullPath $path) {
        $RejectReason.Value = 'installer or redistributable exe name'
        return $null
    }

    if (Test-DesktopScanPathOnSystemDrive -FullPath $path) {
        $RejectReason.Value = 'on system/boot drive'
        return $null
    }

    if ($ScanRootFull -and -not (Test-PathUnderScanRoot -Path $path -ScanRoot $ScanRootFull)) {
        $RejectReason.Value = "outside scan root $ScanRootFull"
        return $null
    }

    if ($path.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($path)
            $target = $shortcut.TargetPath
            if (-not [string]::IsNullOrWhiteSpace($target) -and $target.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
                $path = Normalize-EverythingSearchPath -Path $target -ScanRoot $ScanRootFull
            }
        }
        catch {
        }
    }

    return $path
}

function Find-AllowlistedExesViaEverything {
    param(
        [string]$ScanRoot,
        [object[]]$Allowlist,
        [string]$RepoRoot = "",
        [int]$MaxResultsPerExe = 50,
        [scriptblock]$LogAction
    )

    $esExe = Get-EverythingEsExePath -RepoRoot $RepoRoot
    if (-not $esExe) {
        if ($LogAction) {
            & $LogAction "Everything search: es.exe not found; no results." "WARN"
        }
        return @()
    }

    if ($LogAction) {
        & $LogAction "Everything search: using $esExe"
    }

    $scanRootFull = $null
    if (-not [string]::IsNullOrWhiteSpace($ScanRoot) -and (Test-Path -LiteralPath $ScanRoot)) {
        $scanRootFull = Normalize-EverythingSearchPath -Path $ScanRoot
    }

    $candidatesByKey = @{}

    foreach ($entry in $Allowlist) {
        $key = $entry.Exe.ToLowerInvariant()
        $rejectNotes = New-Object System.Collections.Generic.List[string]
        $lastSearch = $null

        foreach ($searchQuery in (Get-EverythingSearchQueriesForAllowlistExe -ExeName $entry.Exe)) {
            if ($candidatesByKey.ContainsKey($key)) {
                break
            }

            try {
                $lastSearch = Invoke-EverythingEsSearchLines `
                    -EsExe $esExe `
                    -SearchQuery $searchQuery `
                    -ScanRootFull $scanRootFull `
                    -MaxResults $MaxResultsPerExe `
                    -TimeoutMs 15000
            }
            catch {
                if ($LogAction) {
                    & $LogAction ("Everything search failed for $($entry.Exe): " + $_.Exception.Message) "WARN"
                }
                continue
            }

            if ($LogAction) {
                $argPreview = $lastSearch.Arguments
                if ($argPreview.Length -gt 200) { $argPreview = $argPreview.Substring(0, 200) + '...' }
                & $LogAction ("Everything search: $($entry.Exe) exit=$($lastSearch.ExitCode) ($(
                    Get-EverythingEsExitCodeDescription -ExitCode $lastSearch.ExitCode)) lines=$($lastSearch.Lines.Count) args: $argPreview")
            }

            if ($lastSearch.ExitCode -ne 0) {
                continue
            }

            foreach ($line in $lastSearch.Lines) {
                $reason = ''
                $reasonRef = [ref]$reason
                $path = Test-EverythingSearchHitCandidate `
                    -RawLine $line `
                    -AllowlistExeName $entry.Exe `
                    -ScanRootFull $scanRootFull `
                    -RejectReason $reasonRef

                if (-not $path) {
                    if ($reason) {
                        $preview = "$line".Trim()
                        if ($preview.Length -gt 160) { $preview = $preview.Substring(0, 160) + '...' }
                        [void]$rejectNotes.Add("$preview -> $reason")
                    }
                    continue
                }

                $lastWrite = [datetime]::MinValue
                if (Test-Path -LiteralPath $path) {
                    try {
                        $lastWrite = (Get-Item -LiteralPath $path).LastWriteTimeUtc
                    }
                    catch {
                    }
                }

                $hit = [PSCustomObject]@{
                    AllowlistEntry = $entry
                    FullPath       = $path
                    LastWriteTime  = $lastWrite
                }

                if (-not $candidatesByKey.ContainsKey($key)) {
                    $candidatesByKey[$key] = New-Object System.Collections.Generic.List[object]
                }
                [void]$candidatesByKey[$key].Add($hit)
            }
        }

        if ($LogAction -and (-not $candidatesByKey.ContainsKey($key))) {
            $lineCount = 0
            if ($lastSearch -and $lastSearch.Lines) {
                $lineCount = @($lastSearch.Lines).Count
            }
            if ($lineCount -gt 0 -or $rejectNotes.Count -gt 0) {
                $sample = ($rejectNotes | Select-Object -First 3) -join ' | '
                if (-not $sample -and $lastSearch) {
                    $sample = (@($lastSearch.Lines | Select-Object -First 2 | ForEach-Object { "$_".Trim() }) -join ' | ')
                }
                & $LogAction "Everything search: $($entry.Exe) no usable hit. $sample" "WARN"
            }
        }
    }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($key in $candidatesByKey.Keys) {
        $best = Select-BestAllowlistedExeHit -Candidates @($candidatesByKey[$key].ToArray())
        if ($best) {
            [void]$results.Add($best)
        }
    }

    return $results.ToArray()
}

function Find-AllowlistedExesUnderPathWalk {
    param(
        [string]$ScanRoot,
        [object[]]$Allowlist,
        [int]$MaxDepth = 8
    )

    if (-not (Test-Path -LiteralPath $ScanRoot)) {
        return @()
    }

    $allowByExe = @{}
    foreach ($item in $Allowlist) {
        $allowByExe[$item.Exe.ToLowerInvariant()] = $item
    }

    $found = @{}
    $root = [System.IO.Path]::GetFullPath($ScanRoot.TrimEnd('\'))
    $skipHeavyDirNamesDuringWalk = Test-DesktopScanRootIsOnSystemDrive -ScanRoot $root

    function Search-Dir {
        param(
            [string]$Dir,
            [int]$Depth
        )

        if ($Depth -gt $MaxDepth) { return }

        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($Dir, '*.exe')) {
                $name = [System.IO.Path]::GetFileName($file)
                $key = $name.ToLowerInvariant()
                if (-not $allowByExe.ContainsKey($key)) { continue }

                $lastWrite = [datetime]::MinValue
                try {
                    $lastWrite = (Get-Item -LiteralPath $file).LastWriteTimeUtc
                }
                catch {
                }

                $item = [PSCustomObject]@{
                    AllowlistEntry = $allowByExe[$key]
                    FullPath       = $file
                    LastWriteTime  = $lastWrite
                }

                if (-not $found.ContainsKey($key)) {
                    $found[$key] = New-Object System.Collections.Generic.List[object]
                }
                [void]$found[$key].Add($item)
            }

            if ($Depth -ge $MaxDepth) { return }

            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($Dir)) {
                $leaf = [System.IO.Path]::GetFileName($sub)
                if ($skipHeavyDirNamesDuringWalk -and (Test-DesktopScanDirectoryName -Name $leaf)) { continue }
                Search-Dir -Dir $sub -Depth ($Depth + 1)
            }
        }
        catch {
        }
    }

    Search-Dir -Dir $root -Depth 0

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($key in $found.Keys) {
        $best = Select-BestAllowlistedExeHit -Candidates @($found[$key].ToArray())
        if ($best) {
            [void]$results.Add($best)
        }
    }

    return $results.ToArray()
}

function Find-AllowlistedExeHitForEntry {
    param(
        [string]$ScanRoot,
        [object]$Entry,
        [object[]]$Allowlist,
        [string]$RepoRoot = "",
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $script:DesktopImportRepoRoot) {
        $RepoRoot = $script:DesktopImportRepoRoot
    }

    $single = @($Entry)
    $useEverything = $script:DesktopImportUseEverythingSearch

    if ($useEverything) {
        $hits = @(Find-AllowlistedExesViaEverything -ScanRoot $ScanRoot -Allowlist $single -RepoRoot $RepoRoot -LogAction $LogAction)
        if ($hits.Length -gt 0) {
            return $hits[0]
        }
        return $null
    }

    if ($script:DesktopImportEverythingOnly) {
        return $null
    }

    $walkHits = @(Find-AllowlistedExesUnderPathWalk -ScanRoot $ScanRoot -Allowlist $single)
    if ($walkHits.Length -gt 0) {
        return $walkHits[0]
    }

    return $null
}

function Find-AllowlistedExesUnderPath {
    param(
        [string]$ScanRoot,
        [object[]]$Allowlist,
        [int]$MaxDepth = 8,
        [string]$RepoRoot = "",
        [switch]$ForceWalk,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $script:DesktopImportRepoRoot) {
        $RepoRoot = $script:DesktopImportRepoRoot
    }

    $useEverything = (-not $ForceWalk) -and $script:DesktopImportUseEverythingSearch
    $hitByExe = @{}

    if ($useEverything) {
        $everythingHits = Find-AllowlistedExesViaEverything `
            -ScanRoot $ScanRoot `
            -Allowlist $Allowlist `
            -RepoRoot $RepoRoot `
            -LogAction $LogAction
        foreach ($hit in $everythingHits) {
            $hitByExe[$hit.AllowlistEntry.Exe.ToLowerInvariant()] = $hit
        }
    }

    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Allowlist) {
        $key = $entry.Exe.ToLowerInvariant()
        if (-not $hitByExe.ContainsKey($key)) {
            [void]$missing.Add($entry)
        }
    }

    if ($missing.Count -gt 0 -and -not $script:DesktopImportEverythingOnly) {
        $walkHits = Find-AllowlistedExesUnderPathWalk -ScanRoot $ScanRoot -Allowlist @($missing.ToArray()) -MaxDepth $MaxDepth
        foreach ($hit in $walkHits) {
            $key = $hit.AllowlistEntry.Exe.ToLowerInvariant()
            if (-not $hitByExe.ContainsKey($key)) {
                $hitByExe[$key] = $hit
            }
        }
    }
    elseif (-not $useEverything -and -not $script:DesktopImportEverythingOnly) {
        $walkHits = Find-AllowlistedExesUnderPathWalk -ScanRoot $ScanRoot -Allowlist $Allowlist -MaxDepth $MaxDepth
        foreach ($hit in $walkHits) {
            $hitByExe[$hit.AllowlistEntry.Exe.ToLowerInvariant()] = $hit
        }
    }

    return @($hitByExe.Values)
}

function Get-BsonValueAsBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsBoolean) { return $Value.AsBoolean }
        if ($Value.IsInt32) { return $Value.AsInt32 -ne 0 }
    }
    return [bool]$Value
}

function Get-BsonValueAsInt {
    param($Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsInt32) { return $Value.AsInt32 }
        if ($Value.IsInt64) { return [int]$Value.AsInt64 }
        if ($Value.IsString) {
            $text = $Value.AsString
            switch -Regex ($text) {
                '^(?i)File$' { return 0 }
                '^(?i)URL$' { return 1 }
                '^(?i)Emulator$' { return 2 }
                '^(?i)Script$' { return 3 }
                default {
                    if ($text -match '^\d+$') { return [int]$text }
                }
            }
        }
    }
    return [int]$Value
}

function Get-PlayActionsFromGameDocument {
    param($Doc)

    $actions = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Doc -or -not $Doc.ContainsKey('GameActions')) {
        return , @()
    }

    $raw = $Doc['GameActions']
    if ($null -eq $raw) { return , @() }

    $array = $null
    if ($raw -is [LiteDB.BsonArray]) {
        $array = $raw
    }
    elseif ($raw -is [LiteDB.BsonValue] -and $raw.IsArray) {
        $array = $raw.AsArray
    }

    if ($null -eq $array) { return , @() }

    foreach ($entry in $array) {
        if ($null -eq $entry) { continue }
        $actionDoc = $null
        if ($entry -is [LiteDB.BsonValue] -and $entry.IsDocument) {
            $actionDoc = $entry.AsDocument
        }
        elseif ($entry -is [LiteDB.BsonDocument]) {
            $actionDoc = $entry
        }
        if ($null -eq $actionDoc) { continue }

        $path = Get-BsonValueAsString -Value $actionDoc['Path']
        [void]$actions.Add([PSCustomObject]@{
                Name         = Get-BsonValueAsString -Value $actionDoc['Name']
                Path         = $path
                WorkingDir   = Get-BsonValueAsString -Value $actionDoc['WorkingDir']
                IsPlayAction = Get-BsonValueAsBool -Value $actionDoc['IsPlayAction']
                Type         = Get-BsonValueAsInt -Value $actionDoc['Type']
            })
    }

    return , $actions.ToArray()
}

function Get-PrimaryPlayAction {
    param([object[]]$Actions)

    if (-not $Actions -or $Actions.Count -eq 0) {
        return $null
    }

    $play = @($Actions | Where-Object { $_.IsPlayAction -and -not [string]::IsNullOrWhiteSpace($_.Path) })
    if ($play.Count -gt 0) {
        return $play[0]
    }

    return @($Actions | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } | Select-Object -First 1)
}

function New-PlayniteGameRecordFromBsonDocument {
    param($Doc)

    $id = Get-BsonValueAsGuid -Value $Doc['_id']
    if ([string]::IsNullOrWhiteSpace($id)) {
        return $null
    }

    $actions = Get-PlayActionsFromGameDocument -Doc $Doc
    $primary = Get-PrimaryPlayAction -Actions $actions

    return [PSCustomObject]@{
        Id                = $id
        GameId            = Get-BsonValueAsString -Value $Doc['GameId']
        Name              = Get-BsonValueAsString -Value $Doc['Name']
        InstallDirectory  = Get-BsonValueAsString -Value $Doc['InstallDirectory']
        PluginId          = Get-BsonValueAsGuid -Value $Doc['PluginId']
        PlayActions       = $actions
        PrimaryPlayPath   = if ($primary) { $primary.Path } else { "" }
        PrimaryWorkingDir = if ($primary) { $primary.WorkingDir } else { "" }
        LiteDbDocument    = $Doc
    }
}

function Get-PlayniteGamesWithPlayActions {
    param(
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $dbPath)) {
        throw "Playnite library database not found: $dbPath"
    }

    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir

    if ($LogAction) {
        & $LogAction "Reading games with play actions from: $dbPath"
    }

    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)
    $records = New-Object System.Collections.Generic.List[object]

    try {
        $collection = $db.GetCollection("Game")
        foreach ($doc in $collection.FindAll()) {
            $record = New-PlayniteGameRecordFromBsonDocument -Doc $doc
            if ($record) {
                [void]$records.Add($record)
            }
        }
    }
    finally {
        $db.Dispose()
    }

    return , $records.ToArray()
}

function Copy-LiteDbBsonValue {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsNull) {
            return [LiteDB.BsonValue]$null
        }
        if ($Value.IsDocument) {
            return New-Object LiteDB.BsonValue -ArgumentList @(, (Copy-LiteDbBsonDocument -Source $Value.AsDocument))
        }
        if ($Value.IsArray) {
            $copy = New-Object LiteDB.BsonArray
            foreach ($entry in $Value.AsArray) {
                Add-LiteDbBsonArrayItem -Array $copy -Value (Copy-LiteDbBsonValue -Value $entry)
            }
            return New-Object LiteDB.BsonValue -ArgumentList @(, $copy)
        }
        if ($Value.IsGuid) {
            return [LiteDB.BsonValue]$Value.AsGuid
        }
        if ($Value.IsString) {
            return [LiteDB.BsonValue]$Value.AsString
        }
        if ($Value.IsBoolean) {
            return [LiteDB.BsonValue]$Value.AsBoolean
        }
        if ($Value.IsInt32) {
            return [LiteDB.BsonValue]$Value.AsInt32
        }
        if ($Value.IsInt64) {
            return [LiteDB.BsonValue]$Value.AsInt64
        }
        if ($Value.IsDouble) {
            return [LiteDB.BsonValue]$Value.AsDouble
        }
        if ($Value.IsDateTime) {
            return [LiteDB.BsonValue]$Value.AsDateTime
        }
        return [LiteDB.BsonValue]$Value.RawValue
    }

    if ($Value -is [LiteDB.BsonDocument]) {
        return New-Object LiteDB.BsonValue -ArgumentList @(, (Copy-LiteDbBsonDocument -Source $Value))
    }

    if ($Value -is [LiteDB.BsonArray]) {
        $copy = New-Object LiteDB.BsonArray
        foreach ($entry in $Value) {
            Add-LiteDbBsonArrayItem -Array $copy -Value (Copy-LiteDbBsonValue -Value $entry)
        }
        return New-Object LiteDB.BsonValue -ArgumentList @(, $copy)
    }

    if ($Value -is [guid]) {
        return [LiteDB.BsonValue]$Value
    }

    return [LiteDB.BsonValue]$Value
}

function Copy-LiteDbBsonDocument {
    param($Source)

    if ($null -eq $Source) {
        return , (New-Object LiteDB.BsonDocument)
    }

    $sourceDoc = $null
    if ($Source -is [LiteDB.BsonDocument]) {
        $sourceDoc = $Source
    }
    elseif ($Source -is [LiteDB.BsonValue] -and $Source.IsDocument) {
        $sourceDoc = $Source.AsDocument
    }
    else {
        throw "Copy-LiteDbBsonDocument: expected BsonDocument, got $($Source.GetType().FullName)."
    }

    $dest = New-Object LiteDB.BsonDocument
    foreach ($key in $sourceDoc.Keys) {
        Set-LiteDbBsonField -Document $dest -Name ([string]$key) -Value (Copy-LiteDbBsonValue -Value $sourceDoc[$key])
    }

    return , $dest
}

function Get-PlayniteNativeGameBsonTemplateDocument {
    param($Collection)

    foreach ($doc in $Collection.FindAll()) {
        $pluginId = Get-BsonValueAsGuid -Value $doc['PluginId']
        if ($pluginId -ieq $script:PlayniteManualPluginId) {
            continue
        }
        if (-not $doc.ContainsKey('GameActions')) {
            continue
        }

        $actions = Get-RawPlayActionDocumentsFromGameDocument -Doc $doc
        if ($actions.Count -gt 0) {
            return $doc
        }
    }

    return $null
}

function Get-RawPlayActionDocumentsFromGameDocument {
    param($Doc)

    $result = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Doc -or -not $Doc.ContainsKey('GameActions')) {
        return , @()
    }

    $raw = $Doc['GameActions']
    $array = $null
    if ($raw -is [LiteDB.BsonArray]) {
        $array = $raw
    }
    elseif ($raw -is [LiteDB.BsonValue] -and $raw.IsArray) {
        $array = $raw.AsArray
    }

    if ($null -eq $array) {
        return , @()
    }

    foreach ($entry in $array) {
        if ($entry -is [LiteDB.BsonValue] -and $entry.IsDocument) {
            [void]$result.Add($entry.AsDocument)
        }
        elseif ($entry -is [LiteDB.BsonDocument]) {
            [void]$result.Add($entry)
        }
    }

    return , $result.ToArray()
}

function Get-PlayniteTemplatePlayActionDocument {
    param($TemplateGameDocument)

    $actions = Get-RawPlayActionDocumentsFromGameDocument -Doc $TemplateGameDocument
    if ($actions.Count -eq 0) {
        return $null
    }

    foreach ($action in $actions) {
        $path = Get-BsonValueAsString -Value $action['Path']
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            return $action
        }
    }

    return $actions[0]
}

function New-LiteDbGuidBsonDocument {
    param([string]$GuidString)
    $g = if ([string]::IsNullOrWhiteSpace($GuidString)) { [guid]::NewGuid().ToString() } else { $GuidString }
    $inner = New-Object LiteDB.BsonDocument
    Set-LiteDbBsonField -Document $inner -Name '$guid' -Value $g
    return , $inner
}

function New-PlayniteFilePlayActionBson {
    param(
        [string]$ExePath,
        [string]$WorkingDir,
        $TemplateAction = $null
    )

    $work = $WorkingDir
    if ([string]::IsNullOrWhiteSpace($work)) {
        $work = Split-Path -Path $ExePath -Parent
    }

    if ($TemplateAction) {
        $action = Copy-LiteDbBsonDocument -Source $TemplateAction
    }
    else {
        $action = New-Object LiteDB.BsonDocument
        Set-LiteDbBsonField -Document $action -Name 'Type' -Value 'File'
        Set-LiteDbBsonField -Document $action -Name 'TrackingMode' -Value 'Default'
        Set-LiteDbBsonField -Document $action -Name 'OverrideDefaultArgs' -Value $false
        Set-LiteDbBsonField -Document $action -Name 'EmulatorId' -Value ([guid]::Empty)
        Set-LiteDbBsonField -Document $action -Name 'InitialTrackingDelay' -Value 0
        Set-LiteDbBsonField -Document $action -Name 'TrackingFrequency' -Value 2000
    }

    Set-LiteDbBsonField -Document $action -Name 'Path' -Value $ExePath
    Set-LiteDbBsonField -Document $action -Name 'WorkingDir' -Value $work
    Set-LiteDbBsonField -Document $action -Name 'IsPlayAction' -Value $true
    Set-LiteDbBsonField -Document $action -Name 'Name' -Value 'Play'

    return , $action
}

function New-PlayniteManualGameBsonDocument {
    param(
        [string]$Title,
        [string]$ExePath,
        [string]$GameId = "",
        $TemplateGameDocument = $null
    )

    $installDir = Split-Path -Path $ExePath -Parent
    $newId = if ([string]::IsNullOrWhiteSpace($GameId)) {
        [guid]::NewGuid()
    }
    else {
        [guid]::Parse($GameId)
    }

    $templateAction = $null
    if ($TemplateGameDocument) {
        $templateAction = Get-PlayniteTemplatePlayActionDocument -TemplateGameDocument $TemplateGameDocument
        $doc = Copy-LiteDbBsonDocument -Source $TemplateGameDocument
    }
    else {
        $doc = New-Object LiteDB.BsonDocument
    }

    Set-LiteDbBsonField -Document $doc -Name '_id' -Value $newId
    Set-LiteDbBsonField -Document $doc -Name 'Name' -Value $Title
    Set-LiteDbBsonField -Document $doc -Name 'PluginId' -Value ([guid]::Empty)
    Set-LiteDbBsonField -Document $doc -Name 'GameId' -Value $newId.ToString()
    Set-LiteDbBsonField -Document $doc -Name 'IsInstalled' -Value $true
    Set-LiteDbBsonField -Document $doc -Name 'InstallDirectory' -Value $installDir
    Set-LiteDbBsonField -Document $doc -Name 'IncludeLibraryPluginAction' -Value $false

    if ($doc.ContainsKey('IsCustomGame')) {
        [void]$doc.Remove('IsCustomGame')
    }

    $action = New-PlayniteFilePlayActionBson -ExePath $ExePath -WorkingDir $installDir -TemplateAction $templateAction
    $arr = New-Object LiteDB.BsonArray
    Add-LiteDbBsonArrayItem -Array $arr -Value $action
    Set-LiteDbBsonField -Document $doc -Name 'GameActions' -Value $arr

    return , $doc
}

function Update-PlayniteGamePlayActionInDocument {
    param(
        $Doc,
        [string]$ExePath,
        [string]$Title
    )

    $installDir = Split-Path -Path $ExePath -Parent
    Set-LiteDbBsonField -Document $Doc -Name 'Name' -Value $Title
    Set-LiteDbBsonField -Document $Doc -Name 'InstallDirectory' -Value $installDir
    Set-LiteDbBsonField -Document $Doc -Name 'IsInstalled' -Value $true
    Set-LiteDbBsonField -Document $Doc -Name 'IncludeLibraryPluginAction' -Value $false

    $templateAction = $null
    $existingActions = Get-RawPlayActionDocumentsFromGameDocument -Doc $Doc
    if ($existingActions.Count -gt 0) {
        $templateAction = $existingActions[0]
    }

    $action = New-PlayniteFilePlayActionBson -ExePath $ExePath -WorkingDir $installDir -TemplateAction $templateAction
    $arr = New-Object LiteDB.BsonArray
    Add-LiteDbBsonArrayItem -Array $arr -Value $action
    Set-LiteDbBsonField -Document $Doc -Name 'GameActions' -Value $arr
}

function Remove-PlayniteManualGamesFromLiteDb {
    param(
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    Stop-PlayniteApplication -PlayniteExe $playniteExe

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $dbPath)) {
        throw "Playnite library database not found: $dbPath"
    }

    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir
    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)
    $removed = 0

    try {
        $collection = $db.GetCollection("Game")
        foreach ($doc in @($collection.FindAll())) {
            $pluginId = Get-BsonValueAsGuid -Value $doc['PluginId']
            if ($pluginId -ieq $script:PlayniteManualPluginId) {
                [void]$collection.Delete($doc['_id'])
                $removed++
                if ($LogAction) {
                    $title = Get-BsonValueAsString -Value $doc['Name']
                    & $LogAction "Removed manual desktop game from library DB: $title"
                }
            }
        }
    }
    finally {
        $db.Dispose()
    }

    if ($LogAction) {
        & $LogAction "Removed $removed manual desktop game(s) from games.db"
    }

    return $removed
}

function Find-PlayniteGameForAllowlistExe {
    param(
        [object[]]$Games,
        [string]$ExeName,
        [string]$ScanRoot = ""
    )

    $exeKey = $ExeName.ToLowerInvariant()
    $candidates = New-Object System.Collections.Generic.List[object]

    foreach ($game in $Games) {
        $path = $game.PrimaryPlayPath
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (([System.IO.Path]::GetFileName($path)).ToLowerInvariant() -ne $exeKey) { continue }
        if ($ScanRoot -and -not (Test-PathUnderScanRoot -Path $path -ScanRoot $ScanRoot)) { continue }
        [void]$candidates.Add($game)
    }

    if ($candidates.Count -eq 0) {
        return $null
    }

    return @($candidates | Sort-Object {
            if ($_.PrimaryPlayPath -and (Test-Path -LiteralPath $_.PrimaryPlayPath)) {
                (Get-Item -LiteralPath $_.PrimaryPlayPath).LastWriteTimeUtc
            }
            else { [datetime]::MinValue }
        } -Descending | Select-Object -First 1)
}

function Sync-PlayniteDesktopAppsToAllowlist {
    param(
        [string]$InstallDir,
        [string]$ScanRoot,
        [object[]]$Allowlist,
        [switch]$WhatIf,
        [switch]$Prune,
        [scriptblock]$LogAction
    )

    $stats = @{
        Added   = 0
        Updated = 0
        Pruned  = 0
        Missing = New-Object System.Collections.Generic.List[string]
        Extras  = New-Object System.Collections.Generic.List[string]
    }

    if ($WhatIf) {
        foreach ($entry in $Allowlist) {
            $hit = Find-AllowlistedExeHitForEntry -ScanRoot $ScanRoot -Entry $entry -Allowlist $Allowlist -LogAction $LogAction
            if ($hit) {
                if ($LogAction) { & $LogAction "Would sync: $($entry.Title) -> $($hit.FullPath)" }
            }
            else {
                [void]$stats.Missing.Add($entry.Exe)
                if ($LogAction) {
                    & $LogAction ("Not found: {0} (searched under '{1}' via index; allowlist filename only, full path from es.exe)" -f $entry.Exe, $ScanRoot) "WARN"
                }
            }
        }
        return $stats
    }

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    Stop-PlayniteApplication -PlayniteExe $playniteExe

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir
    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)

    try {
        $collection = $db.GetCollection("Game")
        $templateGame = Get-PlayniteNativeGameBsonTemplateDocument -Collection $collection
        $allGames = @(
            foreach ($doc in $collection.FindAll()) {
                New-PlayniteGameRecordFromBsonDocument -Doc $doc
            }
        ) | Where-Object { $_ }

        foreach ($entry in $Allowlist) {
            $hit = Find-AllowlistedExeHitForEntry -ScanRoot $ScanRoot -Entry $entry -Allowlist $Allowlist -LogAction $LogAction
            if (-not $hit) {
                [void]$stats.Missing.Add($entry.Exe)
                if ($LogAction) {
                    & $LogAction ("Not found: {0} (searched under '{1}'; allowlist filename only, need es.exe + Everything index)" -f $entry.Exe, $ScanRoot) "WARN"
                }
                continue
            }

            $exePath = $hit.FullPath
            if ($LogAction) { & $LogAction "Resolved: $($entry.Exe) -> $exePath (written to Playnite launch path)" }
            $existing = Find-PlayniteGameForAllowlistExe -Games $allGames -ExeName $entry.Exe -ScanRoot $ScanRoot

            if ($existing) {
                Update-PlayniteGamePlayActionInDocument -Doc $existing.LiteDbDocument -ExePath $exePath -Title $entry.Title
                [void]$collection.Update($existing.LiteDbDocument)
                $stats.Updated++
                if ($LogAction) { & $LogAction "Updated: $($entry.Title) ($exePath)" }
            }
            else {
                $newDoc = New-PlayniteManualGameBsonDocument -Title $entry.Title -ExePath $exePath -TemplateGameDocument $templateGame
                [void]$collection.Insert($newDoc)
                $stats.Added++
                if ($LogAction) { & $LogAction "Added: $($entry.Title) ($exePath)" }
            }
        }

        if ($Prune) {
            $allowKeys = @{}
            foreach ($entry in $Allowlist) {
                $allowKeys[$entry.Exe.ToLowerInvariant()] = $true
            }

            foreach ($game in $allGames) {
                $path = $game.PrimaryPlayPath
                if ([string]::IsNullOrWhiteSpace($path)) { continue }
                if (-not (Test-PathUnderScanRoot -Path $path -ScanRoot $ScanRoot)) { continue }

                $leaf = ([System.IO.Path]::GetFileName($path)).ToLowerInvariant()
                if ($allowKeys.ContainsKey($leaf)) { continue }
                if ($game.PluginId -ieq $script:PlayniteSteamPluginId) { continue }
                if ($game.PluginId -ieq $script:PlayniteEpicPluginId) { continue }

                $deleteIdDoc = New-LiteDbGuidBsonDocument -GuidString $game.Id
                $deleteId = New-Object LiteDB.BsonValue -ArgumentList @(, $deleteIdDoc)
                [void]$collection.Delete($deleteId)
                $stats.Pruned++
                [void]$stats.Extras.Add($path)
                if ($LogAction) { & $LogAction "Pruned: $path" "WARN" }
            }
        }
    }
    finally {
        $db.Dispose()
        Stop-PlayniteApplication -PlayniteExe $playniteExe
    }

    return $stats
}

function Get-ExportableDesktopPlayniteGames {
    param(
        [string]$InstallDir,
        [string]$RepoRoot,
        [string]$AllowlistPath = "",
        [scriptblock]$LogAction
    )

    $allowlist = Get-DesktopAppAllowlist -RepoRoot $RepoRoot -AllowlistPath $AllowlistPath
    $games = Get-PlayniteGamesWithPlayActions -InstallDir $InstallDir -LogAction $LogAction
    $export = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $allowlist) {
        $match = Find-PlayniteGameForAllowlistExe -Games $games -ExeName $entry.Exe
        if (-not $match) {
            if ($LogAction) {
                & $LogAction "Desktop export skipped (no Playnite match): nameId=$($entry.NameId) exe=$($entry.Exe)" "WARN"
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace($match.PrimaryPlayPath)) {
            if ($LogAction) {
                & $LogAction "Desktop export skipped (no play path): nameId=$($entry.NameId)" "WARN"
            }
            continue
        }

        [void]$export.Add([PSCustomObject]@{
                Id               = $match.Id
                GameId           = if ($match.GameId) { $match.GameId } else { $match.Id }
                Name             = $entry.Title
                InstallDirectory = $match.InstallDirectory
                SourceLabel      = "Desktop"
                NameId           = $entry.NameId
                Exe              = $entry.Exe
            })
    }

    return $export.ToArray()
}

function Ensure-DesktopAppAllowlistFile {
    param([string]$RepoRoot)

    $target = Get-DesktopAppAllowlistPath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $target) {
        return $target
    }

    $template = Join-Path $RepoRoot "config\playnite\desktop-apps.allowlist.json.template"
    if (-not (Test-Path -LiteralPath $template)) {
        return $null
    }

    $dir = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Copy-Item -LiteralPath $template -Destination $target -Force
    return $target
}

function Get-DefaultDesktopAppScanRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $bases = @($env:ProgramFiles)
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $bases += ${env:ProgramFiles(x86)}
    }

    $subfolders = @('Adobe', 'Autodesk', 'Blender Foundation', 'Maxon Cinema 4D', 'SketchUp', 'CapCut')
    foreach ($base in $bases) {
        if ([string]::IsNullOrWhiteSpace($base) -or -not (Test-Path -LiteralPath $base)) {
            continue
        }
        foreach ($sub in $subfolders) {
            $path = Join-Path $base $sub
            if (Test-Path -LiteralPath $path) {
                [void]$roots.Add([System.IO.Path]::GetFullPath($path))
            }
        }
    }

    return @($roots | Select-Object -Unique)
}

function Get-ExcludedSystemDriveRoots {
    <#
        Drive roots for the Windows system / boot volume (e.g. C:\) to skip on "scan all drives".
    #>
    $excluded = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    function Add-DriveRoot {
        param([string]$DriveSpec)
        if ([string]::IsNullOrWhiteSpace($DriveSpec)) { return }
        $letter = $DriveSpec.Trim().TrimEnd('\', ':')
        if ([string]::IsNullOrWhiteSpace($letter)) { return }
        $root = "$letter`:\"
        if (Test-Path -LiteralPath $root) {
            [void]$excluded.Add([System.IO.Path]::GetFullPath($root))
        }
    }

    Add-DriveRoot -DriveSpec $env:SystemDrive

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        Add-DriveRoot -DriveSpec $os.SystemDrive
    }
    catch {
    }

    try {
        Get-Partition -ErrorAction Stop |
            Where-Object { ($_.IsBoot -or $_.IsSystem) -and $_.DriveLetter } |
            ForEach-Object { Add-DriveRoot -DriveSpec $_.DriveLetter }
    }
    catch {
    }

    return @($excluded)
}

function Get-FilesystemDriveScanRoots {
    <#
        Fixed and removable drive roots (e.g. Z:\, D:\) for full-disk allowlist scan.
        By default excludes the Windows system / boot drive (typically C:\).
    #>
    param(
        [switch]$ExcludeSystemDrive
    )

    if (-not $PSBoundParameters.ContainsKey('ExcludeSystemDrive')) {
        $ExcludeSystemDrive = $true
    }

    $roots = New-Object System.Collections.Generic.List[string]
    $skipRoots = if ($ExcludeSystemDrive) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($r in (Get-ExcludedSystemDriveRoots)) { [void]$set.Add($r) }
        $set
    }
    else {
        $null
    }

    try {
        $disks = Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction Stop |
            Where-Object {
                $_.DriveType -in 2, 3 -and
                -not [string]::IsNullOrWhiteSpace($_.DeviceID) -and
                (Test-Path -LiteralPath $_.DeviceID)
            } |
            Sort-Object DeviceID

        foreach ($disk in $disks) {
            $root = [System.IO.Path]::GetFullPath($disk.DeviceID.TrimEnd('\') + '\')
            if ($skipRoots -and $skipRoots.Contains($root)) { continue }
            [void]$roots.Add($root)
        }
    }
    catch {
        Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_.Root) -and (Test-Path -LiteralPath $_.Root) } |
            ForEach-Object {
                $root = [System.IO.Path]::GetFullPath($_.Root)
                if ($skipRoots -and $skipRoots.Contains($root)) { return }
                [void]$roots.Add($root)
            }
    }

    return @($roots | Select-Object -Unique)
}

function Show-DesktopAppImportScanModeDialog {
    <#
        Returns: PickPath | AllDrives | $null (cancelled)
    #>
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Desktop apps - scan scope"
    $form.Size = New-Object System.Drawing.Size(480, 220)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(440, 56)
    $label.Text = "Import allowlisted desktop apps (Adobe, etc.).`r`nChoose how to search for executables:"
    $form.Controls.Add($label)

    $btnFolder = New-Object System.Windows.Forms.Button
    $btnFolder.Location = New-Object System.Drawing.Point(16, 88)
    $btnFolder.Size = New-Object System.Drawing.Size(210, 36)
    $btnFolder.Text = "1. Choose drive or folder..."
    $btnFolder.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $form.Controls.Add($btnFolder)

    $btnAllDrives = New-Object System.Windows.Forms.Button
    $btnAllDrives.Location = New-Object System.Drawing.Point(246, 88)
    $btnAllDrives.Size = New-Object System.Drawing.Size(210, 36)
    $btnAllDrives.Text = "2. All drives (not system)"
    $btnAllDrives.DialogResult = [System.Windows.Forms.DialogResult]::No
    $form.Controls.Add($btnAllDrives)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Location = New-Object System.Drawing.Point(16, 136)
    $btnCancel.Size = New-Object System.Drawing.Size(440, 28)
    $btnCancel.Text = "Skip desktop import"
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($btnCancel)

    $form.AcceptButton = $btnFolder
    $form.CancelButton = $btnCancel

    $result = $form.ShowDialog()
    $form.Dispose()

    switch ($result) {
        ([System.Windows.Forms.DialogResult]::Yes) { return 'PickPath' }
        ([System.Windows.Forms.DialogResult]::No) { return 'AllDrives' }
        default { return $null }
    }
}

function Resolve-DesktopAppImportScanRoots {
    param(
        [ValidateSet('Prompt', 'PickPath', 'PickFolder', 'AllDrives', 'Default')]
        [string]$Mode = 'Prompt',
        [string]$ScanPath = "",
        [string]$PickerInitialDirectory = "",
        [string]$RepoRoot = "",
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = $PSScriptRoot
    }

    $write = { param($Message, $Level = 'INFO')
        if ($LogAction) { & $LogAction $Message $Level }
    }

    $effectiveMode = $Mode
    if ($effectiveMode -eq 'Prompt') {
        $choice = Show-DesktopAppImportScanModeDialog
        if (-not $choice) {
            & $write "Desktop import skipped (no scan option selected)." "WARN"
            return @()
        }
        $effectiveMode = $choice
    }

    if ($effectiveMode -eq 'PickFolder') {
        $effectiveMode = 'PickPath'
    }

    if ($effectiveMode -eq 'PickPath') {
        $folder = $ScanPath
        if ([string]::IsNullOrWhiteSpace($folder)) {
            $initial = $PickerInitialDirectory
            if ([string]::IsNullOrWhiteSpace($initial)) {
                $saved = Read-SavedPlayniteInstallPath -RepoRoot $RepoRoot
                if ($saved) {
                    $initial = Split-Path -Path $saved -Parent
                }
            }
            if ([string]::IsNullOrWhiteSpace($initial)) {
                $initial = [Environment]::GetFolderPath('MyDocuments')
            }
            $folder = Show-PlayniteFolderPicker `
                -Description "Select drive or folder to scan for allowlisted desktop apps" `
                -InitialDirectory $initial `
                -AnchorInitialToDriveRoot
        }
        if ([string]::IsNullOrWhiteSpace($folder)) {
            & $write "Desktop import skipped (drive/folder picker cancelled)." "WARN"
            return @()
        }
        & $write "Desktop scan mode: drive or folder -> $folder"
        return @([System.IO.Path]::GetFullPath($folder))
    }

    if ($effectiveMode -eq 'AllDrives') {
        $excluded = Get-ExcludedSystemDriveRoots
        $roots = Get-FilesystemDriveScanRoots -ExcludeSystemDrive
        if ($roots.Count -eq 0) {
            & $write "Desktop import: no non-system fixed/removable drives found." "WARN"
            return @()
        }
        if ($excluded.Count -gt 0) {
            & $write ("Excluded system/boot drive(s): {0}" -f ($excluded -join ', '))
        }
        & $write ("Desktop scan mode: all non-system drives ({0}): {1}" -f $roots.Count, ($roots -join ', '))
        return $roots
    }

    $defaults = Get-DefaultDesktopAppScanRoots
    & $write ("Desktop scan mode: default vendor folders ({0})" -f $defaults.Count)
    return $defaults
}

function Invoke-HeadlessDesktopAppImport {
    <#
        Finds allowlisted exes under ScanRoots via es.exe (Everything must already be running) or directory walk (-SkipEverythingInstall).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [string]$AllowlistPath = "",
        [string[]]$ScanRoots = @(),
        [switch]$SkipEverythingInstall,
        [scriptblock]$LogAction
    )

    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $RepoRoot
    $script:DesktopImportRepoRoot = $RepoRoot
    $script:DesktopImportUseEverythingSearch = $false
    $script:DesktopImportEverythingOnly = $false

    if ($SkipEverythingInstall) {
        if ($LogAction) {
            & $LogAction "Desktop import: using directory walk (-SkipEverythingInstall)."
        }
    }
    else {
        $script:DesktopImportEverythingOnly = $true
        $script:DesktopImportUseEverythingSearch = Ensure-EverythingReady -RepoRoot $RepoRoot -LogAction $LogAction
        if ($LogAction) {
            if ($script:DesktopImportUseEverythingSearch) {
                & $LogAction "Desktop import: using es.exe only (Everything must stay running in tray/service)."
            }
            else {
                & $LogAction "Desktop import: skipped allowlist search (Everything not reachable via es.exe)." "WARN"
            }
        }
    }

    if ($script:DesktopImportEverythingOnly -and -not $script:DesktopImportUseEverythingSearch) {
        if ($LogAction) {
            & $LogAction "Desktop import aborted: start Everything (tray or service), then re-run setup or Import-PlayniteDesktopApps.ps1." "WARN"
        }
        return @{ Added = 0; Updated = 0; Pruned = 0; RootsScanned = 0 }
    }

    $allowlistFile = Ensure-DesktopAppAllowlistFile -RepoRoot $RepoRoot
    if (-not $allowlistFile) {
        if ($LogAction) {
            & $LogAction "Desktop allowlist template missing; skipped desktop import." "WARN"
        }
        return @{ Added = 0; Updated = 0; Pruned = 0; RootsScanned = 0 }
    }

    if ($LogAction) {
        & $LogAction "Using desktop allowlist: $allowlistFile"
    }

    $allowlist = Get-DesktopAppAllowlist -RepoRoot $RepoRoot -AllowlistPath $AllowlistPath
    $roots = if ($ScanRoots -and $ScanRoots.Count -gt 0) {
        @($ScanRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) })
    }
    else {
        Get-DefaultDesktopAppScanRoots
    }

    if ($roots.Count -eq 0) {
        if ($LogAction) {
            & $LogAction "No desktop scan roots found (Adobe/Autodesk/etc. under Program Files)." "WARN"
        }
        return @{ Added = 0; Updated = 0; Pruned = 0; RootsScanned = 0 }
    }

    $totals = @{ Added = 0; Updated = 0; Pruned = 0; RootsScanned = $roots.Count }

    foreach ($root in $roots) {
        if ($LogAction) {
            & $LogAction "Desktop import scanning: $root"
        }
        $stats = Sync-PlayniteDesktopAppsToAllowlist `
            -InstallDir $InstallDir `
            -ScanRoot $root `
            -Allowlist $allowlist `
            -LogAction $LogAction
        $totals.Added += $stats.Added
        $totals.Updated += $stats.Updated
        $totals.Pruned += $stats.Pruned
    }

    if ($LogAction) {
        & $LogAction ("Desktop import done: roots={0} added={1} updated={2}" -f $totals.RootsScanned, $totals.Added, $totals.Updated)
    }

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    Stop-PlayniteApplication -PlayniteExe $playniteExe

    return $totals
}
