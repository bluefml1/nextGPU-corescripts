#Requires -Version 5.1
<#
.SYNOPSIS
    Restore Sunshine Web UI / API credentials without reinstalling Sunshine.
.DESCRIPTION
    Runs: sunshine.exe --creds bluefml1 letmeinpls
    Then restarts Sunshine in the user session (same order as RegisterMachine / stack update).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$Username = 'bluefml1',
    [string]$Password = 'letmeinpls'
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
$sunshineExe = 'C:\Program Files\Sunshine\sunshine.exe'
$credsPath = 'C:\Program Files\Sunshine\config\credentials'

if (-not (Test-Path -LiteralPath $sunshineExe)) {
    Write-Output "ERROR: Sunshine executable not found: $sunshineExe"
    exit 1
}

Write-Output "[*] Restoring Sunshine API credentials ($Username)..."
& $sunshineExe --creds $Username $Password 2>&1 | Out-Null

if (-not (Test-Path -LiteralPath $credsPath)) {
    Write-Output "ERROR: credentials still missing after --creds: $credsPath"
    exit 1
}

Write-Output '[*] Sunshine credentials restored.'
Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

$sessionPs1 = Join-Path $repo 'scripts\provisioning\Start-Sunshine-InSession.ps1'
if (Test-Path -LiteralPath $sessionPs1) {
    Write-Output '[*] Restarting Sunshine in user session...'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $sessionPs1 -Quiet | Out-Null
}
else {
    Start-Process -FilePath $sunshineExe | Out-Null
}

Start-Sleep -Seconds 3
if (-not (Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue)) {
    Write-Output 'WARN: Sunshine process not visible after credential restore (may need interactive logon).'
    exit 2
}

Write-Output '[*] Sunshine running after credential restore.'
exit 0
