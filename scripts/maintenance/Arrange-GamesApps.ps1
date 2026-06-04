#Requires -Version 5.1
<#
.SYNOPSIS
    Arrange synced games/apps into launcher-specific layouts.
.PARAMETER Steam
    Run Steam steamapps layout arrange (skip menu).
.PARAMETER NoGui
    Console prompts only.
#>
[CmdletBinding()]
param(
    [switch]$Steam,
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
        $form.Height = 220
        $form.StartPosition = 'CenterScreen'
        $form.FormBorderStyle = 'FixedDialog'
        $form.MaximizeBox = $false
        $form.MinimizeBox = $false

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
        $btnSteam.DialogResult = [System.Windows.Forms.DialogResult]::Yes
        $form.Controls.Add($btnSteam)

        $btnLevel = New-Object System.Windows.Forms.Button
        $btnLevel.Text = 'LevelUp (coming soon)'
        $btnLevel.Left = 16
        $btnLevel.Top = 88
        $btnLevel.Width = 310
        $btnLevel.Height = 32
        $btnLevel.Enabled = $false
        $form.Controls.Add($btnLevel)

        $btnHoyo = New-Object System.Windows.Forms.Button
        $btnHoyo.Text = 'HoyoPlay (coming soon)'
        $btnHoyo.Left = 16
        $btnHoyo.Top = 128
        $btnHoyo.Width = 310
        $btnHoyo.Height = 32
        $btnHoyo.Enabled = $false
        $form.Controls.Add($btnHoyo)

        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = 'Cancel'
        $btnCancel.Left = 16
        $btnCancel.Top = 168
        $btnCancel.Width = 310
        $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $form.Controls.Add($btnCancel)

        $form.AcceptButton = $btnSteam
        $form.CancelButton = $btnCancel
        $dr = $form.ShowDialog()
        if ($dr -eq [System.Windows.Forms.DialogResult]::Yes) { return 'Steam' }
        return $null
    }

    Write-Host '  [1] Steam' -ForegroundColor Cyan
    Write-Host '  [2] LevelUp (coming soon)' -ForegroundColor DarkGray
    Write-Host '  [3] HoyoPlay (coming soon)' -ForegroundColor DarkGray
    $n = Read-Host 'Choice (1-3, Enter to cancel)'
    switch ($n) {
        '1' { return 'Steam' }
        '2' { Write-Warn 'LevelUp — coming soon.'; return 'ComingSoon' }
        '3' { Write-Warn 'HoyoPlay — coming soon.'; return 'ComingSoon' }
        default { return $null }
    }
}

Write-Host '==============================================='
Write-Host ' NextGPU Arrange Games/Apps'
Write-Host '==============================================='

$useGui = -not $NoGui.IsPresent
$choice = if ($Steam.IsPresent) { 'Steam' } else { Show-ArrangePlatformMenu -UseGui:$useGui }

if (-not $choice) {
    Write-Warn 'Cancelled.'
    exit 0
}
if ($choice -eq 'ComingSoon') {
    exit 0
}

if ($choice -eq 'Steam') {
    Write-Step 'Arranging Steam layout...'
    $code = Invoke-ArrangeSteamLayout -NoGui:$NoGui.IsPresent
    exit $code
}

Write-Warn "Unknown choice: $choice"
exit 1
