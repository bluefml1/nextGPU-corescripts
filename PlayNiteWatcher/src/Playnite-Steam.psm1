#Requires -Version 5.1
# SQLite, archive tools, and Playnite extension installation helpers

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
            if ($relativeOrAbsolute -match '^https?://') { return $relativeOrAbsolute }
            return "https://www.sqlite.org/$relativeOrAbsolute"
        }
    }
    throw "Could not find sqlite-tools-win-x64 download link on sqlite.org."
}

function Install-Sqlite3ToolsPortable {
    param([scriptblock]$LogAction)
    $toolsDir = Get-SqliteToolsDirectory
    $exePath = Join-Path $toolsDir "sqlite3.exe"
    if (Test-Path -LiteralPath $exePath) { return $exePath }
    if ($LogAction) { & $LogAction "Downloading SQLite tools (portable sqlite3.exe)..." "INFO" }
    New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
    $downloadUrl = Get-SqliteToolsWinX64DownloadUrl
    $zipPath = Join-Path $toolsDir "sqlite-tools-download.zip"
    $extractDir = Join-Path $toolsDir "_extract"
    if (Test-Path -LiteralPath $extractDir) { Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
    $sqliteExe = Get-ChildItem -Path $extractDir -Recurse -Filter "sqlite3.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $sqliteExe) { throw "Downloaded SQLite tools archive did not contain sqlite3.exe." }
    Copy-Item -LiteralPath $sqliteExe.FullName -Destination $exePath -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    if ($LogAction) { & $LogAction "Installed sqlite3.exe to: $exePath" "INFO" }
    return $exePath
}

function Get-Sqlite3Executable {
    param([switch]$AllowBootstrap, [scriptblock]$LogAction)
    $fromPath = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }
    $bundled = Join-Path (Get-SqliteToolsDirectory) "sqlite3.exe"
    if (Test-Path -LiteralPath $bundled) { return $bundled }
    if ($AllowBootstrap) { return Install-Sqlite3ToolsPortable -LogAction $LogAction }
    return $null
}

function Ensure-Sqlite3Available {
    param([scriptblock]$LogAction)
    $exe = Get-Sqlite3Executable -AllowBootstrap:$false -LogAction $LogAction
    if ($exe) { return $exe }
    if ($LogAction) { & $LogAction "sqlite3 not found on PATH; installing portable copy into tools\sqlite..." "INFO" }
    return Get-Sqlite3Executable -AllowBootstrap -LogAction $LogAction
}

function Expand-PlaynitePackageArchive {
    param([string]$ArchivePath, [string]$ExtractDir, [scriptblock]$LogAction)
    if (-not (Test-Path -LiteralPath $ExtractDir)) { New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null }
    $ext = [System.IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()
    $archiveToExpand = $ArchivePath
    if ($ext -eq '.pext') {
        $archiveToExpand = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetFileName($ArchivePath) + '.zip')
        Copy-Item -LiteralPath $ArchivePath -Destination $archiveToExpand -Force
        $ext = '.zip'
    }
    if ($ext -eq '.zip') {
        try {
            if ($LogAction) { & $LogAction "Extracting package: $ArchivePath" }
            Expand-Archive -LiteralPath $archiveToExpand -DestinationPath $ExtractDir -Force
            return
        }
        catch {
            if ($LogAction) { & $LogAction ('Expand-Archive failed: ' + $_.Exception.Message) 'WARN' }
        }
    }
    $sevenZip = Get-7ZipExecutable
    if (-not $sevenZip) { throw "Cannot extract $ArchivePath. Install 7-Zip or ensure .pext/.zip packages can be expanded." }
    if ($LogAction) { & $LogAction "Extracting with 7-Zip: $sevenZip" }
    $proc = Start-Process -FilePath $sevenZip -ArgumentList @('x', $archiveToExpand, "-o$ExtractDir", '-y') -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) { throw "7-Zip extraction failed (exit $($proc.ExitCode))." }
}

function Get-PlayniteExtensionPackageUrlFromManifest {
    param([string]$ManifestUrl, [string]$FallbackPackageUrl)
    if ([string]::IsNullOrWhiteSpace($ManifestUrl)) { return $FallbackPackageUrl }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $yaml = (Invoke-WebRequest -Uri $ManifestUrl -UseBasicParsing).Content
        $urlMatches = [regex]::Matches($yaml, 'PackageUrl:\s*(\S+)')
        if ($urlMatches.Count -gt 0) { return $urlMatches[$urlMatches.Count - 1].Groups[1].Value }
    }
    catch { }
    return $FallbackPackageUrl
}

