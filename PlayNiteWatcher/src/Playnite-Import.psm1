#Requires -Version 5.1

$script:_moduleRoot = $PSScriptRoot

function Show-PlayniteFolderPicker {
    param(
        [string]$Description = "Select a folder",
        [string]$InitialDirectory = "",
        [switch]$AnchorInitialToDriveRoot
    )

    return Show-PlayniteFolderBrowserDialog `
        -Description $Description `
        -InitialDirectory $InitialDirectory `
        -ShowNewFolderButton $false `
        -AnchorInitialToDriveRoot:$AnchorInitialToDriveRoot
}

function Resolve-PlayNiteWatcherRepoRoot {
    param([string]$Candidate = "")

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        $Candidate = $PSScriptRoot
    }

    $dir = $Candidate.TrimEnd('\')
    for ($i = 0; $i -lt 6; $i++) {
        $allowlist = Join-Path $dir "config\playnite\$($script:DesktopAppAllowlistFileName)"
        if (Test-Path -LiteralPath $allowlist) {
            return $dir
        }

        $parent = Split-Path -Path $dir -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) {
            break
        }
        $dir = $parent
    }

    return $Candidate.TrimEnd('\')
}

$script:GamesAppsManifestImported = $false

function Get-NextGpuCoreRepoRootFromWatcher {
    param([string]$WatcherRoot = "")
    $watcher = Resolve-PlayNiteWatcherRepoRoot -Candidate $WatcherRoot
    try {
        return (Resolve-Path -LiteralPath (Join-Path $watcher '..') -ErrorAction Stop).Path
    }
    catch {
        return $null
    }
}

function Import-NextGpuGamesAppsManifest {
    param([string]$WatcherRoot = "")
    if ($script:GamesAppsManifestImported) { return $true }

    $coreRepo = Get-NextGpuCoreRepoRootFromWatcher -WatcherRoot $WatcherRoot
    if (-not $coreRepo) { return $false }

    $manifestScript = Join-Path $coreRepo 'scripts\maintenance\GamesApps-Manifest.ps1'
    if (-not (Test-Path -LiteralPath $manifestScript)) { return $false }

    return $false
}

Export-ModuleMember -Function *
