#Requires -Version 5.1

$script:_moduleRoot = $PSScriptRoot

# ─────────────────────────────────────────────────────────────────────────────
# Everything SDK integration and allowlist exe search helpers
# ─────────────────────────────────────────────────────────────────────────────

$script:DesktopImportRepoRoot = $null
$script:DesktopImportUseEverythingSearch = $false
$script:DesktopImportEverythingOnly = $false

function Get-EverythingToolsDirectory {
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = $PSScriptRoot
    }
    return Join-Path $RepoRoot "tools\everything"
}

function Get-EverythingEsCandidatePaths {
    param([string]$RepoRoot = "")

    $paths = New-Object System.Collections.Generic.List[string]

    $add = {
        param([string]$p)
        if (-not [string]::IsNullOrWhiteSpace($p) -and (Test-Path -LiteralPath $p)) {
            [void]$paths.Add($p)
        }
    }

    & $add (Join-Path $PSScriptRoot "tools\everything")
    & $add (Join-Path $env:ProgramFiles "Everything")
    & $add (Join-Path "${env:ProgramFiles(x86)}" "Everything")
    & $add "C:\Program Files\Everything"
    & $add "C:\Program Files (x86)\Everything"

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        & $add (Get-EverythingToolsDirectory -RepoRoot $RepoRoot)
    }

    return $paths.ToArray()
}

function Get-EverythingEsExePath {
    param(
        [string]$RepoRoot = "",
        [scriptblock]$LogAction
    )

    foreach ($dir in (Get-EverythingEsCandidatePaths -RepoRoot $RepoRoot)) {
        $exe = Join-Path $dir "es.exe"
        if (Test-Path -LiteralPath $exe) {
            return $exe
        }
    }

    return $null
}

