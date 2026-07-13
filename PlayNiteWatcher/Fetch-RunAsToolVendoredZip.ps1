#Requires -Version 5.1
<#
.SYNOPSIS
    Place verified RunAsTool v1.5 zip in PlayNiteWatcher\tools\runastool\RunAsTool-1.5.zip (Option A).
.DESCRIPTION
    Copies from -SourceZip, or downloads from R2 (next-gpu-storage-app/RunAsTool-1.5.zip).
    Internet Archive is not used here (often 429). After this, bypass setup works offline.
.EXAMPLE
    .\Fetch-RunAsToolVendoredZip.ps1 -SourceZip D:\Backups\RunAsTool-1.5.zip
    .\Fetch-RunAsToolVendoredZip.ps1
#>
[CmdletBinding()]
param(
    [string]$SourceZip = '',
    [string]$DestinationZip = '',
    [string]$RemoteName = 'r2games',
    [string]$RemotePath = 'next-gpu-storage-app/RunAsTool-1.5.zip'
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
$toolDir = Join-Path $scriptRoot 'tools\runastool'
if ([string]::IsNullOrWhiteSpace($DestinationZip)) {
    $DestinationZip = Join-Path $toolDir 'RunAsTool-1.5.zip'
}

$script:RunAsToolPinnedZipSha256 = @(
    'bfe64c76792dc3dd40206895ed49c0ca462f6f618485060c96fa2d57dddc1e60',
    '3b31dbfca6670cf92080059cc5e165570a05e8674a4f154a67330d658906a823'
)

function Write-FetchLog {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Cyan' } }
    Write-Host "[RunAsTool] $Message" -ForegroundColor $color
}

function Test-RunAsToolZipFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    if ((Get-Item -LiteralPath $Path).Length -lt 1000) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
}

function Test-RunAsToolPinnedZipHash {
    param([string]$Path)
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($script:RunAsToolPinnedZipSha256 -contains $hash)
}

function Install-VerifiedRunAsToolVendoredZip {
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestPath
    )

    if (-not (Test-RunAsToolZipFile -Path $SourcePath)) {
        throw "Source is not a valid zip: $SourcePath"
    }
    if (-not (Test-RunAsToolPinnedZipHash -Path $SourcePath)) {
        $got = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
        throw "Source SHA256 $got is not a known RunAsTool v1.5 archive. Refusing to install (live sordum.org serves v1.6)."
    }

    $destParent = Split-Path -Parent $DestPath
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }

    $temp = "$DestPath.tmp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    Copy-Item -LiteralPath $SourcePath -Destination $temp -Force
    if (Test-Path -LiteralPath $DestPath) { Remove-Item -LiteralPath $DestPath -Force }
    Move-Item -LiteralPath $temp -Destination $DestPath -Force
    Write-FetchLog "Vendored zip ready: $DestPath"
}

function Get-RcloneExecutable {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($path in @(
            "${env:ProgramFiles}\rclone\rclone.exe",
            "${env:ProgramFiles(x86)}\rclone\rclone.exe",
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\rclone.exe')
        )) {
        if ($path -and (Test-Path -LiteralPath $path)) { return $path }
    }
    return $null
}

function Get-DefaultRcloneConfigPath {
    return Join-Path $env:USERPROFILE '.config\rclone\rclone.conf'
}

function Invoke-DownloadRunAsToolVendoredZipFromR2 {
    param(
        [Parameter(Mandatory)][string]$DestPath,
        [string]$Remote = 'r2games',
        [string]$ObjectPath = 'next-gpu-storage-app/RunAsTool-1.5.zip'
    )

    $rclone = Get-RcloneExecutable
    if (-not $rclone) {
        throw 'rclone not found. Install rclone or use -SourceZip.'
    }

    $config = Get-DefaultRcloneConfigPath
    if (-not (Test-Path -LiteralPath $config)) {
        throw "rclone config not found: $config (run Sync Game/Apps Officially once, or use -SourceZip)."
    }

    $remoteSpec = "${Remote}:$($ObjectPath.Trim().TrimStart('/'))"
    $temp = "$DestPath.download"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }

    Write-FetchLog "Downloading from R2: $remoteSpec"
    $args = @('copyto', $remoteSpec, $temp, '--config', $config)
    & $rclone @args
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temp) -or (Get-Item -LiteralPath $temp).Length -lt 1000) {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        throw "rclone copyto failed or R2 object missing (exit $LASTEXITCODE). Upload RunAsTool-1.5.zip with Push-RunAsToolVendoredZipToR2.ps1 first."
    }

    try {
        Install-VerifiedRunAsToolVendoredZip -SourcePath $temp -DestPath $DestPath
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

if ((Test-Path -LiteralPath $DestinationZip) -and (Test-RunAsToolZipFile -Path $DestinationZip) -and (Test-RunAsToolPinnedZipHash -Path $DestinationZip)) {
    Write-FetchLog "Already present: $DestinationZip"
    exit 0
}

if (-not [string]::IsNullOrWhiteSpace($SourceZip)) {
    $src = [System.IO.Path]::GetFullPath($SourceZip.Trim().Trim('"'))
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Source zip not found: $src"
    }
    Install-VerifiedRunAsToolVendoredZip -SourcePath $src -DestPath $DestinationZip
    exit 0
}

try {
    Invoke-DownloadRunAsToolVendoredZipFromR2 -DestPath $DestinationZip -Remote $RemoteName -ObjectPath $RemotePath
    exit 0
}
catch {
    Write-FetchLog $_.Exception.Message 'ERROR'
    Write-FetchLog @(
        'Option A requires RunAsTool v1.5 zip at:',
        "  $DestinationZip",
        'Obtain it once from another host (or Internet Archive when not rate-limited), then either:',
        '  .\Fetch-RunAsToolVendoredZip.ps1 -SourceZip <path-to-RunAsTool-1.5.zip>',
        '  .\Push-RunAsToolVendoredZipToR2.ps1 -SourceZip <path>  (then re-run this script)',
        'Expected SHA256 (either):',
        "  $($script:RunAsToolPinnedZipSha256[0])"
    ) -join "`n" 'WARN'
    exit 1
}
