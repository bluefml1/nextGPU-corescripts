#Requires -Version 5.1
<#
.SYNOPSIS
    Start NVIDIA App / Nvidia.exe in the active user session at logon.
#>
[CmdletBinding()]
param(
    [string]$NvidiaExePath = '',
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
}

function Resolve-NvidiaExePath {
    param([string]$PreferredPath)

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path -LiteralPath $PreferredPath)) {
        return $PreferredPath
    }

    $candidates = @(
        'C:\Program Files\NVIDIA Corporation\NVIDIA App\NVIDIA App.exe',
        'C:\Program Files\NVIDIA Corporation\NVIDIA App\CEF\NVIDIA App.exe',
        'C:\Program Files\NVIDIA Corporation\NVIDIA App.exe',
        'C:\Program Files\NVIDIA Corporation\Nvidia.exe'
    )
    foreach ($path in $candidates) {
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    $nvidiaRoot = 'C:\Program Files\NVIDIA Corporation'
    if (Test-Path -LiteralPath $nvidiaRoot) {
        $found = Get-ChildItem -LiteralPath $nvidiaRoot -Recurse -Filter 'Nvidia.exe' -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) {
            return $found.FullName
        }
    }

    return $null
}

$exe = Resolve-NvidiaExePath -PreferredPath $NvidiaExePath
if (-not $exe) {
    Write-Status '[!] NVIDIA executable not found. Pass -NvidiaExePath or install NVIDIA App.'
    exit 1
}

$procName = [System.IO.Path]::GetFileNameWithoutExtension($exe)
if (Get-Process -Name $procName -ErrorAction SilentlyContinue) {
    Write-Status "[*] $procName already running."
    exit 0
}

Start-Process -FilePath $exe -WindowStyle Hidden
Write-Status "[*] Started: $exe"
exit 0
