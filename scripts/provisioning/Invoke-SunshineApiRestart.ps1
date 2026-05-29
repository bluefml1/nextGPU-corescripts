#Requires -Version 5.1
<#
.SYNOPSIS
    POST /api/reset-display-device-persistence then POST /api/restart on Sunshine HTTPS API.
    Treats curl exit 56/52 as success on restart (connection closed during restart).

.PARAMETER LoopUntilVdd
    Repeats reset + restart every -IntervalSeconds until Get-DisplayDeviceId.ps1 lists a path
    whose instance id contains MTT1337 (VDD), or -MaxAttempts is reached.
    Run from an elevated PowerShell so display enumeration works.

.PARAMETER SkipResetDisplayPersistence
    Do not call /api/reset-display-device-persistence (stock Sunshine may not expose this route).
#>
[CmdletBinding()]
param(
    [string]$User = 'bluefml1',
    [string]$Password = 'letmeinpls',
    [int]$Port = 47990,
    [int]$ReadyTimeoutSec = 60,
    [int]$WaitAfterSec = 12,
    [switch]$LoopUntilVdd,
    [int]$IntervalSeconds = 10,
    [int]$MaxAttempts = 120,
    [switch]$SkipResetDisplayPersistence,
    [int]$ResetWaitHttp200TimeoutSec = 20,
    [int]$ResetPollSeconds = 1,
    [int]$AfterRestartProbeSeconds = 8
)

$ErrorActionPreference = 'Stop'
$urlRestart = "https://localhost:${Port}/api/restart"
$urlResetPersistence = "https://localhost:${Port}/api/reset-display-device-persistence"
$cred = "${User}:${Password}"

function Write-Stamp {
    param([string]$Message)
    $ts = (Get-Date).ToString('HH:mm:ss')
    Write-Host "[$ts] $Message"
}

function Get-CurlExe {
    $c = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $c) { return $null }
    return $c.Source
}

function Test-SunshinePortOpen {
    param([int]$TcpPort)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect('127.0.0.1', $TcpPort)
        $client.Close()
        return $true
    } catch {
        return $false
    }
}

function Wait-SunshinePort {
    param([int]$TcpPort, [int]$TimeoutSec)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        if (Test-SunshinePortOpen -TcpPort $TcpPort) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-SunshineHttpPostStatusWebRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$CredPair
    )
    # Fallback when curl.exe schannel still rejects Sunshine's self-signed localhost cert (curl exit 60).
    $prevCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $user, $pass = $CredPair -split ':', 2
        if (-not $pass) { $pass = '' }
        $pairBytes = [Text.Encoding]::ASCII.GetBytes("${user}:${pass}")
        $auth = [Convert]::ToBase64String($pairBytes)
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Method = 'POST'
        $req.Accept = '*/*'
        $req.ContentType = 'application/json'
        $req.Headers['Authorization'] = "Basic $auth"
        $req.ContentLength = 0
        $req.Timeout = 30000
        try {
            $resp = $req.GetResponse()
            $code = [int][System.Net.HttpWebResponse]$resp.StatusCode
            $resp.Close()
            return [pscustomobject]@{ ExitCode = 0; HttpCode = $code; Raw = 'dotnet' }
        } catch [System.Net.WebException] {
            $we = $_.Exception
            if ($we.Response) {
                $code = [int][System.Net.HttpWebResponse]$we.Response.StatusCode
                $we.Response.Close()
                return [pscustomobject]@{ ExitCode = 0; HttpCode = $code; Raw = 'dotnet' }
            }
            # Sunshine /api/restart often drops TLS before close_notify (same as curl exit 52/56).
            if ($we.Status -in @(
                    [System.Net.WebExceptionStatus]::SendFailure,
                    [System.Net.WebExceptionStatus]::ConnectionClosed,
                    [System.Net.WebExceptionStatus]::SecureChannelFailure,
                    [System.Net.WebExceptionStatus]::TrustFailure
                ) -or $we.Message -match 'closed|reset|abort|close_notify') {
                return [pscustomobject]@{ ExitCode = 56; HttpCode = $null; Raw = 'dotnet-connection-closed' }
            }
            return [pscustomobject]@{ ExitCode = 1; HttpCode = $null; Raw = $we.Message }
        }
    } finally {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $prevCallback
    }
}

