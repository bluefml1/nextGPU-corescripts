#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Sends a ping to the NextGPUService via the named pipe and reports success/failure.
#>
param(
    [string]$PipeName = "NextGPUControl",
    [int]$TimeoutMs = 5000
)

$ErrorActionPreference = "Stop"

$request = @{ version = 1; op = "ping" } | ConvertTo-Json -Compress
$requestBytes = [System.Text.Encoding]::UTF8.GetBytes($request)

$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(
    ".",
    $PipeName,
    [System.IO.Pipes.PipeDirection]::InOut,
    [System.IO.Pipes.PipeOptions]::Asynchronous)

try {
    $pipe.Connect($TimeoutMs)
} catch {
    Write-Error "Failed to connect to pipe $PipeName`: $_"
    exit 1
}

try {
    $lenBytes = [BitConverter]::GetBytes($requestBytes.Length)
    $pipe.Write($lenBytes, 0, 4)
    $pipe.Write($requestBytes, 0, $requestBytes.Length)
    $pipe.WaitForPipeDrain()

    $lenBuf = New-Object byte[] 4
    $read = $pipe.Read($lenBuf, 0, 4)
    if ($read -lt 4) {
        Write-Error "Server returned short length header"
        exit 1
    }
    $len = [BitConverter]::ToUInt32($lenBuf, 0)

    if ($len -gt 1MB) {
        Write-Error "Server returned implausible length: $len"
        exit 1
    }

    $respBuf = New-Object byte[] $len
    $total = 0
    while ($total -lt $len) {
        $r = $pipe.Read($respBuf, $total, $len - $total)
        if ($r -eq 0) { break }
        $total += $r
    }

    $resp = [System.Text.Encoding]::UTF8.GetString($respBuf, 0, $total) | ConvertFrom-Json

    if ($resp.ok -eq $true) {
        Write-Output "OK: NextGPUService pipe is responsive"
        exit 0
    } else {
        Write-Error "Server returned ok=false: $($resp | ConvertTo-Json -Compress)"
        exit 1
    }
} finally {
    $pipe.Dispose()
}
