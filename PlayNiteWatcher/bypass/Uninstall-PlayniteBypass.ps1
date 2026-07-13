#Requires -Version 5.1
<#
.SYNOPSIS
    Uninstall RunAsTool and Game Shortcuts bypass config. Playnite library is kept by default.
.DESCRIPTION
    Default: removes RunAsTool, Game Shortcuts folders, bypass bindings, and reverts bypass
    play paths in games.db. Does NOT delete the portable Playnite install folder.
    Use -RemovePlayniteInstall only when you intend to remove Playnite entirely.
.EXAMPLE
    .\Uninstall-PlayniteBypass.ps1
    .\Uninstall-PlayniteBypass.ps1 -Force
    .\Uninstall-PlayniteBypass.ps1 -Force -RemovePlayniteInstall
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = "",
    [switch]$Force,
    [switch]$RemovePlayniteInstall,
    [switch]$SkipPlaynite,
    [switch]$SkipRunAsTool,
    [switch]$SkipFolders,
    [switch]$SkipAllowlist
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot
$bootstrapCommon = Join-Path $scriptRoot "..\Playnite-Common.ps1"
if (-not (Test-Path -LiteralPath $bootstrapCommon)) {
    $checkPath = Split-Path -Path $scriptRoot -Parent
    while ($checkPath) {
        $candidate = Join-Path $checkPath "Playnite-Common.ps1"
        if (Test-Path -LiteralPath $candidate) { $bootstrapCommon = $candidate; break }
        $checkPath = Split-Path -Path $checkPath -Parent
    }
}
. $bootstrapCommon

$script:LogFile = Join-Path $scriptRoot "Uninstall-PlayniteBypass.log"

function Write-UninstallLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding utf8
}

try {
    Write-UninstallLog "=== Uninstall-PlayniteBypass started ==="
    $removePlayniteInstall = $RemovePlayniteInstall.IsPresent

    if (-not $Force.IsPresent) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        $lines = @(
            "This will remove:",
            "  - RunAsTool install (ProgramData\NextGPU\RunAsTool)",
            "  - Game Shortcuts / legacy Bypasses folders and .lnk files",
            "  - bypass-shortcuts.json bindings and Playnite bypass-bindings.json",
            "  - Allowlist entries tied to bypass bindings",
            "  - Playnite bypass play paths (revert store games; remove manual bypass rows)"
            "",
            "Playnite portable install folder and games.db are KEPT unless you choose full removal."
        )
        if ($removePlayniteInstall) {
            $lines += @(
                "",
                "Also removing:",
                "  - PlayNiteWatcher Sunshine hooks",
                "  - Entire portable Playnite install folder + PlayniteInstall.path"
            )
        }
        $lines += "", "Continue?"
        $choice = [System.Windows.Forms.MessageBox]::Show(
            ($lines -join [Environment]::NewLine),
            "Uninstall Game Shortcuts + RunAsTool",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-UninstallLog "Uninstall cancelled by user."
            exit 0
        }
    }

    $installDir = ""
    if (-not $SkipPlaynite.IsPresent) {
        $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $scriptRoot -OverrideDir $PlayniteInstallDir
        $installDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
        if (-not $installDir) {
            Write-UninstallLog "Playnite install not configured; skipping Playnite library cleanup." "WARN"
            $SkipPlaynite = $true
            if ($removePlayniteInstall) {
                Write-UninstallLog "Portable Playnite folder not found; skipping Playnite folder removal." "WARN"
                $removePlayniteInstall = $false
            }
        }
        else {
            Write-UninstallLog "Playnite install: $installDir"
        }
    }

    Stop-RunAsToolApplicationProcesses
    if ($installDir) {
        $playniteExe = Join-Path $installDir 'Playnite.DesktopApp.exe'
        if (Test-Path -LiteralPath $playniteExe) {
            Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $installDir -WaitSeconds 45 -Force
        }
        Stop-Process -Name 'Playnite.DesktopApp', 'Playnite.FullscreenApp' -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }

    $logAction = { param($Message, $Level = "INFO") Write-UninstallLog $Message $Level }
    $stats = Uninstall-PlayniteBypassEnvironment `
        -RepoRoot $scriptRoot `
        -InstallDir $installDir `
        -SkipPlaynite:$SkipPlaynite `
        -SkipRunAsTool:$SkipRunAsTool `
        -SkipFolders:$SkipFolders `
        -SkipAllowlist:$SkipAllowlist `
        -RemovePlayniteInstall:$removePlayniteInstall `
        -LogAction $logAction `
        -LogFile $script:LogFile `
        -CallerProcessId $PID

    Write-UninstallLog ("Done. folders={0} storeReverted={1} manualRemoved={2} allowlistRemoved={3} missing={4} playniteRemoved={5} playniteRemovalDeferred={6}" -f `
            $stats.FoldersRemoved, $stats.StoreReverted, $stats.ManualRemoved, $stats.AllowlistRemoved, $stats.Missing, $stats.PlayniteRemoved, $stats.PlayniteRemovalDeferred)
    if (-not $removePlayniteInstall) {
        Write-UninstallLog "Playnite install kept. Run Update-PlayniteLibraries.ps1 and Import-PlayniteDesktopApps.ps1 to restore library entries if needed."
    }
    Write-UninstallLog "=== Uninstall-PlayniteBypass finished ==="
}
catch {
    Write-UninstallLog $_.Exception.Message "ERROR"
    exit 1
}