function Invoke-SunshineHttpPostStatus {
    param(
        [Parameter(Mandatory)][string]$CurlPath,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$CredPair
    )
    # Capture HTTP status code via stdout while still using curl.exe for schannel (-k / --insecure).
    # If the connection is closed during a restart, curl may exit 52/56 and status can be empty.
    $oldNative = $null
    $hadNative = $false
    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -Scope 0 -ErrorAction SilentlyContinue) {
        $hadNative = $true
        $oldNative = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Match Sunshine web UI: POST, Basic auth, Content-Type application/json, empty body (content-length 0).
        # No -S: curl must not write errors to stderr (PowerShell 7 treats that as NativeCommandError).
        # -k/--insecure/--ssl-no-revoke: Sunshine uses a self-signed cert on https://localhost:47990
        $out = & $CurlPath `
            -u $CredPair `
            -H 'Accept: */*' `
            -H 'Content-Type: application/json' `
            -X POST `
            -d '' `
            -k `
            --insecure `
            --ssl-no-revoke `
            -s `
            --max-time 30 `
            -o NUL `
            -w "%{http_code}" `
            $Url 2>$null
        $exitCode = [int]$LASTEXITCODE
    } finally {
        $ErrorActionPreference = $oldEap
        if ($hadNative) { $PSNativeCommandUseErrorActionPreference = $oldNative }
    }
    $http = $null
    if ($out -match '(\d{3})\s*$') { $http = [int]$Matches[1] }
    $raw = ($out | Out-String).Trim()
    if ($exitCode -eq 60 -or ($raw -match 'SEC_E_UNTRUSTED_ROOT|certificate.*not trusted')) {
        Write-Verbose 'curl TLS verify failed; retrying POST via .NET (trust localhost self-signed cert).'
        return Invoke-SunshineHttpPostStatusWebRequest -Url $Url -CredPair $CredPair
    }
    return [pscustomobject]@{ ExitCode = $exitCode; HttpCode = $http; Raw = $raw }
}

function Invoke-SunshineResetDisplayPersistence {
    param([string]$CurlPath, [string]$CredPair, [string]$Url)
    $r = Invoke-SunshineHttpPostStatus -CurlPath $CurlPath -Url $Url -CredPair $CredPair
    if ($r.HttpCode -eq 200) {
        return $true
    }
    return $false
}

function Invoke-SunshineRestartOnce {
    param([string]$CurlPath, [string]$CredPair, [string]$Url)
    Write-Stamp "POST $Url (restart)..."
    # Use .NET for restart: Sunshine closes the connection immediately; curl exit 56 is success but noisy in PS 7.
    $r = Invoke-SunshineHttpPostStatusWebRequest -Url $Url -CredPair $CredPair
    if ($r.ExitCode -eq 0 -or $r.ExitCode -eq 56 -or $r.ExitCode -eq 52) {
        Write-Stamp 'restart OK (Sunshine accepted restart; connection may close abruptly).'
        return $true
    }
    # Fallback to curl if .NET path failed for an unexpected reason.
    $r = Invoke-SunshineHttpPostStatus -CurlPath $CurlPath -Url $Url -CredPair $CredPair
    if ($r.ExitCode -eq 0 -or $r.ExitCode -eq 56 -or $r.ExitCode -eq 52) {
        Write-Stamp 'restart OK (curl exit 0/52/56).'
        return $true
    }
    Write-Stamp "restart FAIL (exit $($r.ExitCode), http=$($r.HttpCode))."
    return $false
}

function Wait-ResetDisplayPersistenceHttp200 {
    param(
        [string]$CurlPath,
        [string]$CredPair,
        [string]$Url,
        [int]$TimeoutSec,
        [int]$PollSec
    )
    Write-Stamp "POST $Url until HTTP 200 (timeout ${TimeoutSec}s, poll ${PollSec}s)"
    $start = Get-Date
    $n = 0
    while (((Get-Date) - $start).TotalSeconds -lt $TimeoutSec) {
        $n++
        $r = Invoke-SunshineHttpPostStatus -CurlPath $CurlPath -Url $Url -CredPair $CredPair
        $hc = if ($null -ne $r.HttpCode) { $r.HttpCode } else { 'n/a' }
        $bodyHint = if ($r.Raw -and $r.Raw -notmatch '^\d{3}$') { " body=$($r.Raw)" } else { '' }
        Write-Stamp "reset poll #$n => http=$hc curl=$($r.ExitCode)$bodyHint"
        if ($r.HttpCode -eq 200) {
            Write-Stamp 'reset-display-device-persistence OK (HTTP 200, same as Sunshine Troubleshooting UI).'
            return $true
        }
        Start-Sleep -Seconds $PollSec
    }
    Write-Stamp "reset-display-device-persistence did not reach HTTP 200 within ${TimeoutSec}s."
    return $false
}

function Test-VddDeviceIdInLog {
    $logScript = Join-Path $PSScriptRoot 'Get-SunshineDeviceIdFromLog.ps1'
    if (-not (Test-Path -LiteralPath $logScript)) { return $false }
    try {
        $id = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $logScript 2>$null
        return ($LASTEXITCODE -eq 0 -and $id -match '^\{[0-9a-fA-F-]{36}\}$')
    } catch {
        return $false
    }
}

function Test-VddDisplayPathPresent {
    $displayScript = Join-Path $PSScriptRoot 'Get-DisplayDeviceId.ps1'
    if (Test-Path -LiteralPath $displayScript) {
        try {
            $out = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $displayScript -ListAll -IncludeInactive 2>&1 | Out-String
            if ($out -match 'instance:\s*.*MTT1337' -or $out -match 'DISPLAY\\MTT1337') { return $true }
        } catch { }
    }
    return (Test-VddDeviceIdInLog)
}

function Get-DisplayPathSummary {
    $displayScript = Join-Path $PSScriptRoot 'Get-DisplayDeviceId.ps1'
    if (-not (Test-Path -LiteralPath $displayScript)) {
        return @('[!] Get-DisplayDeviceId.ps1 not found.')
    }
    try {
        $raw = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $displayScript -ListAll -IncludeInactive 2>&1
        # Keep this concise but useful; show path headers + instance lines + DISPLAY names.
        $keep = @()
        foreach ($l in $raw) {
            if ($l -match '^\[(active|inactive)\]\s+\{[0-9a-fA-F-]{36}\}$') { $keep += $l; continue }
            if ($l -match '^\s+instance:\s+') { $keep += $l; continue }
            if ($l -match '^\s+path:\s+') { $keep += $l; continue }
            if ($l -match '^\s+edid:\s+') { $keep += $l; continue }
        }
        if ($keep.Count -eq 0) { return @('[i] No display paths returned.') }
        return $keep
    } catch {
        return @('[!] Failed to run Get-DisplayDeviceId.ps1')
    }
}

$curlPath = Get-CurlExe
if (-not $curlPath) {
    Write-Warning 'curl.exe not found.'
    exit 1
}

if ($LoopUntilVdd.IsPresent) {
    Write-Host '=== Sunshine: reset display persistence + restart until VDD path appears ==='
    Write-Stamp "Interval between attempts: ${IntervalSeconds}s (max $MaxAttempts attempts)."
    Write-Stamp 'Tip: run elevated so Get-DisplayDeviceId can enumerate displays.'
    if (-not (Wait-SunshinePort -TcpPort $Port -TimeoutSec $ReadyTimeoutSec)) {
        Write-Stamp "Sunshine HTTPS API not reachable on port $Port within ${ReadyTimeoutSec}s."
        Write-Stamp 'Start Sunshine in the logged-on session: Start-Sunshine.bat or RDP logon (nextGPU-SunshineLogon task).'
        exit 1
    }
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host ""
        Write-Stamp "--- Attempt $attempt / $MaxAttempts ---"
        if (-not (Wait-SunshinePort -TcpPort $Port -TimeoutSec 30)) {
            Write-Stamp 'Sunshine port not open; waiting interval...'
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }
        if (-not $SkipResetDisplayPersistence.IsPresent) {
            if (-not (Wait-ResetDisplayPersistenceHttp200 -CurlPath $curlPath -CredPair $cred -Url $urlResetPersistence -TimeoutSec $ResetWaitHttp200TimeoutSec -PollSec $ResetPollSeconds)) {
                Write-Stamp "WARNING: reset-display-device-persistence did not return HTTP 200 within ${ResetWaitHttp200TimeoutSec}s (continuing to restart)."
            }
        } else {
            Write-Stamp "Skip reset-display-device-persistence (flag set)."
        }
        $restartOk = Invoke-SunshineRestartOnce -CurlPath $curlPath -CredPair $cred -Url $urlRestart
        if (-not $restartOk) {
            Start-Sleep -Seconds $IntervalSeconds
            continue
        }
        if ($WaitAfterSec -gt 0) {
            Write-Stamp "Waiting ${WaitAfterSec}s for Sunshine to come back..."
            Start-Sleep -Seconds $WaitAfterSec
        }
        if ($AfterRestartProbeSeconds -gt 0) {
            Write-Stamp "Probing for VDD display path for ${AfterRestartProbeSeconds}s..."
            $probeStart = Get-Date
            $lastDump = Get-Date '2000-01-01'
            while (((Get-Date) - $probeStart).TotalSeconds -lt $AfterRestartProbeSeconds) {
                if (Test-VddDisplayPathPresent) {
                    Write-Host ''
                    Write-Host '[OK] VDD (MTT1337) device_id available (display path and/or sunshine.log).'
                    exit 0
                }
                # Dump current display paths at most once every ~2 seconds to avoid spam.
                if (((Get-Date) - $lastDump).TotalSeconds -ge 2) {
                    $lastDump = Get-Date
                    $summary = Get-DisplayPathSummary
                    Write-Stamp 'Current display paths (condensed):'
                    foreach ($line in $summary) { Write-Host "  $line" }
                    $logScript = Join-Path $PSScriptRoot 'Get-SunshineDeviceIdFromLog.ps1'
                    if (Test-Path -LiteralPath $logScript) {
                        Write-Stamp 'Sunshine log VDD device_id candidates (all log paths):'
                        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $logScript -ListAll 2>$null | ForEach-Object { Write-Host "  $_" }
                    }
                }
                Start-Sleep -Seconds 1
            }
        }
        if (Test-VddDisplayPathPresent) {
            Write-Host ''
            Write-Host '[OK] VDD (MTT1337) device_id available (display path and/or sunshine.log).'
            exit 0
        }
        Write-Stamp 'VDD path not visible yet; sleeping before next reset+restart...'
        $summary = Get-DisplayPathSummary
        Write-Stamp 'End-of-attempt display paths (condensed):'
        foreach ($line in $summary) { Write-Host "  $line" }
        Start-Sleep -Seconds $IntervalSeconds
    }
    Write-Warning 'Max attempts reached without seeing VDD display path.'
    exit 1
}

Write-Host '=== Restart Sunshine (Web UI API) ==='
if (-not (Wait-SunshinePort -TcpPort $Port -TimeoutSec $ReadyTimeoutSec)) {
    Write-Warning "Sunshine port $Port not reachable within ${ReadyTimeoutSec}s; skipping API restart."
    exit 1
}

if (-not $SkipResetDisplayPersistence.IsPresent) {
    if (-not (Wait-ResetDisplayPersistenceHttp200 -CurlPath $curlPath -CredPair $cred -Url $urlResetPersistence -TimeoutSec $ResetWaitHttp200TimeoutSec -PollSec $ResetPollSeconds)) {
        Write-Warning "reset-display-device-persistence did not return HTTP 200 within ${ResetWaitHttp200TimeoutSec}s (continuing to restart)."
    }
}

if (-not (Invoke-SunshineRestartOnce -CurlPath $curlPath -CredPair $cred -Url $urlRestart)) {
    exit 1
}
Write-Host '[OK] Sunshine restart requested.'
if ($WaitAfterSec -gt 0) {
    Write-Host "  Waiting ${WaitAfterSec}s for Sunshine to come back..."
    Start-Sleep -Seconds $WaitAfterSec
}
exit 0
