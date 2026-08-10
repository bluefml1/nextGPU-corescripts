#Requires -Version 5.1
<#
.SYNOPSIS
    Build / package NextGPU Playnite SteamLibrary_NextGPU extension output.
.EXAMPLE
    .\Build-SteamExtensions.ps1
    .\Build-SteamExtensions.ps1 -PlayniteInstallDir Z:\Playnite
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = "",
    [string]$SteamPextUrl = "https://github.com/JosefNemec/PlayniteExtensions/releases/download/2.2/SteamLibrary_Builtin_2_40.pext"
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$buildRoot = Join-Path $scriptRoot "build"
$steamOut = Join-Path $buildRoot "SteamLibrary_NextGPU"
$steamTemplate = Join-Path $scriptRoot "extension-templates\SteamLibrary_NextGPU.extension.yaml"

function Expand-ArchivePackage {
    param(
        [string]$ArchivePath,
        [string]$ExtractDir
    )

    if (-not (Test-Path -LiteralPath $ExtractDir)) {
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    }

    if ($ArchivePath -match '\.zip$|\.pext$') {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractDir -Force
        return
    }

    throw "Unsupported archive format: $ArchivePath"
}

function Resolve-SteamLibrarySource {
    param([string]$InstallDir)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $candidates += Join-Path $InstallDir "Extensions\SteamLibrary_Builtin"
        $candidates += Join-Path $InstallDir "Extensions\SteamLibrary_NextGPU"
    }

    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $path "SteamLibrary.dll")) {
            return $path
        }
    }

    return $null
}

if (Test-Path -LiteralPath $steamOut) {
    Remove-Item -LiteralPath $steamOut -Recurse -Force
}
New-Item -ItemType Directory -Path $steamOut -Force | Out-Null

$steamSource = Resolve-SteamLibrarySource -InstallDir $PlayniteInstallDir
if (-not $steamSource) {
    $installPathFile = Join-Path (Split-Path $scriptRoot -Parent) "PlayniteInstall.path"
    if ([string]::IsNullOrWhiteSpace($PlayniteInstallDir) -and (Test-Path -LiteralPath $installPathFile)) {
        $PlayniteInstallDir = (Get-Content -LiteralPath $installPathFile -Raw).Trim()
        $steamSource = Resolve-SteamLibrarySource -InstallDir $PlayniteInstallDir
    }
}

if ($steamSource) {
    Write-Host "Packaging SteamLibrary_NextGPU from $steamSource"
    Copy-Item -Path (Join-Path $steamSource '*') -Destination $steamOut -Recurse -Force
}
else {
    Write-Host "Downloading Steam library package for SteamLibrary_NextGPU..."
    $cacheDir = Join-Path $scriptRoot ".cache"
    if (-not (Test-Path -LiteralPath $cacheDir)) {
        New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    }
    $pextFile = Join-Path $cacheDir "SteamLibrary_Builtin_2_40.pext"
    if (-not (Test-Path -LiteralPath $pextFile)) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $SteamPextUrl -OutFile $pextFile -UseBasicParsing
    }
    $tempExtract = Join-Path $cacheDir ("extract_" + [guid]::NewGuid().ToString("N"))
    try {
        Expand-ArchivePackage -ArchivePath $pextFile -ExtractDir $tempExtract
        $manifest = Get-ChildItem -LiteralPath $tempExtract -Filter "extension.yaml" -Recurse | Select-Object -First 1
        if (-not $manifest) {
            throw "extension.yaml not found inside Steam .pext package"
        }
        Copy-Item -Path (Join-Path $manifest.Directory.FullName '*') -Destination $steamOut -Recurse -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempExtract) {
            Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Copy-Item -LiteralPath $steamTemplate -Destination (Join-Path $steamOut "extension.yaml") -Force
Write-Host "SteamLibrary_NextGPU -> $steamOut"
Write-Host "Build-SteamExtensions: done."
