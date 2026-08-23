#Requires -Version 5.1
<#
.SYNOPSIS
    Runs Playnite --updatelibraries --updatemetadata and waits for Steam/Epic disk import in playnite.log.
    No Steam or Epic login required when extension settings use Import installed games only.
    Install path comes from PlayniteInstall.path (folder picker during setup). -PlayniteInstallDir is optional for automation.
.EXAMPLE
    .\Update-PlayniteLibraries.ps1
    .\Update-PlayniteLibraries.ps1 -MaxWaitMinutes 30
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = "",
    [int]$MaxWaitMinutes = 20,
    [switch]$SkipMetadata
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Playnite-Common.ps1")

$script:LogFile = Join-Path $PSScriptRoot "Update-PlayniteLibraries.log"
$script:PlayniteAppData = $null

function Write-MigrationLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
}

function Get-ResolvedPlayniteInstallDir {
    $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $PSScriptRoot -OverrideDir $PlayniteInstallDir
    return Resolve-PlayniteInstallDir -PreferredDir $preferred
}

$script:UpdatePlayniteExe = $null

try {
    Write-MigrationLog "=== Update-PlayniteLibraries started ==="
    $installDir = Get-ResolvedPlayniteInstallDir
    if (-not $installDir) {
        throw "Playnite install folder is not set. Run Setup-PlayniteSteam.bat and choose a folder, or pass -PlayniteInstallDir."
    }
    $script:PlayniteAppData = Get-PlayniteDataDirectory -InstallDir $installDir
    Write-MigrationLog "Windows user: $env:USERNAME | Portable data: $script:PlayniteAppData"

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $installDir
    $script:UpdatePlayniteExe = $playniteExe
    $extLogAction = { param($Message, $Level) Write-MigrationLog $Message $Level }
    Install-PlayniteBuiltinLibraryExtensions -InstallDir $installDir -RepoRoot $PSScriptRoot -LogAction $extLogAction

    Stop-PlayniteApplication -PlayniteExe $playniteExe

    $playniteLog = Join-Path $script:PlayniteAppData "playnite.log"
    $startedAfter = Get-Date

    $args = @("--startdesktop", "--hidesplashscreen", "--updatelibraries")
    if (-not $SkipMetadata) {
        $args += "--updatemetadata"
        Write-MigrationLog "Metadata pass enabled (--updatemetadata). Large libraries can take many minutes."
    }
    Write-MigrationLog "Launch: $playniteExe $($args -join ' ')"
    Start-PlayniteProcess -PlayniteExe $playniteExe -ArgumentList $args | Out-Null

    $logAction = { param($Message, $Level) Write-MigrationLog $Message $Level }
    $ok = Wait-PlayniteLibraryImportInLog -LogPath $playniteLog -StartedAfter $startedAfter `
        -TimeoutMinutes $MaxWaitMinutes -LogAction $logAction -WaitForMetadata:(-not $SkipMetadata)
    if (-not $ok) {
        Write-MigrationLog "Playnite may still be open - check for first-run wizard dialogs." "WARN"
    }

    Stop-PlayniteApplication -PlayniteExe $playniteExe

    if ($ok) {
        Write-MigrationLog "Done. Library update finished. Applying elevated Play actions (Steam + Desktop Admin)..." "INFO"
    }
    else {
        Write-MigrationLog "No Steam/Epic import in log. Ensure Steam/Epic clients are installed and games are on disk, then Update All in Playnite or re-run this script." "WARN"
        Write-MigrationLog "Still applying elevated Play actions for any Steam games already in games.db..." "INFO"
    }

    $applyScript = Join-Path $PSScriptRoot 'Apply-PlayniteElevatedPlayActions.ps1'
    if (Test-Path -LiteralPath $applyScript) {
        & $applyScript -PlayniteInstallDir $installDir
        Write-MigrationLog "Elevated Play actions applied. Re-run Setup-PlayniteSteam.ps1 -WithSunshine or Export if you use Sunshine/Moonlight." "INFO"
    }
    else {
        Write-MigrationLog "Apply-PlayniteElevatedPlayActions.ps1 not found: $applyScript" "WARN"
    }
}
catch {
    Write-MigrationLog $_.Exception.Message "ERROR"
    exit 1
}
finally {
    if ($script:UpdatePlayniteExe) {
        Stop-PlayniteApplication -PlayniteExe $script:UpdatePlayniteExe
    }
}
