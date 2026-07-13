#Requires -Version 5.1
<#
.SYNOPSIS
    Playnite bypass shortcuts: RunAsTool + allowlist + games.db sync.
.EXAMPLE
    .\Sync-PlayniteBypassShortcuts.ps1 -RunAsToolOnly
    .\Sync-PlayniteBypassShortcuts.ps1 -Interactive
    .\Sync-PlayniteBypassShortcuts.ps1 -PickParentFolder
    .\Sync-PlayniteBypassShortcuts.ps1 -SyncOnly
    .\Sync-PlayniteBypassShortcuts.ps1 -ExportSunshine
#>
[CmdletBinding(DefaultParameterSetName = "Interactive")]
param(
    [string]$PlayniteInstallDir = "",
    [string]$ParentPath = "",
    [string]$RepoRoot = "",
    [switch]$PickParentFolder,
    [Parameter(ParameterSetName = "RunAsToolOnly")]
    [switch]$RunAsToolOnly,
    [Parameter(ParameterSetName = "Interactive")]
    [switch]$Interactive,
    [Parameter(ParameterSetName = "SyncOnly")]
    [switch]$SyncOnly,
    [switch]$NoPrompt,
    [switch]$WhatIf,
    [switch]$ExportSunshine
)

$ErrorActionPreference = "Stop"
$script:WatcherRoot = $PSScriptRoot
. (Join-Path $script:WatcherRoot "Playnite-Common.ps1")
. (Join-Path $script:WatcherRoot "BypassShortcutUI.ps1")
$script:ModuleRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    Resolve-PlayNiteWatcherRepoRoot -Candidate $script:WatcherRoot
} else {
    $RepoRoot.TrimEnd('\')
}
$PlayniteBypassSyncLogPath = Join-Path $script:WatcherRoot "Sync-PlayniteBypassShortcuts.log"
$script:LogFile = $PlayniteBypassSyncLogPath

function Write-BypassSyncLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    if ([string]::IsNullOrWhiteSpace($PlayniteBypassSyncLogPath)) {
        return
    }
    Add-Content -LiteralPath $PlayniteBypassSyncLogPath -Value $line -Encoding utf8
}

