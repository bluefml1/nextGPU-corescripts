#Requires -Version 5.1
<#
.SYNOPSIS
    Upload verified RunAsTool v1.5 zip to R2 for host-wide vendored fetch.
.EXAMPLE
    .\Push-RunAsToolVendoredZipToR2.ps1 -SourceZip .\tools\runastool\RunAsTool-1.5.zip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceZip,
    [string]$RemoteName = 'r2games',
    [string]$RemotePath = 'next-gpu-storage-app/RunAsTool-1.5.zip'
)

$ErrorActionPreference = 'Stop'
$fetchScript = Join-Path $PSScriptRoot 'Fetch-RunAsToolVendoredZip.ps1'
if (-not (Test-Path -LiteralPath $fetchScript)) {
    throw "Required file missing: $fetchScript"
}

$src = [System.IO.Path]::GetFullPath($SourceZip.Trim().Trim('"'))
if (-not (Test-Path -LiteralPath $src)) {
    throw "Source zip not found: $src"
}

# Validate via fetch helper (throws if hash wrong)
$tempDest = Join-Path $env:TEMP ("RunAsTool-vendor-check-{0}.zip" -f ([guid]::NewGuid().ToString('N')))
try {
    & $fetchScript -SourceZip $src -DestinationZip $tempDest
}
finally {
    if (Test-Path -LiteralPath $tempDest) { Remove-Item -LiteralPath $tempDest -Force -ErrorAction SilentlyContinue }
}

$rclone = Get-Command rclone -ErrorAction SilentlyContinue
if (-not $rclone) {
    throw 'rclone not found.'
}

$config = Join-Path $env:USERPROFILE '.config\rclone\rclone.conf'
if (-not (Test-Path -LiteralPath $config)) {
    throw "rclone config not found: $config"
}

$remoteSpec = "${RemoteName}:$($RemotePath.Trim().TrimStart('/'))"
Write-Host "[RunAsTool] Uploading $src -> $remoteSpec" -ForegroundColor Cyan
& rclone.exe copyto $src $remoteSpec --config $config
if ($LASTEXITCODE -ne 0) {
    throw "rclone upload failed (exit $LASTEXITCODE)."
}

Write-Host "[OK] Uploaded. Hosts can run: .\Fetch-RunAsToolVendoredZip.ps1" -ForegroundColor Green
