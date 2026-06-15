#Requires -Version 5.1
<#
.SYNOPSIS
    Runs a runtime .bat for Task Scheduler with stdout/stderr log append (paths with spaces/% safe).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BatPath,
    [Parameter(Mandatory)]
    [string]$StdoutLog,
    [Parameter(Mandatory)]
    [string]$StderrLog
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $BatPath)) {
    Write-Error "Batch script not found: $BatPath"
}

foreach ($logPath in @($StdoutLog, $StderrLog)) {
    $dir = Split-Path -Parent $logPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -LiteralPath $StdoutLog -Value "[$timestamp] --- scheduled run start: $BatPath ---"

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'cmd.exe'
$psi.Arguments = '/c call "{0}"' -f $BatPath
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.CreateNoWindow = $true
$psi.WorkingDirectory = Split-Path -Parent $BatPath

$proc = [System.Diagnostics.Process]::Start($psi)
$stdout = $proc.StandardOutput.ReadToEnd()
$stderr = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()

if ($stdout) {
    Add-Content -LiteralPath $StdoutLog -Value $stdout
}
if ($stderr) {
    Add-Content -LiteralPath $StderrLog -Value $stderr
}

$timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
Add-Content -LiteralPath $StdoutLog -Value "[$timestamp] --- scheduled run end (exit $($proc.ExitCode)) ---"
exit $proc.ExitCode