function Get-PlayniteExtensionManifestField {
    param([string]$ManifestPath, [string]$FieldName)
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $null }
    foreach ($line in (Get-Content -LiteralPath $ManifestPath -ErrorAction SilentlyContinue)) {
        if ($line -match ('^{0}:\s*(.+)$' -f [regex]::Escape($FieldName))) { return $Matches[1].Trim() }
    }
    return $null
}

function Test-PlayniteLibraryExtensionInstalled {
    param([string]$InstallDir, [string]$ExtensionId = "", [string]$PluginId = "")
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { return $false }
    if ([string]::IsNullOrWhiteSpace($ExtensionId) -and [string]::IsNullOrWhiteSpace($PluginId)) { return $false }
    $extensionsDir = Join-Path $InstallDir 'Extensions'
    if (-not (Test-Path -LiteralPath $extensionsDir)) { return $false }
    if (-not [string]::IsNullOrWhiteSpace($ExtensionId)) {
        $byId = Join-Path $extensionsDir $ExtensionId
        $manifestPath = Join-Path $byId 'extension.yaml'
        if (Test-Path -LiteralPath $manifestPath) {
            $manifestId = Get-PlayniteExtensionManifestField -ManifestPath $manifestPath -FieldName 'Id'
            if ($manifestId -ieq $ExtensionId) { return $true }
        }
    }
    foreach ($folder in (Get-ChildItem -LiteralPath $extensionsDir -Directory -ErrorAction SilentlyContinue)) {
        $manifestPath = Join-Path $folder.FullName 'extension.yaml'
        if (-not (Test-Path -LiteralPath $manifestPath)) { continue }
        $manifestId = Get-PlayniteExtensionManifestField -ManifestPath $manifestPath -FieldName 'Id'
        if (-not [string]::IsNullOrWhiteSpace($ExtensionId) -and $manifestId -ieq $ExtensionId) { return $true }
        if (-not [string]::IsNullOrWhiteSpace($PluginId)) {
            $content = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction SilentlyContinue
            if ($content -and ($content -match [regex]::Escape($PluginId))) { return $true }
        }
    }
    return $false
}

