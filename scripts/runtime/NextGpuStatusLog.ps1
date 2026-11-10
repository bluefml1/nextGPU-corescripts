#Requires -Version 5.1
<#
.SYNOPSIS
    One timeline for boot, machine status changes, coordination flags and status API calls.
.DESCRIPTION
    Appends to %ProgramData%\nextGPU\Logs\status-events.log (rotated to status-events.1.log at 5 MB).
    Line format:
        2026-11-10 14:49:01.123 EVENT          src=<entry script> pid=<pid> key=value ... | message
    src is $env:NEXTGPU_STATUS_SOURCE when set (bats set it), else the outermost calling script.
    Request headers are never logged (onDemandGPUHost uses x-api-key).
#>

$script:NextGpuStatusLogDir = Join-Path $env:ProgramData 'nextGPU\Logs'
$script:NextGpuStatusLogPath = Join-Path $script:NextGpuStatusLogDir 'status-events.log'
$script:NextGpuStatusLogMaxBytes = 5MB
$script:NextGpuStatusLogMaxValueLength = 600

function Get-NextGpuStatusLogPath {
    return $script:NextGpuStatusLogPath
}

function Get-NextGpuStatusLogSource {
    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_STATUS_SOURCE)) {
        return $env:NEXTGPU_STATUS_SOURCE.Trim()
    }
    $outermost = $null
    foreach ($frame in @(Get-PSCallStack)) {
        if ($frame.ScriptName) { $outermost = $frame.ScriptName }
    }
    if ($outermost) { return (Split-Path -Leaf $outermost) }
    return 'interactive'
}

function ConvertTo-NextGpuStatusLogValue {
    param($Value)
    if ($null -eq $Value) { return '(null)' }
    $text = ([string]$Value) -replace '\s*\r?\n\s*', ' '
    $text = $text.Trim()
    if ($text.Length -gt $script:NextGpuStatusLogMaxValueLength) {
        $text = $text.Substring(0, $script:NextGpuStatusLogMaxValueLength) + '...(truncated)'
    }
    if ($text -eq '') { return '""' }
    if ($text -match '\s') { return '"' + ($text -replace '"', "'") + '"' }
    return $text
}

function Write-NextGpuStatusLog {
    <#
    .SYNOPSIS
        Append one event line. Never throws.
    #>
    param(
        [Parameter(Mandatory)][string]$Event,
        [string]$Message = '',
        [System.Collections.IDictionary]$Data
    )

    try {
        if (-not (Test-Path -LiteralPath $script:NextGpuStatusLogDir)) {
            New-Item -ItemType Directory -Path $script:NextGpuStatusLogDir -Force | Out-Null
        }

        $parts = New-Object System.Collections.Generic.List[string]
        $parts.Add((Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'))
        $parts.Add($Event.ToUpperInvariant().PadRight(14))
        $parts.Add('src=' + (ConvertTo-NextGpuStatusLogValue (Get-NextGpuStatusLogSource)))
        $parts.Add("pid=$PID")
        if ($Data) {
            foreach ($key in @($Data.Keys | Sort-Object)) {
                $parts.Add(('{0}={1}' -f $key, (ConvertTo-NextGpuStatusLogValue $Data[$key])))
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $parts.Add('| ' + ($Message -replace '\s*\r?\n\s*', ' '))
        }
        $line = ($parts -join ' ') + [Environment]::NewLine

        try {
            $info = Get-Item -LiteralPath $script:NextGpuStatusLogPath -ErrorAction SilentlyContinue
            if ($info -and $info.Length -gt $script:NextGpuStatusLogMaxBytes) {
                $rotated = Join-Path $script:NextGpuStatusLogDir 'status-events.1.log'
                Move-Item -LiteralPath $script:NextGpuStatusLogPath -Destination $rotated -Force -ErrorAction Stop
            }
        }
        catch { }

        # Heartbeat, auto-repair and boot tasks can write at the same moment.
        for ($attempt = 0; $attempt -lt 5; $attempt++) {
            try {
                $stream = New-Object System.IO.FileStream(
                    $script:NextGpuStatusLogPath,
                    [System.IO.FileMode]::Append,
                    [System.IO.FileAccess]::Write,
                    [System.IO.FileShare]::ReadWrite)
                try {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
                    $stream.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $stream.Dispose()
                }
                return
            }
            catch {
                Start-Sleep -Milliseconds 60
            }
        }
    }
    catch { }
}

function Invoke-NextGpuStatusApiPost {
    <#
    .SYNOPSIS
        POST JSON to a nextGPU API endpoint and log endpoint, body, HTTP code, duration and response.
    .OUTPUTS
        Response body string. Rethrows the original error on failure (after logging API_FAIL).
    #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Body,
        [System.Collections.IDictionary]$Headers,
        [int]$TimeoutSec = 100
    )

    $endpoint = $Uri
    try { $endpoint = ([uri]$Uri).AbsolutePath.TrimStart('/') } catch { }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }

    $request = @{
        Method          = 'Post'
        Uri             = $Uri
        ContentType     = 'application/json'
        Body            = $Body
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSec
        ErrorAction     = 'Stop'
    }
    if ($Headers) { $request.Headers = $Headers }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Invoke-WebRequest @request
        $sw.Stop()
        $content = [string]$response.Content
        Write-NextGpuStatusLog -Event 'API_OK' -Data ([ordered]@{
                endpoint = $endpoint
                http     = [int]$response.StatusCode
                ms       = $sw.ElapsedMilliseconds
                request  = $Body
                response = $content
            })
        return $content
    }
    catch {
        $sw.Stop()
        $http = 'none'
        $responseBody = ''
        try {
            $webResponse = $_.Exception.Response
            if ($webResponse) {
                $http = [int]$webResponse.StatusCode
                $reader = New-Object System.IO.StreamReader($webResponse.GetResponseStream())
                try { $responseBody = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
        }
        catch { }
        Write-NextGpuStatusLog -Event 'API_FAIL' -Data ([ordered]@{
                endpoint = $endpoint
                http     = $http
                ms       = $sw.ElapsedMilliseconds
                request  = $Body
                response = $responseBody
                error    = $_.Exception.Message
            })
        throw
    }
}

function Get-NextGpuStatusFlagSnapshot {
    <#
    .SYNOPSIS
        Current machine-status.flag and coordination flags, for BOOT / cycle log lines.
    #>
    $dir = Join-Path $env:ProgramData 'nextGPU'
    $statusPath = Join-Path $dir 'machine-status.flag'
    $status = '(missing)'
    if (Test-Path -LiteralPath $statusPath) {
        try { $status = ((Get-Content -LiteralPath $statusPath -Raw -ErrorAction Stop).Trim() -split '\r?\n')[0] } catch { $status = '(unreadable)' }
    }
    $pendingPath = Join-Path $dir 'endsession-reset-pending.flag'
    $pending = 'no'
    if (Test-Path -LiteralPath $pendingPath) {
        try { $pending = (Get-Content -LiteralPath $pendingPath -Raw -ErrorAction Stop).Trim() } catch { $pending = 'yes' }
        if ([string]::IsNullOrWhiteSpace($pending)) { $pending = 'yes(empty)' }
    }
    return [ordered]@{
        status             = $status
        heartbeatSuspended = [bool](Test-Path -LiteralPath (Join-Path $dir 'heartbeat-suspended.flag'))
        publishPending     = [bool](Test-Path -LiteralPath (Join-Path $dir 'startup-publish-pending.flag'))
        endSessionPending  = $pending
    }
}
