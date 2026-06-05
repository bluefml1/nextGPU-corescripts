#Requires -Version 5.1
# Shared manifest helpers for Sync-GamesApps-Official.ps1 and Arrange-GamesApps.ps1

# PowerShell unwraps single-element arrays from functions; a leading comma on return nests arrays.
function ConvertTo-ObjectArray {
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Collections.Generic.List[object]]) {
        return [object[]]$InputObject.ToArray()
    }
    if ($InputObject.GetType().IsArray) {
        $arr = [object[]]@($InputObject)
        if ($arr.Count -eq 1 -and $arr[0] -is [System.Array]) {
            return [object[]]@($arr[0])
        }
        return $arr
    }
    return @($InputObject)
}

function Get-ManifestEntryExtractPath {
    param([Parameter(Mandatory)]$Entry)
    if ($null -eq $Entry) { return '' }
    $v = $Entry.ExtractPath
    if ($null -eq $v) { return '' }
    if ($v -is [string]) {
        return $v.Trim().Trim('"').TrimEnd('\')
    }
    foreach ($item in @($v)) {
        if ($null -eq $item) { continue }
        if ($item -is [string]) {
            $s = $item.Trim().Trim('"').TrimEnd('\')
            if ($s) { return $s }
        }
    }
    return ''
}

function Get-ManifestEntryType {
    param([Parameter(Mandatory)]$Entry)
    if ($null -eq $Entry) { return '' }
    $v = $Entry.Type
    if ($null -eq $v) { return '' }
    if ($v -is [string]) { return $v.Trim() }
    $parts = @($v | ForEach-Object { if ($_ -is [string]) { $_.Trim() } else { [string]$_ } } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return '' }
    $steamApp = @($parts | Where-Object { $_ -ieq 'Steam app' } | Select-Object -First 1)
    if ($steamApp) { return $steamApp }
    return ($parts[-1])
}

function Test-ManifestEntryIsSteamClient {
    param([Parameter(Mandatory)]$Entry)
    if ((Get-ManifestEntryType -Entry $Entry) -ieq 'Steam app') { return $true }
    $path = Get-ManifestEntryExtractPath -Entry $Entry
    if (-not $path) { return $false }
    if (Test-IsSteamClientPath -Path $path) { return $true }
    return [bool](Find-SteamClientPathUnderDirectory -Root $path -MaxDepth 3)
}

function Get-ConfiguredSteamInstallPath {
    if ([string]::IsNullOrWhiteSpace($env:NEXTGPU_STEAM_INSTALL_PATH)) { return $null }
    $p = $env:NEXTGPU_STEAM_INSTALL_PATH.Trim().Trim('"').TrimEnd('\')
    if (-not $p) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $null }
        return [System.IO.Path]::GetFullPath($p)
    }
    catch { return $null }
}

function Get-ConfiguredSyncTargetPath {
    if ([string]::IsNullOrWhiteSpace($env:NEXTGPU_SYNC_TARGET)) { return $null }
    $p = $env:NEXTGPU_SYNC_TARGET.Trim().Trim('"').TrimEnd('\')
    if (-not $p) { return $null }
    try {
        if (-not (Test-Path -LiteralPath $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
        }
        return [System.IO.Path]::GetFullPath($p)
    }
    catch { return $null }
}

function Get-PreferredFilesystemBrowseRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    foreach ($candidate in @(
            (Get-ConfiguredSyncTargetPath),
            (Get-ConfiguredSteamInstallPath)
        )) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $key = $candidate.ToLowerInvariant()
        if ($seen[$key]) { continue }
        $seen[$key] = $true
        [void]$roots.Add($candidate)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_SYNC_DRIVE)) {
        $driveLetter = $env:NEXTGPU_SYNC_DRIVE.Trim().TrimEnd(':')
        if ($driveLetter) {
            $driveRoot = "${driveLetter}:\"
            if ((Test-Path -LiteralPath $driveRoot) -and -not $seen[$driveRoot.ToLowerInvariant()]) {
                $seen[$driveRoot.ToLowerInvariant()] = $true
                [void]$roots.Add($driveRoot)
            }
        }
    }

    foreach ($extract in @(Get-DownloadManifestExtractPaths)) {
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        foreach ($part in @(
                $extract,
                (Split-Path -Parent $extract),
                [System.IO.Path]::GetPathRoot($extract)
            )) {
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            try {
                $full = [System.IO.Path]::GetFullPath($part.TrimEnd('\'))
                if (-not (Test-Path -LiteralPath $full)) { continue }
                $key = $full.ToLowerInvariant()
                if ($seen[$key]) { continue }
                $seen[$key] = $true
                [void]$roots.Add($full)
            }
            catch { }
        }
    }

    foreach ($psd in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Sort-Object Free -Descending) {
        if ($psd.DisplayRoot) { continue }
        $driveRoot = "$($psd.Name):\"
        if (-not (Test-Path -LiteralPath $driveRoot)) { continue }
        $key = $driveRoot.ToLowerInvariant()
        if ($seen[$key]) { continue }
        $seen[$key] = $true
        [void]$roots.Add($driveRoot)
    }

    foreach ($fallback in @(
            (Join-Path $env:USERPROFILE 'Downloads'),
            $env:USERPROFILE
        )) {
        if ([string]::IsNullOrWhiteSpace($fallback)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($fallback)
            if (-not (Test-Path -LiteralPath $full)) { continue }
            $key = $full.ToLowerInvariant()
            if ($seen[$key]) { continue }
            $seen[$key] = $true
            [void]$roots.Add($full)
        }
        catch { }
    }

    return $roots.ToArray()
}

function Get-NextGpuRepoRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $root = $env:NEXTGPU_REPO_ROOT.Trim().TrimEnd('\')
        if (Test-Path -LiteralPath $root) { return $root }
    }
    $here = $PSScriptRoot
    if ($here) {
        $candidate = (Resolve-Path -LiteralPath (Join-Path $here '..\..') -ErrorAction SilentlyContinue).Path
        if ($candidate) { return $candidate }
    }
    return $null
}

function Get-NextGpuLogsDirectory {
    $repoRoot = Get-NextGpuRepoRoot
    if ($repoRoot) {
        $logsDir = Join-Path $repoRoot 'logs'
    }
    else {
        $logsDir = Join-Path $env:ProgramData 'nextGPU\logs'
    }
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }
    return $logsDir
}

