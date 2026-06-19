#Requires -Version 5.1
<#
.SYNOPSIS
    Post-Sunshine setup: deploy repo sunshine.conf + dd_* settings, support scripts, VDD output_name via Set-SunshineVddOutput.ps1, and re-export games via PlayNiteWatcher when configured.
.DESCRIPTION
    By default exports apps already present in Playnite games.db without rescanning Steam/Epic.
    Use -RefreshPlayniteLibrary when new games were installed on disk and Playnite needs --updatelibraries.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$RefreshPlayniteLibrary
)

$ErrorActionPreference = "Stop"

function Write-SetupMessage {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    switch ($Level) {
        "WARN" { Write-Host $Message -ForegroundColor Yellow }
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message }
    }
}

function Resolve-RepoRoot {
    param([string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.TrimEnd('\')
    }

    if ($env:NEXTGPU_REPO_ROOT) {
        return $env:NEXTGPU_REPO_ROOT.TrimEnd('\')
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Invoke-ExternalPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ArgumentList = @()
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }

    $params = @{
        FilePath             = "powershell.exe"
        ArgumentList         = @(
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $ScriptPath
        ) + $ArgumentList
        Wait                 = $true
        PassThru             = $true
        NoNewWindow          = $true
    }

    $process = Start-Process @params
    if ($process.ExitCode -ne 0) {
        throw "Script failed with exit code $($process.ExitCode): $ScriptPath"
    }
}

function Invoke-ExternalPowerShellAllowFailure {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ArgumentList = @()
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw "Script not found: $ScriptPath"
    }

    $psArgs = @(
        "-NoLogo",
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ScriptPath
    ) + $ArgumentList

    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -Wait -PassThru -NoNewWindow
    return $process.ExitCode
}

$repoRoot = Resolve-RepoRoot -Override $RepoRoot
$installScriptsPs1 = Join-Path $PSScriptRoot "Install-SunshineScripts.ps1"
$setVddOutputPs1 = Join-Path $PSScriptRoot "Set-SunshineVddOutput.ps1"
$playnitePathFile = Join-Path $repoRoot "PlayNiteWatcher\PlayniteInstall.path"
$updateLibrariesPs1 = Join-Path $repoRoot "PlayNiteWatcher\Update-PlayniteLibraries.ps1"
$exportSunshinePs1 = Join-Path $repoRoot "PlayNiteWatcher\Export-SunshineFromPlaynite.ps1"

Write-SetupMessage "=== Post-Sunshine setup started ==="
Write-SetupMessage "Repo root: $repoRoot"

Invoke-ExternalPowerShell -ScriptPath $installScriptsPs1

Write-SetupMessage "[*] Resolving VDD output_name (retries + sunshine.log)..."
$vddExit = Invoke-ExternalPowerShellAllowFailure -ScriptPath $setVddOutputPs1 -ArgumentList @("-RepoRoot", $repoRoot)
if ($vddExit -eq 0) {
    Write-SetupMessage "[*] VDD output_name configured (see logs\sunshine-vdd-setup.log)"
}
else {
    Write-SetupMessage "[!] VDD output_name not resolved; Sunshine update continues. See logs\sunshine-vdd-setup.log" "WARN"
}

if (-not (Test-Path -LiteralPath $playnitePathFile)) {
    Write-SetupMessage "[!] PlayNite not configured - skipping game export. Run PlayNiteWatcher\Setup-PlayniteSteam.bat" "WARN"
    Write-SetupMessage "=== Post-Sunshine setup finished ==="
    exit 0
}

$playniteCommonPs1 = Join-Path $repoRoot "PlayNiteWatcher\Playnite-Common.ps1"
$playniteInstallDir = $null
if (Test-Path -LiteralPath $playnitePathFile) {
    $playniteInstallDir = (Get-Content -LiteralPath $playnitePathFile -Raw -ErrorAction SilentlyContinue).Trim()
}

$libraryWasRepaired = $false
if ($playniteInstallDir -and (Test-Path -LiteralPath $playniteCommonPs1)) {
    try {
        . $playniteCommonPs1
        $repairLog = { param($Message, $Level) Write-SetupMessage $Message $(if ($Level -eq 'WARN') { 'WARN' } else { 'INFO' }) }
        $repair = Repair-PlayniteLibraryDatabaseIfNeeded -InstallDir $playniteInstallDir -LogAction $repairLog
        if ($repair.Repaired) {
            $libraryWasRepaired = $repair.Success
            if (-not $repair.Success) {
                Write-SetupMessage "[!] Playnite library repair failed; Sunshine export will be skipped." "WARN"
            }
        }
    }
    catch {
        Write-SetupMessage "Playnite library repair check failed: $($_.Exception.Message)" "WARN"
    }
}

$shouldRefreshLibrary = $RefreshPlayniteLibrary -or $libraryWasRepaired
if ($shouldRefreshLibrary) {
    if (Test-Path -LiteralPath $updateLibrariesPs1) {
        if ($libraryWasRepaired -and -not $RefreshPlayniteLibrary) {
            Write-SetupMessage "[*] Refreshing Playnite libraries after library database repair..."
        }
        else {
            Write-SetupMessage "[*] Refreshing Playnite libraries before Sunshine export (-RefreshPlayniteLibrary)..."
        }
        try {
            Invoke-ExternalPowerShell -ScriptPath $updateLibrariesPs1 -ArgumentList @("-SkipMetadata")
        }
        catch {
            Write-SetupMessage "Playnite library update failed: $($_.Exception.Message)" "WARN"
        }
    }
    else {
        Write-SetupMessage "Update-PlayniteLibraries.ps1 not found; continuing with export." "WARN"
    }
}
else {
    Write-SetupMessage "[*] Exporting existing Playnite library (no disk rescan). Use -RefreshPlayniteLibrary after new game installs."
}

if (-not (Test-Path -LiteralPath $exportSunshinePs1)) {
    Write-SetupMessage "Export-SunshineFromPlaynite.ps1 not found at $exportSunshinePs1" "ERROR"
    exit 1
}

Write-SetupMessage "[*] Exporting Sunshine apps via PlayNiteWatcher..."
$exportExit = Invoke-ExternalPowerShellAllowFailure -ScriptPath $exportSunshinePs1
if ($exportExit -ne 0) {
    Write-SetupMessage "[!] Sunshine app export failed (exit $exportExit). Sunshine update completed; re-run PlayNiteWatcher\Export-SunshineFromPlaynite.ps1 or Setup-PlayniteSteam.bat -SkipInstall." "WARN"
}

Write-SetupMessage "=== Post-Sunshine setup finished ==="
