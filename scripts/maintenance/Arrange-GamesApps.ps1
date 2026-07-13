#Requires -Version 5.1
<#
.SYNOPSIS
    Arrange synced games/apps into launcher-specific layouts.
.PARAMETER Steam
    Run Steam steamapps layout arrange (skip menu).
.PARAMETER LevelUp
    Run LevelUp deploy and games.json path arrange (skip menu).
.PARAMETER Garena
    Run Garena client deploy, gxx to ProgramData, and user.dat install path arrange (skip menu).
.PARAMETER HoYoPlay
    Run HoYoPlay Cognosphere deploy to Default user Roaming (skip menu).
.PARAMETER NoGui
    Console prompts only.
#>
[CmdletBinding()]
param(
    [switch]$Steam,
    [switch]$LevelUp,
    [switch]$Garena,
    [switch]$HoYoPlay,
    [switch]$NoGui
)

$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $PSScriptRoot 'GamesApps-Manifest.ps1'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Required file missing: $manifestPath (copy from nextGPU-corescripts\scripts\maintenance\)."
}
. $manifestPath

$steamArrangePath = Join-Path $PSScriptRoot 'Invoke-ArrangeSteamLayout.ps1'
if (-not (Test-Path -LiteralPath $steamArrangePath)) {
    throw "Required file missing: $steamArrangePath (copy from nextGPU-corescripts\scripts\maintenance\)."
}
. $steamArrangePath

$levelUpArrangePath = Join-Path $PSScriptRoot 'Invoke-ArrangeLevelUpLayout.ps1'
if (-not (Test-Path -LiteralPath $levelUpArrangePath)) {
    throw "Required file missing: $levelUpArrangePath (copy from nextGPU-corescripts\scripts\maintenance\)."
}
. $levelUpArrangePath

$garenaArrangePath = Join-Path $PSScriptRoot 'Invoke-ArrangeGarenaLayout.ps1'
if (-not (Test-Path -LiteralPath $garenaArrangePath)) {
    throw "Required file missing: $garenaArrangePath (copy from nextGPU-corescripts\scripts\maintenance\)."
}
. $garenaArrangePath

$hoyoPlayArrangePath = Join-Path $PSScriptRoot 'Invoke-ArrangeHoYoPlayLayout.ps1'
if (-not (Test-Path -LiteralPath $hoyoPlayArrangePath)) {
    throw "Required file missing: $hoyoPlayArrangePath (copy from nextGPU-corescripts\scripts\maintenance\)."
}
. $hoyoPlayArrangePath

function Write-Step([string]$Message) { Write-Host ''; Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }

function Show-ArrangePlatformMenu {
    param([bool]$UseGui)
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'Arrange Games/Apps'
        $form.Width = 360
        $form.Height = 300
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

        $script:ArrangePlatformChoice = $null

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = 'Choose platform:'
        $lbl.Left = 16
        $lbl.Top = 16
        $lbl.Width = 320
        $form.Controls.Add($lbl)

        $btnSteam = New-Object System.Windows.Forms.Button
        $btnSteam.Text = 'Steam'
        $btnSteam.Left = 16
        $btnSteam.Top = 48
        $btnSteam.Width = 310
        $btnSteam.Height = 32
        $btnSteam.Add_Click({ $script:ArrangePlatformChoice = 'Steam'; $form.Close() })
        $form.Controls.Add($btnSteam)

        $btnLevel = New-Object System.Windows.Forms.Button
        $btnLevel.Text = 'LevelUp'
        $btnLevel.Left = 16
        $btnLevel.Top = 88
        $btnLevel.Width = 310
        $btnLevel.Height = 32
        $btnLevel.Add_Click({ $script:ArrangePlatformChoice = 'LevelUp'; $form.Close() })
        $form.Controls.Add($btnLevel)

        $btnGarena = New-Object System.Windows.Forms.Button
        $btnGarena.Text = 'Garena'
        $btnGarena.Left = 16
        $btnGarena.Top = 128
        $btnGarena.Width = 310
        $btnGarena.Height = 32
        $btnGarena.Add_Click({ $script:ArrangePlatformChoice = 'Garena'; $form.Close() })
        $form.Controls.Add($btnGarena)

        $btnHoYoPlay = New-Object System.Windows.Forms.Button
        $btnHoYoPlay.Text = 'HoYoPlay'
        $btnHoYoPlay.Left = 16
        $btnHoYoPlay.Top = 168
        $btnHoYoPlay.Width = 310
        $btnHoYoPlay.Height = 32
        $btnHoYoPlay.Add_Click({ $script:ArrangePlatformChoice = 'HoYoPlay'; $form.Close() })
        $form.Controls.Add($btnHoYoPlay)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = 'Cancel'
        $btnCancel.Left = 16
        $btnCancel.Top = 248
        $btnCancel.Width = 310
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)

        $form.CancelButton = $btnCancel
        $null = $form.ShowDialog()
        return $script:ArrangePlatformChoice
    }

    Write-Host '  [1] Steam' -ForegroundColor Cyan
    Write-Host '  [2] LevelUp' -ForegroundColor Cyan
    Write-Host '  [3] Garena' -ForegroundColor Cyan
    Write-Host '  [4] HoYoPlay' -ForegroundColor Cyan
    $n = Read-Host 'Choice (1-4, Enter to cancel)'
    switch ($n) {
        '1' { return 'Steam' }
        '2' { return 'LevelUp' }
        '3' { return 'Garena' }
        '4' { return 'HoYoPlay' }
        default { return $null }
    }
}

Write-Host '==============================================='
Write-Host ' NextGPU Arrange Games/Apps'
Write-Host '==============================================='

$useGui = -not $NoGui.IsPresent
$platformSwitches = @($Steam.IsPresent, $LevelUp.IsPresent, $Garena.IsPresent, $HoYoPlay.IsPresent) | Where-Object { $_ }
if ($platformSwitches.Count -gt 1) {
    throw 'Use only one of -Steam, -LevelUp, -Garena, or -HoYoPlay.'
}
$choice = if ($Steam.IsPresent) { 'Steam' } elseif ($LevelUp.IsPresent) { 'LevelUp' } elseif ($Garena.IsPresent) { 'Garena' } elseif ($HoYoPlay.IsPresent) { 'HoYoPlay' } else { Show-ArrangePlatformMenu -UseGui:$useGui }

if (-not $choice) {
    Write-Warn 'Cancelled.'
    exit 0
}

if ($choice -eq 'Steam') {
    Write-Step 'Arranging Steam layout...'
    $code = Invoke-ArrangeSteamLayout -NoGui:$NoGui.IsPresent
    exit $code
}

if ($choice -eq 'LevelUp') {
    Write-Step 'Arranging LevelUp layout...'
    $code = Invoke-ArrangeLevelUpLayout -NoGui:$NoGui.IsPresent
    exit $code
}

if ($choice -eq 'Garena') {
    Write-Step 'Arranging Garena layout...'
    $code = Invoke-ArrangeGarenaLayout -NoGui:$NoGui.IsPresent
    exit $code
}

if ($choice -eq 'HoYoPlay') {
    Write-Step 'Arranging HoYoPlay layout...'
    $code = Invoke-ArrangeHoYoPlayLayout -NoGui:$NoGui.IsPresent
    exit $code
}

Write-Warn "Unknown choice: $choice"
exit 1
