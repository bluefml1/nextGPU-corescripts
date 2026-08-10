#Requires -Version 5.1
<#
.SYNOPSIS
    Exit 0 if streaming credentials look intact; exit 1 if pairing and/or Sunshine creds are missing.
.DESCRIPTION
    Used by auto-repair.bat.
    Checks:
      1) C:\Program Files\Sunshine\config\credentials (Sunshine API / Web UI)
      2) moonlight-web\server\data.json hosts.0.pair_info certs (Moonlight <-> Sunshine pair)
    Stdout lines start with OK: / MISSING: so the bat can decide restore vs re-pair.
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
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

$repo = Resolve-RepoRoot -Override $RepoRoot
$missing = New-Object System.Collections.Generic.List[string]

# --- Sunshine API credentials ---
$credsPath = 'C:\Program Files\Sunshine\config\credentials'
if (-not (Test-Path -LiteralPath $credsPath)) {
    [void]$missing.Add('sunshine-credentials')
    Write-Output "MISSING: Sunshine credentials folder ($credsPath)"
}
else {
    $credFiles = @(Get-ChildItem -LiteralPath $credsPath -File -ErrorAction SilentlyContinue)
    if ($credFiles.Count -eq 0) {
        [void]$missing.Add('sunshine-credentials')
        Write-Output "MISSING: Sunshine credentials folder is empty ($credsPath)"
    }
    else {
        Write-Output "OK: Sunshine credentials ($($credFiles.Count) file(s))"
    }
}

# --- Moonlight pairing material ---
$dataPath = Join-Path $repo 'moonlight-web\server\data.json'
$pairOk = $false

if (-not (Test-Path -LiteralPath $dataPath)) {
    [void]$missing.Add('moonlight-pairing')
    Write-Output "MISSING: data.json ($dataPath)"
}
else {
    try {
        $data = Get-Content -Raw -LiteralPath $dataPath -Encoding UTF8 | ConvertFrom-Json
        $host0 = $null
        if ($data.hosts -and $data.hosts.PSObject.Properties['0']) {
            $host0 = $data.hosts.'0'
        }
        elseif ($data.hosts -and $data.hosts[0]) {
            $host0 = $data.hosts[0]
        }

        if (-not $host0) {
            [void]$missing.Add('moonlight-pairing')
            Write-Output 'MISSING: hosts.0 in data.json'
        }
        else {
            $pair = $host0.pair_info
            $clientCert = if ($pair) { [string]$pair.client_certificate } else { '' }
            $serverCert = if ($pair) { [string]$pair.server_certificate } else { '' }
            $clientKey = if ($pair) { [string]$pair.client_private_key } else { '' }

            if ([string]::IsNullOrWhiteSpace($clientCert) -or
                [string]::IsNullOrWhiteSpace($serverCert) -or
                [string]::IsNullOrWhiteSpace($clientKey) -or
                $clientCert -notmatch 'BEGIN CERTIFICATE' -or
                $serverCert -notmatch 'BEGIN CERTIFICATE') {
                [void]$missing.Add('moonlight-pairing')
                Write-Output 'MISSING: hosts.0.pair_info certificates/key'
            }
            else {
                $pairOk = $true
                Write-Output 'OK: Moonlight pairing (pair_info present)'
            }
        }
    }
    catch {
        [void]$missing.Add('moonlight-pairing')
        Write-Output "MISSING: data.json parse failed ($($_.Exception.Message))"
    }
}

if ($missing.Count -eq 0) {
    Write-Output 'CREDENTIALS: OK'
    exit 0
}

# Exit codes for auto-repair.bat:
#   1 = pairing missing only (re-pair)
#   2 = sunshine credentials missing (restore creds; usually also re-pair)
#   3 = both missing
$hasSun = $missing -contains 'sunshine-credentials'
$hasPair = $missing -contains 'moonlight-pairing'
Write-Output ("CREDENTIALS: MISSING -> " + ($missing -join ', '))

if ($hasSun -and $hasPair) { exit 3 }
if ($hasSun) { exit 2 }
if ($hasPair) { exit 1 }
exit 1
