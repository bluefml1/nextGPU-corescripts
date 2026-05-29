<#
.SYNOPSIS
    Remove all files and shortcuts from the nextGPU user's Desktop folder.
.DESCRIPTION
    Intended for rental sessions: run at nextGPU logon (scheduled task) or once from setup (elevated).
    Does not modify Public Desktop (affects all users). Only clears the nextGPU profile Desktop path.
#>
[CmdletBinding()]
param(
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

function Write-Status([string]$Message) {
    if (-not $Quiet) { Write-Host $Message }
}

function Get-NextGpuDesktopPath {
    if ($env:USERNAME -ieq 'nextGPU') {
        return [System.Environment]::GetFolderPath('Desktop')
    }

    $localUser = Get-LocalUser -Name 'nextGPU' -ErrorAction SilentlyContinue
    if (-not $localUser) {
        return $null
    }

    $sid = $localUser.Sid.Value
    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    if (Test-Path -LiteralPath $profileKey) {
        $imagePath = (Get-ItemProperty -LiteralPath $profileKey -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
        if (-not [string]::IsNullOrWhiteSpace($imagePath)) {
            return (Join-Path $imagePath 'Desktop')
        }
    }

    return Join-Path $env:SystemDrive 'Users\nextGPU\Desktop'
}

$desktop = Get-NextGpuDesktopPath
if ([string]::IsNullOrWhiteSpace($desktop)) {
    Write-Status '[*] Local user nextGPU not found; nothing to clear.'
    exit 0
}

if (-not (Test-Path -LiteralPath $desktop)) {
    Write-Status "[*] Desktop folder not present yet: $desktop"
    exit 0
}

$items = @(Get-ChildItem -LiteralPath $desktop -Force -ErrorAction SilentlyContinue)
if ($items.Count -eq 0) {
    Write-Status "[*] Desktop already empty: $desktop"
    exit 0
}

foreach ($item in $items) {
    try {
        Remove-Item -LiteralPath $item.FullName -Force -Recurse -ErrorAction Stop
    } catch {
        Write-Status "[!] Could not remove $($item.FullName): $($_.Exception.Message)"
    }
}

Write-Status "[*] Cleared nextGPU desktop ($($items.Count) item(s)): $desktop"
exit 0