function Install-PlayniteExtensionFromPextFile {
    param([string]$InstallDir, [string]$PextPath, [string]$ExtensionId, [string]$PluginId = "", [scriptblock]$LogAction)
    if (Test-PlayniteLibraryExtensionInstalled -InstallDir $InstallDir -ExtensionId $ExtensionId -PluginId $PluginId) {
        if ($LogAction) { & $LogAction "Library extension already installed ($ExtensionId)." }
        return
    }
    if (-not (Test-Path -LiteralPath $PextPath)) { throw "Extension package not found: $PextPath" }
    $tempExtract = Join-Path ([System.IO.Path]::GetTempPath()) ('playnite_ext_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
    try {
        Expand-PlaynitePackageArchive -ArchivePath $PextPath -ExtractDir $tempExtract -LogAction $LogAction
        $manifestFile = Get-ChildItem -LiteralPath $tempExtract -Filter 'extension.yaml' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $manifestFile) { throw "extension.yaml not found inside package: $PextPath" }
        $extRoot = $manifestFile.Directory.FullName
        $manifestId = Get-PlayniteExtensionManifestField -ManifestPath $manifestFile.FullName -FieldName 'Id'
        $folderName = if (-not [string]::IsNullOrWhiteSpace($manifestId)) { $manifestId } else { $ExtensionId }
        if ([string]::IsNullOrWhiteSpace($folderName)) { throw "Could not determine extension folder name from package: $PextPath" }
        $extensionsDir = Join-Path $InstallDir 'Extensions'
        if (-not (Test-Path -LiteralPath $extensionsDir)) { New-Item -ItemType Directory -Path $extensionsDir -Force | Out-Null }
        $dest = Join-Path $extensionsDir $folderName
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath $extRoot -Destination $dest -Recurse -Force
        if (-not (Test-PlayniteLibraryExtensionInstalled -InstallDir $InstallDir -ExtensionId $folderName -PluginId $PluginId)) {
            throw "Extension install verification failed for $folderName at $dest"
        }
        if ($LogAction) { & $LogAction "Installed library extension: $dest" }
    }
    finally {
        if (Test-Path -LiteralPath $tempExtract) { Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-NextGpuSteamExtensionsBuildRoot {
    param([string]$RepoRoot)
    $root = Resolve-PlayNiteWatcherRepoRoot -Candidate $RepoRoot
    return Join-Path $root 'SteamExtensions\build'
}

function Install-NextGpuSteamExtensions {
    param([string]$InstallDir, [string]$RepoRoot, [scriptblock]$LogAction)
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { throw 'InstallDir is required.' }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { throw 'RepoRoot is required.' }
    $buildRoot = Get-NextGpuSteamExtensionsBuildRoot -RepoRoot $RepoRoot
    $steamSource = Join-Path $buildRoot 'SteamLibrary_NextGPU'
    if (-not (Test-Path -LiteralPath (Join-Path $steamSource 'SteamLibrary.dll'))) {
        throw "NextGPU Steam extension build not found: $steamSource. Run PlayNiteWatcher\SteamExtensions\Build-SteamExtensions.ps1 first."
    }
    $extensionsDir = Join-Path $InstallDir 'Extensions'
    if (-not (Test-Path -LiteralPath $extensionsDir)) { New-Item -ItemType Directory -Path $extensionsDir -Force | Out-Null }
    $legacySteam = Join-Path $extensionsDir 'SteamLibrary_Builtin'
    if (Test-Path -LiteralPath $legacySteam) {
        if ($LogAction) { & $LogAction "Migrating away from official Steam extension: removing $legacySteam" "INFO" }
        Remove-Item -LiteralPath $legacySteam -Recurse -Force
    }
    $dest = Join-Path $extensionsDir 'SteamLibrary_NextGPU'
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath $steamSource -Destination $dest -Recurse -Force
    if ($LogAction) { & $LogAction "Installed NextGPU extension: $dest" }
    if ($LogAction) { & $LogAction "Installed NextGPU Steam extension (SteamLibrary_NextGPU)" }
}

function Install-PlayniteBuiltinLibraryExtensions {
    param([string]$InstallDir, [string]$RepoRoot, [scriptblock]$LogAction)
    if ([string]::IsNullOrWhiteSpace($InstallDir)) { throw 'InstallDir is required.' }
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { throw 'RepoRoot is required.' }
    Install-NextGpuSteamExtensions -InstallDir $InstallDir -RepoRoot $RepoRoot -LogAction $LogAction
    $configPath = Join-Path $RepoRoot 'config\playnite\builtin-library-extensions.json'
    if (-not (Test-Path -LiteralPath $configPath)) { throw "Missing extension config: $configPath" }
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $config.extensions) { throw "No extensions defined in $configPath" }
    $downloadDir = Get-PlayniteDownloadDir -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $downloadDir)) { New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    foreach ($entry in $config.extensions) {
        $name = $entry.name
        $extensionId = $entry.extensionId.ToString()
        $pluginId = if ($entry.pluginId) { $entry.pluginId.ToString() } else { "" }
        $fallbackUrl = $entry.packageUrl
        $manifestUrl = $entry.manifestUrl
        if (Test-PlayniteLibraryExtensionInstalled -InstallDir $InstallDir -ExtensionId $extensionId -PluginId $pluginId) {
            if ($LogAction) { & $LogAction "$name library extension already present; skipping download." }
            continue
        }
        $packageUrl = Get-PlayniteExtensionPackageUrlFromManifest -ManifestUrl $manifestUrl -FallbackPackageUrl $fallbackUrl
        if ([string]::IsNullOrWhiteSpace($packageUrl)) { throw "No package URL for $name library extension." }
        $fileName = [System.IO.Path]::GetFileName(($packageUrl -split '\?')[0])
        $localPext = Join-Path $downloadDir $fileName
        if (-not (Test-Path -LiteralPath $localPext)) {
            if ($LogAction) { & $LogAction "Downloading $name library extension: $packageUrl" }
            Invoke-WebRequest -Uri $packageUrl -OutFile $localPext -UseBasicParsing
        }
        elseif ($LogAction) { & $LogAction "Using cached $name extension package: $localPext" }
        Install-PlayniteExtensionFromPextFile -InstallDir $InstallDir -PextPath $localPext -ExtensionId $extensionId -PluginId $pluginId -LogAction $LogAction
    }
}

Export-ModuleMember -Function @(
    'Get-DefaultSunshineConfigPath',
    'Get-SqliteToolsDirectory',
    'Get-SqliteToolsWinX64DownloadUrl',
    'Install-Sqlite3ToolsPortable',
    'Get-Sqlite3Executable',
    'Ensure-Sqlite3Available',
    'Expand-PlaynitePackageArchive',
    'Get-PlayniteExtensionPackageUrlFromManifest',
    'Get-PlayniteExtensionManifestField',
    'Test-PlayniteLibraryExtensionInstalled',
    'Install-PlayniteExtensionFromPextFile',
    'Get-NextGpuSteamExtensionsBuildRoot',
    'Install-NextGpuSteamExtensions',
    'Install-PlayniteBuiltinLibraryExtensions'
)