function Initialize-BypassSetupPaths {
    param(
        [string]$Parent,
        [switch]$PickFolder
    )

    $parentPath = $Parent
    if ($PickFolder -or [string]::IsNullOrWhiteSpace($parentPath)) {
        $picked = Show-PlayniteFolderBrowserDialog -Description "Select parent folder for Game Shortcuts subfolder"
        if (-not $picked) {
            throw "Folder selection cancelled."
        }
        $parentPath = $picked
    }

    $folder = Initialize-BypassShortcutsFolder -ParentPath $parentPath -NoPrompt:$NoPrompt
    if (-not $folder) {
        throw "Game Shortcuts folder setup cancelled."
    }

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $script:ModuleRoot
    $config = $wrapper.Config
    $config.parentPath = $folder.ParentPath
    $config.bypassesPath = $folder.BypassesPath
    if ([string]::IsNullOrWhiteSpace($config.adminUser)) {
        $config.adminUser = $script:DefaultBypassAdminUser
    }

    $configRef = [ref]$config
    $runAs = Ensure-RunAsToolExeResolved `
        -RepoRoot $script:ModuleRoot `
        -ConfigRef $configRef `
        -LogAction { param($m, $l = 'INFO') Write-BypassSyncLog $m $l }
    $config = $configRef.Value
    Save-BypassShortcutsConfig -RepoRoot $script:ModuleRoot -Config $config

    Write-BypassSyncLog "Game Shortcuts folder: $($folder.BypassesPath)"
    Write-BypassSyncLog "RunAsTool ready: $runAs"
    return $config
}

function Invoke-RunAsToolOnlyStep {
    param(
        [object]$Config,
        [switch]$PickFolder
    )

    if ([string]::IsNullOrWhiteSpace($Config.bypassesPath)) {
        $Config = Initialize-BypassSetupPaths -Parent $ParentPath -PickFolder:$PickFolder
    }

    $configRef = [ref]$Config
    $runAs = Ensure-RunAsToolExeResolved `
        -RepoRoot $script:ModuleRoot `
        -ConfigRef $configRef `
        -Launch `
        -LogAction { param($m, $l = 'INFO') Write-BypassSyncLog $m $l }
    $Config = $configRef.Value
    Save-BypassShortcutsConfig -RepoRoot $script:ModuleRoot -Config $Config

    $adminUser = if ($Config.adminUser) { $Config.adminUser } else { $script:DefaultBypassAdminUser }
    Write-BypassSyncLog "RunAsTool launched: $runAs"
    Show-RunAsToolManualStepsDialog -AdminUser $adminUser -BypassesPath $Config.bypassesPath
}

function Invoke-BypassReviewWizard {
    param(
        [string]$InstallDir,
        [object]$Config
    )

    $stats = @{ Added = 0; Updated = 0; Skipped = 0; Renamed = 0; Errors = 0; Cancelled = 0 }
    $bypassesPath = $Config.bypassesPath

    if ([string]::IsNullOrWhiteSpace($bypassesPath)) {
        throw "Game Shortcuts folder is not configured. Run Setup Bypass Folder first."
    }

    $syncList = Get-BypassSyncList -RepoRoot $script:ModuleRoot
    if ($syncList.Count -eq 0) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            "Bypass sync list is empty.`n`nAdd entries on the Bypass Sync tab (or PlayNite library -> Add to Bypass Sync) before running review.",
            "Bypass review",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $stats.Cancelled = 1
        return $stats
    }

    $missingLnks = @()
    foreach ($entry in $syncList) {
        $lnk = Join-Path $bypassesPath "$($entry.shortcutName).lnk"
        if (-not (Test-Path -LiteralPath $lnk)) {
            $missingLnks += $entry.shortcutName
        }
    }
    if ($missingLnks.Count -eq $syncList.Count) {
        Add-Type -AssemblyName System.Windows.Forms | Out-Null
        [System.Windows.Forms.MessageBox]::Show(
            "No sync-list shortcuts found in:`n$bypassesPath`n`nRun Setup Bypass first, or create shortcuts in RunAsTool (`-RunAsToolOnly`).",
            "Bypass review",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        $stats.Cancelled = 1
        return $stats
    }

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.MessageBox]::Show(
        "Playnite will be closed if it is running so games.db can be read and updated.",
        "Bypass sync",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

    $rows = Get-BypassShortcutReviewRowsFromSyncList `
        -BypassesPath $bypassesPath `
        -RepoRoot $script:ModuleRoot `
        -InstallDir $InstallDir `
        -LogAction { param($m, $l = 'INFO') Write-BypassSyncLog $m $l }

    $reviewed = Show-BypassShortcutReviewDialog -Rows $rows -BypassesPath $bypassesPath
    if (-not $reviewed) {
        $stats.Cancelled = 1
        return $stats
    }

    $syncStats = Invoke-BypassShortcutReviewSync `
        -InstallDir $InstallDir `
        -RepoRoot $script:ModuleRoot `
        -BypassesPath $bypassesPath `
        -ReviewedRows $reviewed `
        -LogAction { param($m, $l = 'INFO') Write-BypassSyncLog $m $l }

    $stats.Added = $syncStats.Added
    $stats.Updated = $syncStats.Updated
    $stats.Skipped = $syncStats.Skipped
    $stats.Renamed = $syncStats.Renamed
    $stats.Errors = $syncStats.Errors
    if ($syncStats.DuplicateNotices -and $syncStats.DuplicateNotices.Count -gt 0) {
        Show-BypassDuplicateNoticesDialog -Notices $syncStats.DuplicateNotices
    }
    return $stats
}

try {
    if (Test-Path -LiteralPath $script:LogFile) {
        Remove-Item -LiteralPath $script:LogFile -Force -ErrorAction SilentlyContinue
    }
    Write-BypassSyncLog "=== Sync-PlayniteBypassShortcuts started ==="

    $installDir = Resolve-PlayniteInstallDir -PreferredDir $(Resolve-PlayniteInstallPathFromConfig -RepoRoot $script:ModuleRoot -OverrideDir $PlayniteInstallDir)
    if (-not $installDir) {
        throw "Playnite install folder is not set. Run Setup-PlayniteSteam.bat first."
    }

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $script:ModuleRoot
    $config = $wrapper.Config

    if ($SyncOnly.IsPresent) {
        if ([string]::IsNullOrWhiteSpace($config.bypassesPath)) {
            throw "Game Shortcuts path not configured. Run with -PickParentFolder first."
        }
        $stats = Invoke-PlayniteBypassShortcutsSyncFromFolder `
            -InstallDir $installDir `
            -RepoRoot $script:ModuleRoot `
            -BypassesPath $config.bypassesPath `
            -WhatIf:$WhatIf `
            -LogAction { param($m, $l = 'INFO') Write-BypassSyncLog $m $l }
        Write-BypassSyncLog ("SyncOnly done: updated={0} skipped={1} missing={2}" -f $stats.Updated, $stats.Skipped, $stats.Missing)
    }
    elseif ($RunAsToolOnly.IsPresent) {
        $pick = $PickParentFolder.IsPresent -or [string]::IsNullOrWhiteSpace($config.bypassesPath)
        Invoke-RunAsToolOnlyStep -Config $config -PickFolder:$pick
        Write-BypassSyncLog "RunAsToolOnly done."
    }
    elseif ($PickParentFolder.IsPresent -and -not $Interactive.IsPresent) {
        $config = Initialize-BypassSetupPaths -Parent $ParentPath -PickFolder:$true
        Write-BypassSyncLog "Bypass folder setup complete (use -RunAsToolOnly then -Interactive to sync shortcuts)."
    }
    else {
        if ($PickParentFolder.IsPresent -or [string]::IsNullOrWhiteSpace($config.bypassesPath)) {
            $pick = $PickParentFolder.IsPresent -or [string]::IsNullOrWhiteSpace($config.bypassesPath)
            $config = Initialize-BypassSetupPaths -Parent $ParentPath -PickFolder:$pick
        }
        elseif (-not [string]::IsNullOrWhiteSpace($ParentPath)) {
            $config = Initialize-BypassSetupPaths -Parent $ParentPath
        }

        if ([string]::IsNullOrWhiteSpace($config.bypassesPath)) {
            throw "Game Shortcuts path is not configured."
        }

        $stats = Invoke-BypassReviewWizard -InstallDir $installDir -Config $config
        Write-BypassSyncLog ("Interactive done: added={0} updated={1} skipped={2} renamed={3} errors={4} cancelled={5}" -f `
            $stats.Added, $stats.Updated, $stats.Skipped, $stats.Renamed, $stats.Errors, $stats.Cancelled)
    }

    if ($ExportSunshine.IsPresent) {
        $exportScript = Join-Path $script:WatcherRoot "Export-SunshineFromPlaynite.ps1"
        if (Test-Path -LiteralPath $exportScript) {
            Write-BypassSyncLog "Running Sunshine export..."
            & $exportScript
        }
    }

    Write-BypassSyncLog "=== Sync-PlayniteBypassShortcuts finished ==="
}
catch {
    Write-BypassSyncLog $_.Exception.Message "ERROR"
    throw
}