function Get-DownloadManifestFilePath {
    return Join-Path (Get-NextGpuLogsDirectory) 'sync-games-apps-downloaded.txt'
}

function Get-LegacyDownloadManifestPaths {
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
        if ($d.DisplayRoot) { continue }
        $p = Join-Path "$($d.Name):\" 'NextGPU-Sync\sync-games-apps-downloaded.txt'
        if ((Test-Path -LiteralPath $p) -and ($list -notcontains $p)) {
            [void]$list.Add($p)
        }
    }
    return $list.ToArray()
}

function Get-ResolvedDownloadManifestPath {
    $primary = Get-DownloadManifestFilePath
    if (Test-Path -LiteralPath $primary) { return $primary }
    foreach ($legacy in @(Get-LegacyDownloadManifestPaths)) {
        if (Test-Path -LiteralPath $legacy) { return $legacy }
    }
    return $primary
}

function Read-DownloadManifestEntries {
    param([string]$ManifestPath = '')
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Get-ResolvedDownloadManifestPath
    }
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return @() }

    $inEntry = $false
    $extract = ''
    $type = ''
    $sizeBytes = [int64]0

    foreach ($line in Get-Content -LiteralPath $ManifestPath -ErrorAction SilentlyContinue) {
        $t = $line.Trim()
        if ($t -eq '[entry]') {
            $inEntry = $true
            $extract = ''
            $type = ''
            $sizeBytes = [int64]0
            continue
        }
        if ($t -eq '[/entry]') {
            if ($inEntry -and $extract) {
                [void]$entries.Add([pscustomobject]@{
                    ExtractPath = $extract
                    Type        = $type
                    SizeBytes   = $sizeBytes
                })
            }
            $inEntry = $false
            continue
        }
        if (-not $inEntry) { continue }
        if ($t -match '^extract=(.+)$') { $extract = $Matches[1].Trim() }
        elseif ($t -match '^type=(.+)$') { $type = $Matches[1].Trim() }
        elseif ($t -match '^size_bytes=(\d+)$') { $sizeBytes = [int64]$Matches[1] }
    }
    return ConvertTo-ObjectArray $entries.ToArray()
}

