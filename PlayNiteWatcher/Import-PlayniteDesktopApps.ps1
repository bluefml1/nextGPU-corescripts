#Requires -Version 5.1
<#
.SYNOPSIS
    Import allowlisted desktop apps into Playnite (headless via Everything, or manual Playnite scan).
.DESCRIPTION
    -Headless: uses es.exe + Sync-PlayniteDesktopAppsToAllowlist (same as Setup step 7).
    Default: pick folders and use Playnite UI "Scan automatically", then sync library.
.EXAMPLE
    .\Import-PlayniteDesktopApps.ps1 -Headless -DesktopImportScanMode AllDrives
    .\Import-PlayniteDesktopApps.ps1 -ScanPath "Z:\Adobe" -NoLoop
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = "",
    [string]$AllowlistPath = "",
    [string]$ScanPath = "",
    [switch]$PickScanFolder,
    [switch]$NoLoop,
    [switch]$WhatIf,
    [switch]$Prune,
    [switch]$LaunchPlaynite,
    [switch]$NoPrompt,
    [switch]$Headless,
    [switch]$SkipEverythingInstall,
    [ValidateSet('Prompt', 'PickPath', 'PickFolder', 'AllDrives', 'Default')]
    [string]$DesktopImportScanMode = "Prompt"
)

$ErrorActionPreference = "Stop"
$script:ModuleRoot = $PSScriptRoot
$bootstrapCommon = Join-Path $script:ModuleRoot "Playnite-Common.ps1"
if (-not (Test-Path -LiteralPath $bootstrapCommon)) {
    $parentCommon = Join-Path (Split-Path -Path $script:ModuleRoot -Parent) "Playnite-Common.ps1"
    if (Test-Path -LiteralPath $parentCommon) {
        $bootstrapCommon = $parentCommon
    }
}
. $bootstrapCommon
$script:ModuleRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $script:ModuleRoot

$script:LogFile = Join-Path $script:ModuleRoot "Import-PlayniteDesktopApps.log"

function Write-ImportLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
}

function Show-PlayniteScanInstructions {
    param(
        [string]$ScanRoot,
        [object[]]$Allowlist
    )

    Write-Host ""
    Write-Host "=== Playnite scan (manual step) ===" -ForegroundColor Cyan
    Write-Host "Folder to scan: $ScanRoot"
    Write-Host ""
    Write-Host "In Playnite:" -ForegroundColor Yellow
    Write-Host "  Add game -> Scan automatically"
    Write-Host "  Select the folder above"
    Write-Host "  Check ONLY games whose executable name is in this list:"
    Write-Host ""
    foreach ($entry in $Allowlist) {
        Write-Host "    - $($entry.Exe)  ($($entry.Title))"
    }
    Write-Host ""
}

