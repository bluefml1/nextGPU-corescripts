#Requires -Version 5.1
<#
.SYNOPSIS
    Headless export of Playnite Steam/Epic library to Sunshine apps.json (no Playnite UI).
    By default also installs PlayNiteWatcher after export. Use -SkipWatcherInstall to export only.
.EXAMPLE
    .\Export-SunshineFromPlaynite.ps1
    .\Export-SunshineFromPlaynite.ps1 -PlayniteInstallDir "D:\Games\Playnite"
    .\Export-SunshineFromPlaynite.ps1 -SunshineConfigDir "C:\Program Files\Sunshine\config"
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = "",
    [string]$SunshineConfigDir = "",
    [string]$SunshineAppsPath = "",
    [string]$AllowlistPath = "",
    [switch]$SkipDesktopApps,
    [switch]$SkipWatcherInstall
)

$ErrorActionPreference = "Stop"
$script:ExportModuleRoot = $PSScriptRoot
. (Join-Path $script:ExportModuleRoot "Playnite-Common.ps1")
. (Join-Path $script:ExportModuleRoot "SunshineExport-Core.ps1")

$script:ExportLogFile = Join-Path $script:ExportModuleRoot "Export-SunshineFromPlaynite.log"

function Write-ExportLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:ExportLogFile -Value $line -Encoding utf8
}

function Invoke-SunshineExportFromPlaynite {
    [CmdletBinding()]
    param(
        [string]$PlayniteInstallDir = "",
        [string]$SunshineConfigDir = "",
        [string]$SunshineAppsPath = "",
        [string]$AllowlistPath = "",
        [switch]$SkipDesktopApps,
        [switch]$SkipWatcherInstall
    )

    if (Test-Path -LiteralPath $script:ExportLogFile) {
        Remove-Item -LiteralPath $script:ExportLogFile -Force -ErrorAction SilentlyContinue
    }

    Write-ExportLog "=== Export-SunshineFromPlaynite started ==="

    $logAction = { param($Message, $Level) Write-ExportLog $Message $Level }

    $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $script:ExportModuleRoot -OverrideDir $PlayniteInstallDir
    $installDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
    if (-not $installDir) {
        throw "Playnite install folder is not set. Run Setup-PlayniteSteam.bat or pass -PlayniteInstallDir."
    }

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $installDir
    $games = New-Object System.Collections.Generic.List[object]
    $steamEpic = Get-ExportablePlayniteGames -InstallDir $installDir -LogAction $logAction
    foreach ($g in $steamEpic) { [void]$games.Add($g) }
    Write-ExportLog "Found $($steamEpic.Count) Steam/Epic game(s) in library/games.db (LiteDB)"

    if (-not $SkipDesktopApps) {
        $allowFile = Resolve-DesktopAppAllowlistPath -RepoRoot $script:ExportModuleRoot -OverridePath $AllowlistPath
        if (Test-Path -LiteralPath $allowFile) {
            try {
                $desktop = Get-ExportableDesktopPlayniteGames -InstallDir $installDir -RepoRoot $script:ExportModuleRoot -AllowlistPath $AllowlistPath -LogAction $logAction
                foreach ($g in $desktop) { [void]$games.Add($g) }
                Write-ExportLog "Found $($desktop.Count) desktop app(s) from allowlist: $allowFile"
            }
            catch {
                Write-ExportLog "Desktop allowlist export skipped: $($_.Exception.Message)" "WARN"
            }
        }
        else {
            Write-ExportLog "No desktop allowlist at $allowFile (copy desktop-apps.allowlist.json.template)" "WARN"
        }
    }

    if ($games.Count -eq 0) {
        Write-ExportLog "No games to export. Run Update-PlayniteLibraries.ps1 and/or Import-PlayniteDesktopApps.ps1." "WARN"
    }

    if ([string]::IsNullOrWhiteSpace($SunshineAppsPath)) {
        $configDir = if ([string]::IsNullOrWhiteSpace($SunshineConfigDir)) {
            Get-DefaultSunshineConfigPath
        }
        else {
            $SunshineConfigDir.TrimEnd('\')
        }
        $SunshineAppsPath = Join-Path $configDir "apps.json"
    }

    Write-ExportLog "Sunshine apps.json: $SunshineAppsPath"

    $exportResult = Export-PlayniteLibraryToSunshine -PlayniteExe $playniteExe -AppsPath $SunshineAppsPath -Games @($games.ToArray())
    Publish-SunshineExportArtifacts -ExportResult $exportResult | Out-Null

    $desktopCount = 0
    if ($exportResult.Counts.Desktop -ne $null) { $desktopCount = $exportResult.Counts.Desktop }
    Write-ExportLog ("Exported Steam: {0}, Epic: {1}, Desktop: {2}, processed: {3}" -f `
            $exportResult.Counts.Steam, $exportResult.Counts.Epic, $desktopCount, $exportResult.Counts.Total)
    Write-ExportLog "Wrote: $($exportResult.AppsPath)"
    Write-ExportLog "Wrote: $($exportResult.ResolvedJsonPath)"
    Write-ExportLog "Wrote: $($exportResult.ResolvedTxtPath)"
    Write-ExportLog "=== Export finished ==="

    if (-not $SkipWatcherInstall) {
        Write-ExportLog "=== Installing PlayNiteWatcher (post-export) ==="
        $installScript = Join-Path $script:ExportModuleRoot "Install-PlayniteWatcher.ps1"
        if (-not (Test-Path -LiteralPath $installScript)) {
            Write-ExportLog "Install script not found: $installScript" "WARN"
            return
        }
        if (-not (Get-Command Invoke-PlayniteWatcherInstall -ErrorAction SilentlyContinue)) {
            . $installScript
        }
        $installParams = @{ SkipExport = $true }
        if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDir)) {
            $installParams.PlayniteInstallDir = $PlayniteInstallDir
        }
        if (-not [string]::IsNullOrWhiteSpace($SunshineConfigDir)) {
            $installParams.SunshineConfigDir = $SunshineConfigDir
        }
        if (-not [string]::IsNullOrWhiteSpace($AllowlistPath)) {
            $installParams.AllowlistPath = $AllowlistPath
        }
        Invoke-PlayniteWatcherInstall @installParams
        Write-ExportLog "=== PlayNiteWatcher install finished ==="
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-SunshineExportFromPlaynite @PSBoundParameters
    }
    catch {
        Write-ExportLog $_.Exception.Message "ERROR"
        exit 1
    }
}
