#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Write-Step([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-VadReady {
    try {
        $items = @(Get-PnpDevice -ErrorAction Stop | Where-Object {
            $_.InstanceId -like "ROOT\VirtualAudioDriver*" -or
            ($_.FriendlyName -and $_.FriendlyName -match "Virtual Audio|VB-Audio|CABLE")
        })
        foreach ($d in $items) {
            $problem = if ($null -ne $d.Problem) { [string]$d.Problem } else { "" }
            if ($d.Status -eq "OK" -and ($problem -eq "" -or $problem -eq "CM_PROB_NONE")) {
                return $true
            }
        }
    } catch { }
    return $false
}

if (-not (Test-Admin)) {
    Write-Step "Requesting administrator permission..."
    $args = @(
        "-NoProfile","-ExecutionPolicy","Bypass","-File","`"$PSCommandPath`""
    )
    $proc = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $args -Wait -PassThru
    exit $proc.ExitCode
}

Write-Host "======================================="
Write-Host " NextGPU VAD Fallback Installer"
Write-Host "======================================="

if (Test-VadReady) {
    Write-Ok "VAD already detected and ready. No fallback needed."
    exit 0
}

Write-Warn "Primary VAD is not ready. Running fallback flow."
Write-Step "Trying fallback package via winget (VB-CABLE)..."

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Warn "winget not found. Open Virtual Driver Control and install Virtual Audio Driver manually."
    Write-Host "Path hint: VDD-VAD-Install\VirtualDriverControl\VDD Control.exe"
    exit 2
}

$attempted = $false
$installed = $false
$candidateIds = @(
    "VB-Audio.VB-CABLE",
    "VBAudio.VBCABLE"
)

foreach ($id in $candidateIds) {
    $attempted = $true
    Write-Step ("Trying winget package: {0}" -f $id)
    & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --source winget
    $code = $LASTEXITCODE
    if ($code -eq 0) {
        $installed = $true
        Write-Ok ("Installed fallback package: {0}" -f $id)
        break
    }
    Write-Warn ("Package {0} not installed (exit {1}). Trying next candidate..." -f $id, $code)
}

Start-Sleep -Seconds 3
if (Test-VadReady) {
    Write-Ok "VAD fallback is now ready."
    exit 0
}

Write-Warn "Fallback package did not produce a ready VAD device yet."
if ($attempted -and -not $installed) {
    Write-Warn "No fallback package ID succeeded from predefined list."
}
Write-Host ""
Write-Host "Manual fallback options:"
Write-Host "1) Open Virtual Driver Control and install Virtual Audio Driver."
Write-Host "2) Install a signed virtual audio driver (VB-CABLE), then rerun status check."
Write-Host "3) Reboot and run scripts\drivers\Get-VddVadStatus.ps1"
exit 3