function Invoke-PlayniteDesktopAppImport {
    if (Test-Path -LiteralPath $script:LogFile) {
        Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
    }

    Write-ImportLog "=== Import-PlayniteDesktopApps started ==="

    $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $script:ModuleRoot -OverrideDir $PlayniteInstallDir
    $installDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
    if (-not $installDir) {
        throw "Playnite install folder is not set. Run Setup-PlayniteSteam.bat or pass -PlayniteInstallDir."
    }

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $installDir
    $logAction = { param($Message, $Level) Write-ImportLog $Message $Level }

    if ($Headless) {
        Write-ImportLog "Headless import (Everything es.exe or directory walk)."
        $scanRoots = Resolve-DesktopAppImportScanRoots `
            -Mode $DesktopImportScanMode `
            -ScanPath $ScanPath `
            -PickerInitialDirectory (Split-Path -Path $installDir -Parent) `
            -RepoRoot $script:ModuleRoot `
            -LogAction $logAction

        if (-not $scanRoots -or $scanRoots.Count -eq 0) {
            Write-ImportLog "No scan roots; import skipped." "WARN"
            return
        }

        $result = Invoke-HeadlessDesktopAppImport `
            -InstallDir $installDir `
            -RepoRoot $script:ModuleRoot `
            -AllowlistPath $AllowlistPath `
            -ScanRoots $scanRoots `
            -SkipEverythingInstall:$SkipEverythingInstall `
            -LogAction $logAction

        Write-ImportLog ("Headless import: roots={0} added={1} updated={2}" -f `
                $result.RootsScanned, $result.Added, $result.Updated)

        if ($LaunchPlaynite) {
            Stop-PlayniteApplication -PlayniteExe $playniteExe
            Start-PlayniteProcess -PlayniteExe $playniteExe -ArgumentList @('--startdesktop') | Out-Null
            Write-ImportLog "Launched Playnite."
        }

        Write-ImportLog "=== Import finished ==="
        return
    }

    $allowlist = Get-DesktopAppAllowlist -RepoRoot $script:ModuleRoot -AllowlistPath $AllowlistPath
    Write-ImportLog "Allowlist: $($allowlist.Count) app(s) (manual Playnite scan mode)"

    if ($LaunchPlaynite) {
        Stop-PlayniteApplication -PlayniteExe $playniteExe
        Start-PlayniteProcess -PlayniteExe $playniteExe -ArgumentList @('--startdesktop') | Out-Null
        Write-ImportLog "Launched Playnite for scan."
    }

    $iteration = 0

    do {
        $iteration++
        $scanRoot = $ScanPath

        if ([string]::IsNullOrWhiteSpace($scanRoot) -or $PickScanFolder -or ($iteration -gt 1)) {
            $initial = if ($scanRoot) { $scanRoot } else { "${env:ProgramFiles}\Adobe" }
            $scanRoot = Show-PlayniteFolderPicker -Description "Select folder to scan in Playnite (desktop apps)" -InitialDirectory $initial
        }

        if ([string]::IsNullOrWhiteSpace($scanRoot)) {
            Write-ImportLog "No folder selected; stopping." "WARN"
            break
        }

        Write-ImportLog "--- Folder iteration ${iteration}: $scanRoot ---"
        Show-PlayniteScanInstructions -ScanRoot $scanRoot -Allowlist $allowlist

        if (-not $NoPrompt -and -not $WhatIf) {
            Read-Host "After Playnite scan/import, press Enter to sync the library"
        }

        $stats = Sync-PlayniteDesktopAppsToAllowlist `
            -InstallDir $installDir `
            -ScanRoot $scanRoot `
            -Allowlist $allowlist `
            -WhatIf:$WhatIf `
            -Prune:$Prune `
            -LogAction $logAction

        Write-ImportLog ("Sync: added={0} updated={1} pruned={2} missing={3}" -f `
                $stats.Added, $stats.Updated, $stats.Pruned, $stats.Missing.Count)
        if ($stats.Missing.Count -gt 0) {
            Write-ImportLog ("Missing under folder: " + ($stats.Missing -join ', ')) "WARN"
        }

        $ScanPath = ""

        if ($NoLoop) { break }

        if ($NoPrompt) { break }

        $again = Read-Host "Scan another folder? (Y/n)"
        if ($again -match '^[Nn]') { break }
    } while ($true)

    Stop-PlayniteApplication -PlayniteExe $playniteExe
    Write-ImportLog "=== Import finished ==="
    Write-ImportLog "Next: .\Export-SunshineFromPlaynite.ps1 (exports and installs PlayNiteWatcher)"
}

if ($PSCommandPath -eq $MyInvocation.PSCommandPath) {
    try {
        Invoke-PlayniteDesktopAppImport
    }
    catch {
        Write-ImportLog $_.Exception.Message "ERROR"
        if ($_.ScriptStackTrace) {
            Write-ImportLog $_.ScriptStackTrace "ERROR"
        }
        $installDir = $null
        try {
            $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $script:ModuleRoot -OverrideDir $PlayniteInstallDir
            $installDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
        }
        catch { }
        if ($installDir) {
            Stop-PlayniteApplication -PlayniteExe (Get-PlayniteDesktopExe -InstallDir $installDir)
        }
        exit 1
    }
}
