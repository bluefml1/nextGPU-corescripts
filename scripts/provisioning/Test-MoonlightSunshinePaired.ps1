#Requires -Version 5.1
<#
.SYNOPSIS
    Exit 0 if Moonlight Web host 0 has pairing material; exit 1 if unpaired/missing.
.DESCRIPTION
    Used by auto-repair.bat. Checks moonlight-web\server\data.json hosts.0.pair_info
    for client_certificate + server_certificate (present after a successful pair).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-RepoRoot {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override) -and (Test-Path -LiteralPath $Override)) {
        return (Resolve-Path -LiteralPath $Override).Path
    }
    if ($env:NEXTGPU_REPO_ROOT -and (Test-Path -LiteralPath $env:NEXTGPU_REPO_ROOT)) {
        return (Resolve-Path -LiteralPath $env:NEXTGPU_REPO_ROOT).Path
    }
    $fromScript = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    return $fromScript
}

$repo = Resolve-RepoRoot -Override $RepoRoot
$dataPath = Join-Path $repo 'moonlight-web\server\data.json'

if (-not (Test-Path -LiteralPath $dataPath)) {
    Write-Output "UNPAIRED: data.json missing ($dataPath)"
    exit 1
}

try {
    $data = Get-Content -Raw -LiteralPath $dataPath -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Output "UNPAIRED: data.json parse failed ($($_.Exception.Message))"
    exit 1
}

$host0 = $null
if ($data.hosts -and $data.hosts.PSObject.Properties['0']) {
    $host0 = $data.hosts.'0'
}
elseif ($data.hosts -and $data.hosts[0]) {
    $host0 = $data.hosts[0]
}

if (-not $host0) {
    Write-Output 'UNPAIRED: hosts.0 missing in data.json'
    exit 1
}

$pair = $host0.pair_info
if ($null -eq $pair) {
    Write-Output 'UNPAIRED: hosts.0.pair_info missing'
    exit 1
}

$clientCert = [string]$pair.client_certificate
$serverCert = [string]$pair.server_certificate
$clientKey = [string]$pair.client_private_key

if ([string]::IsNullOrWhiteSpace($clientCert) -or
    [string]::IsNullOrWhiteSpace($serverCert) -or
    [string]::IsNullOrWhiteSpace($clientKey)) {
    Write-Output 'UNPAIRED: pair_info certificates/key incomplete'
    exit 1
}

if ($clientCert -notmatch 'BEGIN CERTIFICATE' -or $serverCert -notmatch 'BEGIN CERTIFICATE') {
    Write-Output 'UNPAIRED: pair_info certificates look invalid'
    exit 1
}

Write-Output 'PAIRED: hosts.0 pair_info present'
exit 0
