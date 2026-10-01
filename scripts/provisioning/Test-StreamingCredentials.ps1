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

# --- Sunshine API credentials (sunshine_state.json = UI password; PEMs are TLS only) ---
$statePath = 'C:\Program Files\Sunshine\config\sunshine_state.json'
$credsPath = 'C:\Program Files\Sunshine\config\credentials'
if (-not (Test-Path -LiteralPath $statePath)) {
    [void]$missing.Add('sunshine-credentials')
        Write-Output "MISSING: Sunshine UI state ($statePath). Run: sunshine.exe --creds bluefml1 letmeinpls"
}
else {
    $stateLen = (Get-Item -LiteralPath $statePath).Length
    if ($stateLen -lt 8) {
        [void]$missing.Add('sunshine-credentials')
        Write-Output "MISSING: sunshine_state.json too small ($stateLen bytes)"
    }
    else {
        Write-Output "OK: sunshine_state.json ($stateLen bytes)"
    }
}

# Optional: TLS material under credentials\ (not sufficient alone)
if (-not (Test-Path -LiteralPath $credsPath)) {
    Write-Output "WARN: TLS credentials folder missing ($credsPath)"
}
else {
    $pemCount = @(Get-ChildItem -LiteralPath $credsPath -Filter '*.pem' -File -ErrorAction SilentlyContinue).Count
    Write-Output "INFO: TLS pem files in credentials\: $pemCount (not a login substitute)"
}

# Live auth check when Sunshine is up
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $tcp.Connect('127.0.0.1', 47990)
    $tcp.Close()
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $httpCode = & curl.exe -k --max-redirs 0 -u 'bluefml1:letmeinpls' -s -o NUL -w '%{http_code}' --max-time 10 'https://localhost:47990/api/apps' 2>$null
        if ("$httpCode" -eq '200') {
            Write-Output 'OK: Sunshine /api/apps auth HTTP 200 (bluefml1)'
        }
        else {
            [void]$missing.Add('sunshine-credentials')
            Write-Output "MISSING: Sunshine /api/apps auth HTTP $httpCode (want 200 for bluefml1)"
        }
    }
}
catch {
    Write-Output 'INFO: Sunshine port 47990 not open; skipped live auth check'
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
