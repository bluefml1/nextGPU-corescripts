#Requires -Version 5.1
# Steam detection, Steam extension install, and game export helpers

$script:_moduleRoot = $PSScriptRoot

# Plugin IDs (also defined in Playnite-Admin.psm1 for cross-module use)
$script:PlayniteSteamPluginId = "CB91DFC9-B977-43BF-8E70-55F46E410FAB"
$script:PlayniteEpicPluginId  = "00000002-DBD1-46C6-B5D0-B1BA559D10E4"

function Test-PlayniteSteamClientPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $steamExe = Join-Path $Path 'steam.exe'
    if (-not (Test-Path -LiteralPath $steamExe -PathType Leaf)) { return $false }
    $hasUi = (Test-Path -LiteralPath (Join-Path $Path 'package')) -or (Test-Path -LiteralPath (Join-Path $Path 'steamui'))
    $hasApps = Test-Path -LiteralPath (Join-Path $Path 'steamapps') -PathType Container
    return ($hasUi -or $hasApps)
}

function Get-PlayniteSteamPathFromRegistry {
    $keyPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    foreach ($keyPath in $keyPaths) {
        try {
            $installPath = (Get-ItemProperty -LiteralPath $keyPath -Name InstallPath -ErrorAction Stop).InstallPath
            if ($installPath -and (Test-PlayniteSteamClientPath -Path $installPath.TrimEnd('\', '/'))) {
                return $installPath.TrimEnd('\', '/')
            }
        }
        catch { }
    }
    return $null
}

function Resolve-PlayniteSteamFromR2Manifest {
    param(
        [string]$WatcherRoot = "",
        [scriptblock]$LogAction = $null
    )

    $write = if ($LogAction) { $LogAction } else { { param($Message, $Level) } }
    if (-not (Import-NextGpuGamesAppsManifest -WatcherRoot $WatcherRoot)) {
        & $write 'R2 manifest helpers not available (GamesApps-Manifest.ps1 missing).' 'WARN'
        return $null
    }

    if (-not (Get-Command Read-DownloadManifestEntries -ErrorAction SilentlyContinue)) {
        & $write 'R2 manifest helpers unavailable; skipping Steam discovery.' 'WARN'
        return $null
    }

    try {
        $entries = @(Read-DownloadManifestEntries)
    }
    catch {
        & $write "R2 manifest read failed; skipping Steam: $($_.Exception.Message)" 'WARN'
        return $null
    }
    if ($entries.Count -eq 0) {
        & $write 'No R2 sync manifest entries (sync-games-apps-downloaded.txt).' 'WARN'
        return $null
    }

    $steamClients = @($entries | Where-Object { Test-ManifestEntryIsSteamClient $_ })
    foreach ($entry in $steamClients) {
        $extract = Get-ManifestEntryExtractPath -Entry $entry
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        if (-not (Test-Path -LiteralPath $extract -PathType Container)) {
            & $write "R2 Steam app extract missing on disk: $extract" 'WARN'
            continue
        }
        $full = [System.IO.Path]::GetFullPath($extract)
        if (Test-PlayniteSteamClientPath -Path $full) {
            return [PSCustomObject]@{ Path = $full; Source = 'R2Manifest' }
        }
        if (Get-Command Find-SteamClientPathUnderDirectory -ErrorAction SilentlyContinue) {
            $nested = Find-SteamClientPathUnderDirectory -Root $full
            if ($nested) {
                return [PSCustomObject]@{ Path = $nested; Source = 'R2ManifestNested' }
            }
        }
        if (Test-Path -LiteralPath (Join-Path $full 'steam.exe') -PathType Leaf) {
            return [PSCustomObject]@{ Path = $full; Source = 'R2Manifest' }
        }
    }

    if (Get-Command Get-SteamInstallCandidatesFromManifest -ErrorAction SilentlyContinue) {
        foreach ($candidate in @(Get-SteamInstallCandidatesFromManifest -Entries $entries)) {
            if (Test-PlayniteSteamClientPath -Path $candidate) {
                return [PSCustomObject]@{ Path = $candidate; Source = 'R2Candidate' }
            }
        }
    }

    return $null
}

function Resolve-PlayniteSteamInstallPath {
    <#
        Prefer Steam already on the machine (registry / common folders), then R2-downloaded Steam from sync manifest.
    #>
    param(
        [string]$OverridePath = "",
        [string]$WatcherRoot = "",
        [scriptblock]$LogAction = $null
    )

    $write = if ($LogAction) { $LogAction } else { { param($Message, $Level) } }

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        $override = $OverridePath.Trim().TrimEnd('\')
        if (Test-PlayniteSteamClientPath -Path $override) {
            & $write "Steam from -SteamInstallPath: $override" 'INFO'
            return [PSCustomObject]@{ Path = $override; Source = 'Override' }
        }
        & $write "Override Steam path invalid: $override" 'WARN'
    }

    $fromReg = Get-PlayniteSteamPathFromRegistry
    if ($fromReg) {
        & $write "Steam on machine (registry): $fromReg" 'INFO'
        return [PSCustomObject]@{ Path = $fromReg; Source = 'Registry' }
    }

    $commonPaths = @(
        'C:\Program Files (x86)\Steam',
        'C:\Program Files\Steam',
        'D:\Steam', 'D:\Games\Steam',
        'E:\Steam', 'E:\Games\Steam',
        'F:\Steam', 'F:\Games\Steam'
    )
    foreach ($base in $commonPaths) {
        try {
            if (-not (Test-Path -LiteralPath $base)) { continue }
            $resolved = ([System.IO.Path]::GetFullPath($base)).TrimEnd('\')
            if (Test-PlayniteSteamClientPath -Path $resolved) {
                & $write "Steam on machine (common path): $resolved" 'INFO'
                return [PSCustomObject]@{ Path = $resolved; Source = 'CommonPath' }
            }
        }
        catch { }
    }

    & $write 'Steam not found on machine; checking R2 sync manifest...' 'INFO'
    return Resolve-PlayniteSteamFromR2Manifest -WatcherRoot $WatcherRoot -LogAction $LogAction
}

function Register-PlayniteSteamInstallPath {
    param(
        [Parameter(Mandatory)][string]$SteamPath,
        [scriptblock]$LogAction = $null
    )

    $write = if ($LogAction) { $LogAction } else { { param($Message, $Level) } }
    Import-NextGpuGamesAppsManifest | Out-Null
    if (Get-Command Register-SteamInstallPath -ErrorAction SilentlyContinue) {
        return Register-SteamInstallPath -SteamPath $SteamPath -LogAction $LogAction
    }

    $steamPath = $SteamPath.Trim().TrimEnd('\')
    if (-not (Test-PlayniteSteamClientPath -Path $steamPath)) {
        throw "Not a valid Steam client folder: $steamPath"
    }

    $keyPath = 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam'
    if (-not (Test-Path -LiteralPath $keyPath)) {
        New-Item -Path $keyPath -Force | Out-Null
    }

    $current = $null
    try {
        $current = (Get-ItemProperty -LiteralPath $keyPath -Name InstallPath -ErrorAction Stop).InstallPath
    }
    catch { }

    if ($current -and ($current.TrimEnd('\') -ieq $steamPath)) {
        return $false
    }

    Set-ItemProperty -LiteralPath $keyPath -Name InstallPath -Value $steamPath
    & $write "Registered Steam InstallPath in registry: $steamPath" 'INFO'
    return $true
}

function Ensure-PlayniteSteamForLibraryScan {
    param(
        [string]$WatcherRoot = "",
        [string]$OverridePath = "",
        [scriptblock]$LogAction = $null
    )

    try {
        $resolved = Resolve-PlayniteSteamInstallPath -OverridePath $OverridePath -WatcherRoot $WatcherRoot -LogAction $LogAction
    }
    catch {
        if ($LogAction) {
            & $LogAction "Steam discovery failed; skipping Steam library import: $($_.Exception.Message)" 'WARN'
        }
        return $null
    }
    if (-not $resolved -or [string]::IsNullOrWhiteSpace($resolved.Path)) {
        if ($LogAction) {
            & $LogAction 'Steam not found (machine or R2 manifest). Steam library import will be skipped.' 'WARN'
        }
        return $null
    }

    if ($resolved.Source -notin @('Registry', 'Override')) {
        try {
            Register-PlayniteSteamInstallPath -SteamPath $resolved.Path -LogAction $LogAction
        }
        catch {
            if ($LogAction) {
                & $LogAction ("Could not register Steam in registry (run as Admin?): $($_.Exception.Message)") 'WARN'
            }
        }
    }

    return $resolved
}

function Get-ExportablePlayniteGames {
    param(
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    $rows = Get-PlayniteGameRecordsFromLiteDb -InstallDir $InstallDir -LogAction $LogAction
    $games = New-Object System.Collections.Generic.List[object]

    foreach ($row in $rows) {
        if ([string]::IsNullOrWhiteSpace($row.Id)) { continue }

        $sourceLabel = $null
        if ($row.PluginId -ieq $script:PlayniteSteamPluginId) {
            $sourceLabel = "Steam"
        }
        elseif ($row.PluginId -ieq $script:PlayniteEpicPluginId) {
            $sourceLabel = "Epic"
        }
        else {
            continue
        }

        [void]$games.Add([PSCustomObject]@{
                Id               = $row.Id.ToString()
                GameId           = if ($row.GameId) { $row.GameId.ToString() } else { "" }
                Name             = if ($row.Name) { $row.Name.ToString() } else { "" }
                InstallDirectory = if ($row.InstallDirectory) { $row.InstallDirectory.ToString() } else { "" }
                SourceLabel      = $sourceLabel
                SkipAclGrant     = $false
            })
    }

    return $games.ToArray()
}

Export-ModuleMember -Function *