function Get-DownloadManifestExtractPaths {
    param([string]$ManifestPath = '')
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($e in @(ConvertTo-ObjectArray (Read-DownloadManifestEntries -ManifestPath $ManifestPath))) {
        $p = Get-ManifestEntryExtractPath -Entry $e
        if ($p) { [void]$paths.Add($p) }
    }
    return $paths.ToArray()
}

function Test-IsSteamClientPath {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    $steamExe = Join-Path $Path 'steam.exe'
    if (-not (Test-Path -LiteralPath $steamExe -PathType Leaf)) { return $false }
    $hasUi = (Test-Path -LiteralPath (Join-Path $Path 'package')) -or (Test-Path -LiteralPath (Join-Path $Path 'steamui'))
    $hasApps = Test-Path -LiteralPath (Join-Path $Path 'steamapps') -PathType Container
    return ($hasUi -or $hasApps)
}

function Get-ValveSteamRegistryKeyPaths {
    $keys = New-Object System.Collections.Generic.List[string]
    foreach ($valveRoot in @('HKLM:\SOFTWARE\WOW6432Node\Valve', 'HKLM:\SOFTWARE\Valve')) {
        try {
            foreach ($sub in Get-ChildItem -LiteralPath $valveRoot -ErrorAction Stop) {
                if ($sub.PSChildName -ieq 'Steam') { [void]$keys.Add($sub.PSPath) }
            }
        }
        catch { }
    }
    return $keys.ToArray()
}

function Get-SteamInstallPathFromRegistry {
    foreach ($keyPath in @(Get-ValveSteamRegistryKeyPaths)) {
        try {
            $installPath = (Get-ItemProperty -LiteralPath $keyPath -Name InstallPath -ErrorAction Stop).InstallPath
            if ($installPath -and (Test-IsSteamClientPath -Path $installPath.TrimEnd('\', '/'))) {
                return $installPath.TrimEnd('\', '/')
            }
        }
        catch { }
    }
    return $null
}

function Add-SteamInstallCandidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [hashtable]$Seen,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
        $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    }
    catch { return }
    if ($Seen.ContainsKey($full)) { return }
    $Seen[$full] = $true
    if (Test-IsSteamClientPath -Path $full) {
        [void]$List.Add($full)
    }
}

function Get-ManifestPathsToProbeForSteam {
    param([object[]]$Entries = @())
    $probe = New-Object System.Collections.Generic.List[string]
    $probeSeen = @{}

    foreach ($p in @(
            (Get-ConfiguredSteamInstallPath),
            (Get-SteamInstallPathFromRegistry)
        )) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
        }
        catch { continue }
        $key = $full.ToLowerInvariant()
        if ($probeSeen[$key]) { continue }
        $probeSeen[$key] = $true
        [void]$probe.Add($full)
    }

    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        if (Test-ManifestEntryIsSteamClient -Entry $e) {
            $clientPath = Get-ManifestEntryExtractPath -Entry $e
            if (-not [string]::IsNullOrWhiteSpace($clientPath)) {
                try {
                    $full = [System.IO.Path]::GetFullPath($clientPath).TrimEnd('\')
                    $key = $full.ToLowerInvariant()
                    if (-not $probeSeen[$key]) {
                        $probeSeen[$key] = $true
                        [void]$probe.Add($full)
                    }
                }
                catch { }
            }
        }

        $extract = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        foreach ($p in @(
                $extract,
                (Split-Path -Parent $extract),
                [System.IO.Path]::GetPathRoot($extract)
            )) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            try {
                $full = [System.IO.Path]::GetFullPath($p.TrimEnd('\'))
            }
            catch { continue }
            $key = $full.ToLowerInvariant()
            if ($probeSeen[$key]) { continue }
            $probeSeen[$key] = $true
            [void]$probe.Add($full)
        }
    }
    return $probe.ToArray()
}

