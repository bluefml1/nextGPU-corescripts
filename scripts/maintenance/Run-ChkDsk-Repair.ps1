#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Disk management helper: run chkdsk /f on one drive or all fixed drives, then ask for reboot.
#>
[CmdletBinding()]
param(
    [string]$DriveLetter = '',
    [switch]$AllFixed
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

function Get-FixedDriveLetters {
    $letters = @()
    $items = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Sort-Object DeviceID
    foreach ($it in $items) {
        if ($it.DeviceID -match '^([A-Z]):$') { $letters += $matches[1] }
    }
    return @($letters | Select-Object -Unique)
}

function Prompt-Mode([string[]]$letters) {
    $text = @(
        "Choose CHKDSK mode:",
        "",
        "YES = check ALL fixed drives",
        "NO = choose ONE drive"
    ) -join [Environment]::NewLine
    $r = [System.Windows.Forms.MessageBox]::Show($text, 'NextGPU Disk Management', [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return $null }
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { return @{ All = $true; Drive = $null } }

    $pick = [Microsoft.VisualBasic.Interaction]::InputBox("Enter drive letter to check:`nAvailable: $($letters -join ', ')", 'NextGPU Disk Management', $letters[0])
    if ([string]::IsNullOrWhiteSpace($pick)) { return $null }
    $d = $pick.Trim().TrimEnd(':').ToUpperInvariant()
    return @{ All = $false; Drive = $d }
}

function Invoke-ChkDsk([string]$drive) {
    Write-Host ""
    Write-Host "[*] Running chkdsk $drive`: /f" -ForegroundColor Cyan
    $cmd = "echo Y|chkdsk $drive`: /f"
    cmd.exe /c $cmd
    return $LASTEXITCODE
}

Write-Host "=== NextGPU Disk Check / Repair ===" -ForegroundColor Cyan
$letters = Get-FixedDriveLetters
if (-not $letters -or $letters.Count -eq 0) {
    throw 'No fixed drives found.'
}

$runAll = $AllFixed.IsPresent
$selected = $null
if (-not $runAll -and [string]::IsNullOrWhiteSpace($DriveLetter)) {
    $mode = Prompt-Mode -letters $letters
    if ($null -eq $mode) { Write-Host '[*] Cancelled.'; exit 0 }
    $runAll = [bool]$mode.All
    $selected = $mode.Drive
}

if (-not $runAll) {
    if (-not $selected) {
        $selected = $DriveLetter.Trim().TrimEnd(':').ToUpperInvariant()
    }
    if ($letters -notcontains $selected) {
        throw "Drive $selected`: not found among fixed drives: $($letters -join ', ')"
    }
}

$targets = if ($runAll) { $letters } else { @($selected) }
Write-Host "[*] Target(s): $($targets -join ', ')" -ForegroundColor Yellow

$failed = @()
foreach ($d in $targets) {
    $code = Invoke-ChkDsk -drive $d
    if ($code -ne 0) { $failed += $d }
}

if ($failed.Count -gt 0) {
    Write-Host "[!] Some CHKDSK commands returned non-zero: $($failed -join ', ')" -ForegroundColor Yellow
}

$restartMsg = "CHKDSK scheduling complete.`n`nRestart now to run repairs before boot?"
$restart = [System.Windows.Forms.MessageBox]::Show($restartMsg, 'NextGPU Disk Management', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
if ($restart -eq [System.Windows.Forms.DialogResult]::Yes) {
    Write-Host "[*] Restarting in 8 seconds..." -ForegroundColor Cyan
    shutdown.exe /r /t 8 /c "NextGPU disk repair reboot"
}

exit 0