function Get-ExcludedSystemDriveRoots {
    $roots = New-Object System.Collections.Generic.List[string]
    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if ($drive.DriveType -ne [System.IO.DriveType]::Fixed) { continue }
        [void]$roots.Add($drive.RootDirectory.FullName.TrimEnd('\'))
    }
    return $roots.ToArray()
}

function Normalize-EverythingSearchPath {
    param(
        [string]$Path,
        [string]$ScanRoot = ""
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $normalized = "$Path".Trim().Trim('"')
    if ($normalized.StartsWith('\\?\UNC\', [System.StringComparison]::OrdinalIgnoreCase)) {
        $normalized = '\' + $normalized.Substring(8)
    }
    elseif ($normalized.StartsWith('\\?\', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(4)
    }

    $normalized = $normalized -replace '/', '\'

    if (-not [System.IO.Path]::IsPathRooted($normalized) -and -not [string]::IsNullOrWhiteSpace($ScanRoot)) {
        $normalized = Join-Path $ScanRoot.TrimEnd('\') $normalized
    }

    try {
        return [System.IO.Path]::GetFullPath($normalized)
    }
    catch {
        return $normalized
    }
}

function ConvertFrom-EverythingSearchOutputLine {
    param([object]$Line)

    $text = "$Line".Trim()
    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    if ($text -match '^(?<path>".+\.exe")') {
        return $Matches.path.Trim('"')
    }

    if ($text -match '^(?<path>[^\t]+\.exe)\b') {
        return $Matches.path.Trim().Trim('"')
    }

    if ($text.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $text.Trim('"')
    }

    return $null
}

function Test-AllowlistedExeLeafMatch {
    param(
        [string]$CandidatePath,
        [string]$AllowlistExeName
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath) -or [string]::IsNullOrWhiteSpace($AllowlistExeName)) {
        return $false
    }

    $leaf = ([System.IO.Path]::GetFileName($CandidatePath)).ToLowerInvariant()
    $key = $AllowlistExeName.ToLowerInvariant()
    if ($leaf -eq $key) {
        return $true
    }

    if ($leaf.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
        $targetLeaf = [System.IO.Path]::GetFileNameWithoutExtension($leaf).ToLowerInvariant()
        if ($targetLeaf -eq $key) {
            return $true
        }
    }

    return $false
}

function Test-PathUnderScanRoot {
    param(
        [string]$Path,
        [string]$ScanRoot
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($ScanRoot)) {
        return $false
    }

    $fullPath = Normalize-EverythingSearchPath -Path $Path -ScanRoot $ScanRoot
    $fullRoot = Normalize-EverythingSearchPath -Path $ScanRoot
    if ([string]::IsNullOrWhiteSpace($fullPath) -or [string]::IsNullOrWhiteSpace($fullRoot)) {
        return $false
    }

    if ($fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    if (-not $fullRoot.EndsWith('\')) {
        $fullRoot = $fullRoot + '\'
    }

    return $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-DesktopScanDirectoryName {
    param([string]$Name)
    foreach ($skip in $script:DesktopScanSkipDirNames) {
        if ($Name -ieq $skip) { return $true }
    }
    return $false
}

function Test-DesktopScanRootIsOnSystemDrive {
    param([string]$ScanRoot)

    if ([string]::IsNullOrWhiteSpace($ScanRoot)) {
        return $false
    }

    $normalized = Normalize-EverythingSearchPath -Path $ScanRoot
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    foreach ($sysRoot in (Get-ExcludedSystemDriveRoots)) {
        if (Test-PathUnderScanRoot -Path $normalized -ScanRoot $sysRoot) {
            return $true
        }
    }

    return $false
}

function Test-DesktopScanInstallerExeExcluded {
    param([string]$FullPath)

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        return $true
    }

    $leaf = [System.IO.Path]::GetFileName($FullPath)
    return ($leaf -match '(?i)^(uninstall|setup|install|update|redist|vcredist|dxsetup)')
}

function Test-DesktopScanPathOnSystemDrive {
    param([string]$FullPath)

    if ([string]::IsNullOrWhiteSpace($FullPath)) {
        return $false
    }

    $normalized = Normalize-EverythingSearchPath -Path $FullPath
    foreach ($sysRoot in (Get-ExcludedSystemDriveRoots)) {
        if (Test-PathUnderScanRoot -Path $normalized -ScanRoot $sysRoot) {
            return $true
        }
    }

    return $false
}

function Select-BestAllowlistedExeHit {
    param([object[]]$Candidates)

    $list = @($Candidates)
    if ($list.Length -eq 0) {
        return $null
    }

    $ranked = foreach ($candidate in $list) {
        $sortTime = [datetime]::MinValue
        if ($null -ne $candidate.LastWriteTime -and $candidate.LastWriteTime -is [datetime]) {
            $sortTime = $candidate.LastWriteTime
        }
        [PSCustomObject]@{
            Hit      = $candidate
            SortTime = $sortTime
        }
    }

    return ($ranked | Sort-Object SortTime -Descending | Select-Object -First 1).Hit
}

# ─────────────────────────────────────────────────────────────────────────────
# Everything-based allowlist search and path-walk helpers
# ─────────────────────────────────────────────────────────────────────────────

function Get-EverythingSearchQueriesForAllowlistExe {
    param([string]$ExeName)
    $name = $ExeName.Trim()
    if ([string]::IsNullOrWhiteSpace($name)) { return @() }
    return @($name, "wfn:$name", "=$name")
}

function Invoke-EverythingEsSearchLines {
    param([string]$EsExe, [string]$SearchQuery, [string]$ScanRootFull = "", [int]$MaxResults = 50, [int]$TimeoutMs = 15000)
    $argList = @('-a-d', '-max-results', "$MaxResults", '-timeout', "$TimeoutMs")
    if ($ScanRootFull) { $argList += @('-path', $ScanRootFull) }
    $argList += $SearchQuery
    $lines = @( & $EsExe @argList 2>$null | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = -1 }
    return [PSCustomObject]@{ Lines = $lines; ExitCode = [int]$exitCode; Arguments = ($argList -join ' ') }
}

function Test-EverythingSearchHitCandidate {
    param([string]$RawLine, [string]$AllowlistExeName, [string]$ScanRootFull = "", [ref]$RejectReason)
    $RejectReason.Value = $null
    $parsed = ConvertFrom-EverythingSearchOutputLine -Line $RawLine
    if (-not $parsed) { $RejectReason.Value = 'not an exe path line'; return $null }
    $path = Normalize-EverythingSearchPath -Path $parsed -ScanRoot $ScanRootFull
    if ([string]::IsNullOrWhiteSpace($path)) { $RejectReason.Value = 'could not normalize path'; return $null }
    if (-not $path.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $RejectReason.Value = 'does not end with .exe'; return $null }
    if (-not (Test-AllowlistedExeLeafMatch -CandidatePath $path -AllowlistExeName $AllowlistExeName)) { $RejectReason.Value = "filename mismatch (got $([System.IO.Path]::GetFileName($path)))"; return $null }
    if (Test-DesktopScanInstallerExeExcluded -FullPath $path) { $RejectReason.Value = 'installer or redistributable exe name'; return $null }
    if (Test-DesktopScanPathOnSystemDrive -FullPath $path) { $RejectReason.Value = 'on system/boot drive'; return $null }
    if ($ScanRootFull -and -not (Test-PathUnderScanRoot -Path $path -ScanRoot $ScanRootFull)) { $RejectReason.Value = "outside scan root $ScanRootFull"; return $null }
    if ($path.EndsWith('.lnk', [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($path)
            $target = $shortcut.TargetPath
            if (-not [string]::IsNullOrWhiteSpace($target) -and $target.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) { $path = Normalize-EverythingSearchPath -Path $target -ScanRoot $ScanRootFull }
        }
        catch { }
    }
    return $path
}

function Find-AllowlistedExesViaEverything {
    param([string]$ScanRoot, [object[]]$Allowlist, [string]$RepoRoot = "", [int]$MaxResultsPerExe = 50, [scriptblock]$LogAction)
    $esExe = Get-EverythingEsExePath -RepoRoot $RepoRoot
    if (-not $esExe) { if ($LogAction) { & $LogAction "Everything search: es.exe not found; no results." "WARN" }; return @() }
    if ($LogAction) { & $LogAction "Everything search: using $esExe" }
    $scanRootFull = $null
    if (-not [string]::IsNullOrWhiteSpace($ScanRoot) -and (Test-Path -LiteralPath $ScanRoot)) { $scanRootFull = Normalize-EverythingSearchPath -Path $ScanRoot }
    $candidatesByKey = @{}
    foreach ($entry in $Allowlist) {
        $key = $entry.Exe.ToLowerInvariant()
        $rejectNotes = New-Object System.Collections.Generic.List[string]
        $lastSearch = $null
        foreach ($searchQuery in (Get-EverythingSearchQueriesForAllowlistExe -ExeName $entry.Exe)) {
            if ($candidatesByKey.ContainsKey($key)) { break }
            try { $lastSearch = Invoke-EverythingEsSearchLines -EsExe $esExe -SearchQuery $searchQuery -ScanRootFull $scanRootFull -MaxResults $MaxResultsPerExe -TimeoutMs 15000 }
            catch { if ($LogAction) { & $LogAction ("Everything search failed for $($entry.Exe): " + $_.Exception.Message) "WARN" }; continue }
            if ($LogAction) {
                $argPreview = $lastSearch.Arguments; if ($argPreview.Length -gt 200) { $argPreview = $argPreview.Substring(0, 200) + '...' }
                & $LogAction ("Everything search: $($entry.Exe) exit=$($lastSearch.ExitCode) ($(Get-EverythingEsExitCodeDescription -ExitCode $lastSearch.ExitCode)) lines=$($lastSearch.Lines.Count) args: $argPreview")
            }
            if ($lastSearch.ExitCode -ne 0) { continue }
            foreach ($line in $lastSearch.Lines) {
                $reason = ''; $reasonRef = [ref]$reason
                $hitPath = Test-EverythingSearchHitCandidate -RawLine $line -AllowlistExeName $entry.Exe -ScanRootFull $scanRootFull -RejectReason $reasonRef
                if (-not $hitPath) {
                    if ($reason) { $preview = "$line".Trim(); if ($preview.Length -gt 160) { $preview = $preview.Substring(0, 160) + '...' }; [void]$rejectNotes.Add("$preview -> $reason") }
                    continue
                }
                $lastWrite = [datetime]::MinValue
                if (Test-Path -LiteralPath $hitPath) { try { $lastWrite = (Get-Item -LiteralPath $hitPath).LastWriteTimeUtc } catch { } }
                $hit = [PSCustomObject]@{ AllowlistEntry = $entry; FullPath = $hitPath; LastWriteTime = $lastWrite }
                if (-not $candidatesByKey.ContainsKey($key)) { $candidatesByKey[$key] = New-Object System.Collections.Generic.List[object] }
                [void]$candidatesByKey[$key].Add($hit)
            }
        }
        if ($LogAction -and (-not $candidatesByKey.ContainsKey($key))) {
            $lineCount = 0; if ($lastSearch -and $lastSearch.Lines) { $lineCount = @($lastSearch.Lines).Count }
            if ($lineCount -gt 0 -or $rejectNotes.Count -gt 0) {
                $sample = ($rejectNotes | Select-Object -First 3) -join ' | '
                if (-not $sample -and $lastSearch) { $sample = (@($lastSearch.Lines | Select-Object -First 2 | ForEach-Object { "$_" }) -join ' | ') }
                & $LogAction "Everything search: $($entry.Exe) no usable hit. $sample" "WARN"
            }
        }
    }
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($key in $candidatesByKey.Keys) { $best = Select-BestAllowlistedExeHit -Candidates @($candidatesByKey[$key].ToArray()); if ($best) { [void]$results.Add($best) } }
    return $results.ToArray()
}

function Find-AllowlistedExesUnderPathWalk {
    param([string]$ScanRoot, [object[]]$Allowlist, [int]$MaxDepth = 8)
    if (-not (Test-Path -LiteralPath $ScanRoot)) { return @() }
    $allowByExe = @{}
    foreach ($item in $Allowlist) { $allowByExe[$item.Exe.ToLowerInvariant()] = $item }
    $found = @{}
    $root = [System.IO.Path]::GetFullPath($ScanRoot.TrimEnd('\'))
    $skipHeavyDirNamesDuringWalk = Test-DesktopScanRootIsOnSystemDrive -ScanRoot $root
    function Search-Dir {
        param([string]$Dir, [int]$Depth)
        if ($Depth -gt $MaxDepth) { return }
        try {
            foreach ($file in [System.IO.Directory]::EnumerateFiles($Dir, '*.exe')) {
                $name = [System.IO.Path]::GetFileName($file)
                $key = $name.ToLowerInvariant()
                if (-not $allowByExe.ContainsKey($key)) { continue }
                $lastWrite = [datetime]::MinValue; try { $lastWrite = (Get-Item -LiteralPath $file).LastWriteTimeUtc } catch { }
                $item = [PSCustomObject]@{ AllowlistEntry = $allowByExe[$key]; FullPath = $file; LastWriteTime = $lastWrite }
                if (-not $found.ContainsKey($key)) { $found[$key] = New-Object System.Collections.Generic.List[object] }
                [void]$found[$key].Add($item)
            }
            if ($Depth -ge $MaxDepth) { return }
            foreach ($sub in [System.IO.Directory]::EnumerateDirectories($Dir)) {
                $leaf = [System.IO.Path]::GetFileName($sub)
                if ($skipHeavyDirNamesDuringWalk -and (Test-DesktopScanDirectoryName -Name $leaf)) { continue }
                Search-Dir -Dir $sub -Depth ($Depth + 1)
            }
        }
        catch { }
    }
    Search-Dir -Dir $root -Depth 0
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($key in $found.Keys) { $best = Select-BestAllowlistedExeHit -Candidates @($found[$key].ToArray()); if ($best) { [void]$results.Add($best) } }
    return $results.ToArray()
}

function Find-AllowlistedExeHitForEntry {
    param([string]$ScanRoot, [object]$Entry, [object[]]$Allowlist, [string]$RepoRoot = "", [scriptblock]$LogAction)
    if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $script:DesktopImportRepoRoot) { $RepoRoot = $script:DesktopImportRepoRoot }
    $single = @($Entry)
    if ($script:DesktopImportUseEverythingSearch) {
        $hits = @(Find-AllowlistedExesViaEverything -ScanRoot $ScanRoot -Allowlist $single -RepoRoot $RepoRoot -LogAction $LogAction)
        if ($hits.Length -gt 0) { return $hits[0] }
        return $null
    }
    if ($script:DesktopImportEverythingOnly) { return $null }
    $walkHits = @(Find-AllowlistedExesUnderPathWalk -ScanRoot $ScanRoot -Allowlist $single)
    if ($walkHits.Length -gt 0) { return $walkHits[0] }
    return $null
}

function Find-AllowlistedExesUnderPath {
    param([string]$ScanRoot, [object[]]$Allowlist, [int]$MaxDepth = 8, [string]$RepoRoot = "", [switch]$ForceWalk, [scriptblock]$LogAction)
    if ([string]::IsNullOrWhiteSpace($RepoRoot) -and $script:DesktopImportRepoRoot) { $RepoRoot = $script:DesktopImportRepoRoot }
    $useEverything = (-not $ForceWalk) -and $script:DesktopImportUseEverythingSearch
    $hitByExe = @{}
    if ($useEverything) {
        $everythingHits = Find-AllowlistedExesViaEverything -ScanRoot $ScanRoot -Allowlist $Allowlist -RepoRoot $RepoRoot -LogAction $LogAction
        foreach ($hit in $everythingHits) { $hitByExe[$hit.AllowlistEntry.Exe.ToLowerInvariant()] = $hit }
    }
    $missing = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $Allowlist) { $key = $entry.Exe.ToLowerInvariant(); if (-not $hitByExe.ContainsKey($key)) { [void]$missing.Add($entry) } }
    if ($missing.Count -gt 0 -and -not $script:DesktopImportEverythingOnly) {
        $walkHits = Find-AllowlistedExesUnderPathWalk -ScanRoot $ScanRoot -Allowlist @($missing.ToArray()) -MaxDepth $MaxDepth
        foreach ($hit in $walkHits) { $key = $hit.AllowlistEntry.Exe.ToLowerInvariant(); if (-not $hitByExe.ContainsKey($key)) { $hitByExe[$key] = $hit } }
    }
    elseif (-not $useEverything -and -not $script:DesktopImportEverythingOnly) {
        $walkHits = Find-AllowlistedExesUnderPathWalk -ScanRoot $ScanRoot -Allowlist $Allowlist -MaxDepth $MaxDepth
        foreach ($hit in $walkHits) { $hitByExe[$hit.AllowlistEntry.Exe.ToLowerInvariant()] = $hit }
    }
    return @($hitByExe.Values)
}

Export-ModuleMember -Function *