function Get-SteamInstallCandidatesFromManifest {
    <#
        Steam client folders from NEXTGPU_STEAM_INSTALL_PATH, manifest extract paths,
        shallow search under each sync root, and Valve InstallPath from registry.
    #>
    param([object[]]$Entries = @())
    $list = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $configured = Get-ConfiguredSteamInstallPath
    if ($configured) { Add-SteamInstallCandidate -List $list -Seen $seen -Path $configured }

    foreach ($p in @(Get-ManifestPathsToProbeForSteam -Entries $Entries)) {
        Add-SteamInstallCandidate -List $list -Seen $seen -Path $p
        $found = Find-SteamClientPathUnderDirectory -Root $p
        if ($found) { Add-SteamInstallCandidate -List $list -Seen $seen -Path $found }
    }

    $reg = Get-SteamInstallPathFromRegistry
    if ($reg) { Add-SteamInstallCandidate -List $list -Seen $seen -Path $reg }

    return $list.ToArray()
}

function Find-SteamClientPathUnderDirectory {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaxDepth = 5
    )
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    if (Test-IsSteamClientPath -Path $Root) { return [System.IO.Path]::GetFullPath($Root) }

    $queue = New-Object System.Collections.Generic.Queue[object]
    [void]$queue.Enqueue([pscustomobject]@{ Path = $Root; Depth = 0 })

    while ($queue.Count -gt 0) {
        $cur = $queue.Dequeue()
        if ($cur.Depth -ge $MaxDepth) { continue }
        try {
            foreach ($sub in Get-ChildItem -LiteralPath $cur.Path -Directory -ErrorAction Stop) {
                if ($sub.Name -match '^(windows|win64|linux|macos|__MACOSX)$') { continue }
                if (Test-IsSteamClientPath -Path $sub.FullName) {
                    return [System.IO.Path]::GetFullPath($sub.FullName)
                }
                if ($cur.Depth + 1 -lt $MaxDepth) {
                    [void]$queue.Enqueue([pscustomobject]@{ Path = $sub.FullName; Depth = $cur.Depth + 1 })
                }
            }
        }
        catch { }
    }
    return $null
}

function Find-SteamAppManifests {
    param(
        [Parameter(Mandatory)][string]$ExtractPath,
        [int]$MaxHits = 8
    )
    $result = [pscustomobject]@{
        IsSteamGame     = $false
        ManifestPaths   = [string[]]@()
        ManifestNames   = [string[]]@()
    }
    if (-not (Test-Path -LiteralPath $ExtractPath -PathType Container)) { return $result }

    $hits = New-Object System.Collections.Generic.List[string]
    $names = New-Object System.Collections.Generic.List[string]
    $queue = New-Object System.Collections.Generic.Queue[string]
    [void]$queue.Enqueue($ExtractPath)
    $depthByPath = @{ $ExtractPath = 0 }

    while ($queue.Count -gt 0 -and $hits.Count -lt $MaxHits) {
        $dir = $queue.Dequeue()
        $depth = [int]$depthByPath[$dir]
        try {
            foreach ($f in Get-ChildItem -LiteralPath $dir -File -ErrorAction Stop) {
                $n = $f.Name
                if ($n -like 'appmanifest*.txt' -or $n -like 'appmanifest*.acf') {
                    [void]$hits.Add($f.FullName)
                    [void]$names.Add($n)
                    if ($hits.Count -ge $MaxHits) { break }
                }
            }
            if ($hits.Count -ge $MaxHits -or $depth -ge 4) { continue }
            foreach ($sub in Get-ChildItem -LiteralPath $dir -Directory -ErrorAction Stop) {
                if ($sub.Name -match '^(windows|win64|linux|macos|__MACOSX)$') { continue }
                [void]$queue.Enqueue($sub.FullName)
                $depthByPath[$sub.FullName] = $depth + 1
            }
        }
        catch { }
    }

    if ($hits.Count -gt 0) {
        $result.IsSteamGame = $true
        $result.ManifestPaths = [string[]]$hits.ToArray()
        $result.ManifestNames = [string[]]$names.ToArray()
    }
    return $result
}

