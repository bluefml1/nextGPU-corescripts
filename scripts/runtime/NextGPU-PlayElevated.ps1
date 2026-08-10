#Requires -Version 5.1
<#
.SYNOPSIS
  Ask NextGPUService to launch an exe as NextGPU-Admin (Playnite Play-button wrapper).

.DESCRIPTION
  Connects to \\.\pipe\NextGPUControl as the calling user (typically nextGPU) and
  sends op=launch-elevated with the target exe. The SYSTEM service performs
  CreateProcessWithLogonW into the nextGPU session.

  Used for Admin-marked Desktop File games (direct exe) and for Steam Play clicks
  (Exe = steam.exe, Args = -applaunch {SteamAppId}).

.PARAMETER Exe
  Full path to the executable to elevate (game/desktop exe, or steam.exe).

.PARAMETER WorkingDir
  Optional working directory (defaults to parent of Exe).

.PARAMETER Args
  Optional arguments (e.g. -applaunch 730 for Steam).

.PARAMETER TimeoutMs
  Pipe connect + elevate wait (default 60000).

.PARAMETER Wait
  If set, wait for the returned PID to exit (Playnite tracking convenience).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Exe,

    [string]$WorkingDir = '',

    [string]$Args = '',

    [int]$TimeoutMs = 60000,

    [switch]$Wait
)

$ErrorActionPreference = 'Stop'
$PipeName = 'NextGPUControl'
$LogDir = Join-Path $env:ProgramData 'nextGPU\logs'
$LogFile = Join-Path $LogDir 'play-elevated.log'

function Write-PlayElevatedLog {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
    Write-Host $line
}

function Send-NextGpuLaunchElevated {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [string]$GameArgs,
        [string]$Cwd,
        [int]$Timeout
    )

    $request = @{
        version    = 1
        op         = 'launch-elevated'
        appID      = 0
        exe        = $ExePath
        args       = $GameArgs
        workingDir = $Cwd
    }
    $requestJson = $request | ConvertTo-Json -Compress
    $requestBytes = [System.Text.Encoding]::UTF8.GetBytes($requestJson)

    $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
        '.',
        $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        [System.IO.Pipes.PipeOptions]::Asynchronous)

    $connectDeadline = [datetime]::UtcNow.AddMilliseconds([Math]::Max($Timeout, 1))
    $connected = $false
    $lastConnectError = $null
    while ([datetime]::UtcNow -lt $connectDeadline) {
        try {
            $remainingMs = [int][Math]::Max(1, ($connectDeadline - [datetime]::UtcNow).TotalMilliseconds)
            $attemptMs = [Math]::Min(5000, $remainingMs)
            $pipe.Connect($attemptMs)
            $connected = $true
            break
        }
        catch {
            $lastConnectError = $_
            try { $pipe.Dispose() } catch { }
            $pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
                '.',
                $PipeName,
                [System.IO.Pipes.PipeDirection]::InOut,
                [System.IO.Pipes.PipeOptions]::Asynchronous)
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $connected) {
        throw "Pipe connection to $PipeName failed: $lastConnectError"
    }

    try {
        $pipe.Write([BitConverter]::GetBytes($requestBytes.Length), 0, 4)
        $pipe.Write($requestBytes, 0, $requestBytes.Length)
        $pipe.WaitForPipeDrain()

        $lenBuf = New-Object byte[] 4
        if ($pipe.Read($lenBuf, 0, 4) -lt 4) {
            throw 'Server returned short length header'
        }
        $len = [BitConverter]::ToUInt32($lenBuf, 0)
        if ($len -gt 1MB) {
            throw "Server returned implausible length: $len"
        }

        $respBuf = New-Object byte[] $len
        $total = 0
        while ($total -lt $len) {
            $r = $pipe.Read($respBuf, $total, $len - $total)
            if ($r -eq 0) { break }
            $total += $r
        }

        $respJson = [System.Text.Encoding]::UTF8.GetString($respBuf, 0, $total)
        return ($respJson | ConvertFrom-Json)
    }
    finally {
        $pipe.Dispose()
    }
}

# --- main ---
$Exe = $Exe.Trim().Trim('"')
if (-not (Test-Path -LiteralPath $Exe)) {
    Write-PlayElevatedLog 'ERROR' "Executable not found: $Exe"
    exit 2
}

if ([string]::IsNullOrWhiteSpace($WorkingDir)) {
    $WorkingDir = Split-Path -Parent $Exe
}

Write-PlayElevatedLog 'INFO' "Elevate request exe=$Exe cwd=$WorkingDir args=$Args user=$env:USERNAME"

try {
    $resp = Send-NextGpuLaunchElevated -ExePath $Exe -GameArgs $Args -Cwd $WorkingDir -Timeout $TimeoutMs
}
catch {
    Write-PlayElevatedLog 'ERROR' "Launch failed: $_"
    exit 1
}

Write-PlayElevatedLog 'INFO' ("Service response: " + ($resp | ConvertTo-Json -Compress))

if ($resp.ok -ne $true) {
    Write-PlayElevatedLog 'ERROR' "Service rejected elevate: $($resp.error)"
    exit 1
}

$gamePid = [int]$resp.pid
Write-PlayElevatedLog 'INFO' "Elevated PID: $gamePid"

if ($Wait -and $gamePid -gt 0) {
    $proc = Get-Process -Id $gamePid -ErrorAction SilentlyContinue
    if ($proc) {
        Write-PlayElevatedLog 'INFO' 'Waiting for process exit...'
        $null = $proc.WaitForExit()
        Write-PlayElevatedLog 'INFO' "Process exited code=$($proc.ExitCode)"
    }
    else {
        Write-PlayElevatedLog 'WARN' "PID $gamePid already gone (settled elsewhere)"
    }
}

exit 0
