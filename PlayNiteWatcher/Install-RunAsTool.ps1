#Requires -Version 5.1
<#
.SYNOPSIS
    Download (if needed), install, and optionally launch portable RunAsTool.
.EXAMPLE
    .\Install-RunAsTool.ps1
    .\Install-RunAsTool.ps1 -Launch
    .\Install-RunAsTool.ps1 -SkipDownload
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [string]$RepoRoot = "",
    [switch]$SkipDownload,
    [switch]$Download,
    [switch]$Launch,
    [scriptblock]$LogAction
)

$ErrorActionPreference = "Stop"

function Write-RunAsToolInstallLog {
    param([string]$Message, [string]$Level = "INFO")
    if ($LogAction) {
        & $LogAction $Message $Level
    }
    else {
        $color = switch ($Level) {
            "WARN" { "Yellow" }
            "ERROR" { "Red" }
            default { "Gray" }
        }
        Write-Host "[RunAsTool] $Message" -ForegroundColor $color
    }
}

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot "Playnite-Common.ps1")
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
}

function Get-DefaultRunAsToolProgramDataDir {
    return Join-Path $env:ProgramData "NextGPU\RunAsTool"
}

function Get-RunAsToolBundledCandidates {
    param([string]$WatcherRoot)
    $toolDir = Join-Path $WatcherRoot "tools\runastool"
    return @(
        (Join-Path $toolDir "RunAsTool_x64.exe"),
        (Join-Path $toolDir "RunAsTool.exe"),
        (Join-Path $toolDir "RunAsTool\RunAsTool_x64.exe"),
        (Join-Path $toolDir "RunAsTool\RunAsTool.exe")
    )
}

function Find-RunAsToolSourceExe {
    param([string]$WatcherRoot)
    foreach ($candidate in (Get-RunAsToolBundledCandidates -WatcherRoot $WatcherRoot)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $toolDir = Join-Path $WatcherRoot "tools\runastool"
    if (Test-Path -LiteralPath $toolDir) {
        $nested = Get-ChildItem -LiteralPath $toolDir -Recurse -Filter "RunAsTool*.exe" -File -ErrorAction SilentlyContinue |
            Sort-Object { if ($_.Name -ieq "RunAsTool_x64.exe") { 0 } else { 1 } } |
            Select-Object -First 1
        if ($nested) {
            return $nested.FullName
        }
    }

    return $null
}

function Test-RunAsToolZipFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    if ((Get-Item -LiteralPath $Path).Length -lt 1000) {
        return $false
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
}

function Get-RunAsToolDownloadUrls {
    return @(
        "https://www.sordum.org/files/downloads.php?runastool",
        "https://www.sordum.org/files/runastool/download/runastool.zip"
    )
}

function Get-RunAsToolDownloadUrlFromPage {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $page = Invoke-WebRequest -Uri "https://www.sordum.org/downloads/?runastool" -UseBasicParsing -ErrorAction Stop
        $matches = [regex]::Matches($page.Content, 'href="([^"]*downloads\.php\?runastool[^"]*)"', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($match in $matches) {
            $href = $match.Groups[1].Value
            if ($href -notmatch '^https?://') {
                $href = "https://www.sordum.org$href"
            }
            return $href
        }
    }
    catch {
        Write-RunAsToolInstallLog "Could not scrape Sordum download page: $($_.Exception.Message)" "WARN"
    }
    return $null
}

function Invoke-DownloadRunAsToolZip {
    param([string]$DestinationDir)

    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    $zipPath = Join-Path $DestinationDir "runastool.zip"
    $urls = @(Get-RunAsToolDownloadUrlFromPage) + @(Get-RunAsToolDownloadUrls) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloaded = $false
    foreach ($url in $urls) {
        try {
            Write-RunAsToolInstallLog "Downloading RunAsTool from $url ..."
            if (Test-Path -LiteralPath $zipPath) {
                Remove-Item -LiteralPath $zipPath -Force
            }
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
            if (Test-RunAsToolZipFile -Path $zipPath) {
                $downloaded = $true
                break
            }
            Write-RunAsToolInstallLog "Download from $url was not a valid zip; trying next URL." "WARN"
        }
        catch {
            Write-RunAsToolInstallLog "Download failed ($url): $($_.Exception.Message)" "WARN"
        }
    }

    if (-not $downloaded) {
        throw "Could not download RunAsTool. Place RunAsTool.exe in PlayNiteWatcher\tools\runastool\ manually."
    }

    $extractRoot = Join-Path $DestinationDir "_extract"
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractRoot -Force
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue

    $found = Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter "RunAsTool*.exe" -File |
        Sort-Object { if ($_.Name -ieq "RunAsTool_x64.exe") { 0 } else { 1 } }

    if (-not $found) {
        throw "Downloaded RunAsTool archive did not contain RunAsTool.exe."
    }

    foreach ($exe in $found) {
        $dest = Join-Path $DestinationDir $exe.Name
        Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force
        Write-RunAsToolInstallLog "Extracted $($exe.Name) -> $dest"
    }

    $nestedDir = Join-Path $DestinationDir "RunAsTool"
    if (-not (Test-Path -LiteralPath $nestedDir)) {
        New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
    }
    foreach ($exe in $found) {
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $nestedDir $exe.Name) -Force
    }

    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Get-DefaultRunAsToolProgramDataDir
}

$installDir = $InstallDir.TrimEnd('\')
if (-not (Test-Path -LiteralPath $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$destExe = Join-Path $installDir "RunAsTool.exe"
$destX64 = Join-Path $installDir "RunAsTool_x64.exe"
$installedPath = $null
$alreadyInstalled = $false

if (Test-Path -LiteralPath $destX64) {
    $installedPath = $destX64
    $alreadyInstalled = $true
    Write-RunAsToolInstallLog "RunAsTool already installed: $destX64"
}
elseif (Test-Path -LiteralPath $destExe) {
    $installedPath = $destExe
    $alreadyInstalled = $true
    Write-RunAsToolInstallLog "RunAsTool already installed: $destExe"
}

$shouldDownload = (-not $SkipDownload.IsPresent) -and ($Download.IsPresent -or -not $alreadyInstalled)
$bundledDir = Join-Path $RepoRoot "tools\runastool"
if (-not (Test-Path -LiteralPath $bundledDir)) {
    New-Item -ItemType Directory -Path $bundledDir -Force | Out-Null
}

if (-not $alreadyInstalled) {
    $source = Find-RunAsToolSourceExe -WatcherRoot $RepoRoot
    if (-not $source -and $shouldDownload) {
        Invoke-DownloadRunAsToolZip -DestinationDir $bundledDir
        $source = Find-RunAsToolSourceExe -WatcherRoot $RepoRoot
    }

    if (-not $source) {
        throw @(
            "RunAsTool.exe not found. Download from https://www.sordum.org/downloads/?runastool",
            "and place RunAsTool.exe in: $bundledDir",
            "Or run: Install-RunAsTool.ps1 (auto-downloads when missing)"
        ) -join "`n"
    }

    $leaf = [System.IO.Path]::GetFileName($source)
    $target = Join-Path $installDir $leaf
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-RunAsToolInstallLog "Installed RunAsTool: $target"
    $installedPath = $target
}

$result = [PSCustomObject]@{
    Path      = $installedPath
    Installed = (-not $alreadyInstalled)
    Launched  = $false
    Process   = $null
}

if ($Launch.IsPresent -and $installedPath) {
    $proc = Start-RunAsToolApplication -ExePath $installedPath
    $result.Launched = $true
    $result.Process = $proc
}

return $result