function Test-ArchiveNameIsSteamClient {
    param([Parameter(Mandatory)][string]$ArchiveName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ArchiveName.Trim())
    if ([string]::IsNullOrWhiteSpace($base)) { return $false }
    if ($base -match '^(?i)steam$') { return $true }
    if ($base -match '^(?i)steamclient') { return $true }
    if ($base -match '(?i)steam[_\-\s]?(setup|client|installer)') { return $true }
    return $false
}

function Resolve-DownloadEntryType {
    param(
        [Parameter(Mandatory)][string]$ArchiveName,
        [string]$ExtractPath = '',
        [bool]$HasSteamManifest = $false
    )
    if (Test-ArchiveNameIsSteamClient -ArchiveName $ArchiveName) { return 'Steam app' }
    if ($ExtractPath -and (Test-IsSteamClientPath -Path $ExtractPath)) { return 'Steam app' }
    if ($ExtractPath) {
        $nested = Find-SteamClientPathUnderDirectory -Root $ExtractPath -MaxDepth 3
        if ($nested) { return 'Steam app' }
    }
    if ($HasSteamManifest) { return 'steam' }
    return 'generic'
}

function Write-SteamDetectToSyncLog {
    param(
        [string]$LogFile,
        [string]$ArchiveName,
        [string]$ExtractPath,
        [object]$SteamInfo
    )
    if (-not $LogFile -or -not $SteamInfo.IsSteamGame) { return }
    $paths = ($SteamInfo.ManifestPaths | ForEach-Object { $_ }) -join '; '
    $line = ('[{0}] Steam game: {1} | extract={2} | appmanifest={3}' -f (
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),
        $ArchiveName,
        $ExtractPath,
        $paths
    ))
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Update-DownloadManifest {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [string]$RcloneLogFile = '',
        [Parameter(Mandatory)][object[]]$Entries,
        [string]$Status = 'Complete',
        [string]$FailedArchive = ''
    )
    if ($null -eq $Entries -or $Entries.Count -eq 0) { return $null }

    $dir = Split-Path -Parent $ManifestPath
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $block = New-Object System.Collections.Generic.List[string]
    [void]$block.Add('[session]')
    [void]$block.Add(('when={0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    [void]$block.Add(('status={0}' -f $Status))
    if ($RcloneLogFile) { [void]$block.Add(('rclone_log={0}' -f $RcloneLogFile)) }
    if ($FailedArchive) { [void]$block.Add(('stopped_at={0}' -f $FailedArchive)) }

    foreach ($e in $Entries) {
        $extractPath = Get-ManifestEntryExtractPath -Entry $e
        if (-not $extractPath) { continue }
        $gameType = Get-ManifestEntryType -Entry $e
        if (-not $gameType) {
            $gameType = Resolve-DownloadEntryType -ArchiveName ([string]$e.Name) -ExtractPath $extractPath -HasSteamManifest:([bool]$e.IsSteamGame)
        }
        [void]$block.Add('[entry]')
        [void]$block.Add(('extract={0}' -f $extractPath))
        [void]$block.Add(('size_bytes={0}' -f [int64]$e.SizeBytes))
        [void]$block.Add(('type={0}' -f $gameType))
        [void]$block.Add('[/entry]')
    }
    [void]$block.Add('[/session]')

    $text = ($block.ToArray() -join [Environment]::NewLine) + [Environment]::NewLine
    if (Test-Path -LiteralPath $ManifestPath) {
        Add-Content -LiteralPath $ManifestPath -Value $text -Encoding UTF8
    }
    else {
        Set-Content -LiteralPath $ManifestPath -Value $text -Encoding UTF8
    }
    return $ManifestPath
}

function Get-ArrangeGamesAppsLogPath {
    return Join-Path (Get-NextGpuLogsDirectory) 'arrange-games-apps.log'
}
