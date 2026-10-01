#Requires -Version 5.1
<#
.SYNOPSIS
    Manage %ProgramData%\nextGPU\launch-companions.json: helper exes that NextGPUService
    starts as NextGPU-Admin before an elevated app (e.g. gxxapphelper.exe for Garena.exe).
.DESCRIPTION
    -SeedDefaults        Add rows from config\launch-companions.defaults.json that are not listed yet.
    -Seed                Resolve exe/searchDir for every row (or only -MainExe) via Everything (es.exe),
                         falling back to a folder walk when Everything is not reachable.
    -SaveJson <file>     Replace the list with rows from a JSON array of
                         { mainExe, exeName, exe, searchDir, delayMs } (written by the NextGPU app).
    -StatusOnly          Print rows + status as one "@@LAUNCH_COMPANIONS_STATUS@@<json>" line.
    -NoEverythingInstall Never download/install Everything; use the folder walk instead.

    Every write re-applies the ACL NextGPUService requires before it trusts the file:
    owner Administrators, SYSTEM + Administrators Full Control, Users Read, no inheritance.
.EXAMPLE
    .\Update-LaunchCompanions.ps1 -SeedDefaults -Seed
    .\Update-LaunchCompanions.ps1 -Seed -MainExe Garena.exe
    .\Update-LaunchCompanions.ps1 -StatusOnly
#>
[CmdletBinding()]
param(
    [switch]$SeedDefaults,
    [switch]$Seed,
    [string]$MainExe = '',
    [string]$SaveJson = '',
    [switch]$StatusOnly,
    [switch]$NoEverythingInstall,
    [string]$DefaultsPath = ''
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$script:WatcherRoot = Join-Path $script:RepoRoot 'PlayNiteWatcher'
$script:ConfigDir = Join-Path $env:ProgramData 'nextGPU'
$script:ConfigPath = Join-Path $script:ConfigDir 'launch-companions.json'
$script:LogPath = Join-Path $script:ConfigDir 'logs\launch-companions.log'
$script:MaxDelayMs = 2000
$script:StatusMarker = '@@LAUNCH_COMPANIONS_STATUS@@'
if ([string]::IsNullOrWhiteSpace($DefaultsPath)) {
    $DefaultsPath = Join-Path $script:RepoRoot 'config\launch-companions.defaults.json'
}

function Write-LcLog {
    param([string]$Message)
    Write-Host $Message
    try {
        $dir = Split-Path -Parent $script:LogPath
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $script:LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
    }
    catch { }
}

function Test-LcIsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-LcExeFileName {
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name)) -and ($Name -match '^[^\\/:*?"<>|]+\.exe$')
}

function ConvertTo-LcDelay {
    param($Value)
    $n = $script:MaxDelayMs
    if ($null -ne $Value -and "$Value" -ne '') {
        $parsed = 0
        if ([int]::TryParse("$Value", [ref]$parsed)) { $n = $parsed }
    }
    return [Math]::Max(0, [Math]::Min($n, $script:MaxDelayMs))
}

function New-LcRow {
    param([string]$MainExe, [string]$ExeName, [string]$Exe, [string]$SearchDir, $DelayMs)
    return [PSCustomObject]@{
        MainExe   = $MainExe.Trim()
        ExeName   = $ExeName.Trim()
        Exe       = if ($Exe) { $Exe.Trim() } else { '' }
        SearchDir = if ($SearchDir) { $SearchDir.Trim() } else { '' }
        DelayMs   = ConvertTo-LcDelay $DelayMs
        Status    = ''
    }
}

function Get-LcRowKey {
    param($Row)
    return ('{0}|{1}' -f $Row.MainExe, $Row.ExeName).ToLowerInvariant()
}

function Read-LcRows {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return , $rows
    }

    $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return , $rows
    }

    $doc = $raw | ConvertFrom-Json
    if ($null -eq $doc -or $null -eq $doc.companions) {
        return , $rows
    }

    foreach ($prop in $doc.companions.PSObject.Properties) {
        foreach ($entry in @($prop.Value)) {
            if ($null -eq $entry) { continue }
            $exeName = [string]$entry.exeName
            if ([string]::IsNullOrWhiteSpace($exeName) -and $entry.exe) {
                $exeName = [System.IO.Path]::GetFileName([string]$entry.exe)
            }
            if ([string]::IsNullOrWhiteSpace($exeName)) { continue }
            [void]$rows.Add((New-LcRow -MainExe $prop.Name -ExeName $exeName -Exe ([string]$entry.exe) `
                        -SearchDir ([string]$entry.searchDir) -DelayMs $entry.delayMs))
        }
    }
    return , $rows
}

function Set-LcFileAcl {
    param([string]$Path)

    $system = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $admins = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $users = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')

    $sec = New-Object Security.AccessControl.FileSecurity
    $sec.SetAccessRuleProtection($true, $false)
    $sec.SetOwner($admins)
    foreach ($sid in @($system, $admins)) {
        $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'Allow')))
    }
    $sec.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($users, 'ReadAndExecute', 'Allow')))
    [System.IO.File]::SetAccessControl($Path, $sec)
}

function Write-LcRows {
    param([System.Collections.Generic.List[object]]$Rows)

    if (-not (Test-Path -LiteralPath $script:ConfigDir)) {
        New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
    }

    $companions = [ordered]@{}
    $keyByLower = @{}
    foreach ($row in $Rows) {
        $lower = $row.MainExe.ToLowerInvariant()
        if (-not $keyByLower.ContainsKey($lower)) {
            $keyByLower[$lower] = $row.MainExe
            $companions[$row.MainExe] = New-Object System.Collections.Generic.List[object]
        }
        $entry = [ordered]@{ exeName = $row.ExeName }
        if ($row.Exe) { $entry.exe = $row.Exe }
        if ($row.SearchDir) { $entry.searchDir = $row.SearchDir }
        $entry.delayMs = $row.DelayMs
        [void]$companions[$keyByLower[$lower]].Add($entry)
    }

    $out = [ordered]@{}
    foreach ($key in $companions.Keys) {
        $out[$key] = $companions[$key].ToArray()
    }
    $json = ConvertTo-Json -InputObject ([ordered]@{ companions = $out }) -Depth 6

    # Lock the ACL before content lands so a fresh file never carries inherited rights.
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        [System.IO.File]::WriteAllText($script:ConfigPath, '{}', (New-Object System.Text.UTF8Encoding $false))
    }
    Set-LcFileAcl -Path $script:ConfigPath
    [System.IO.File]::WriteAllText($script:ConfigPath, $json, (New-Object System.Text.UTF8Encoding $false))
    Set-LcFileAcl -Path $script:ConfigPath
    Write-LcLog "[OK] Saved $($Rows.Count) companion row(s) to $script:ConfigPath (admin-only ACL)."
}

function Import-LcRowsFromJson {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "SaveJson file not found: $Path"
    }
    # PS 5.1 emits a JSON array as one pipeline object; assign first so @() unrolls it.
    $parsed = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $items = @($parsed)
    $rows = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $main = ([string]$item.mainExe).Trim()
        $exeName = ([string]$item.exeName).Trim()
        if (-not (Test-LcExeFileName $main)) { throw "Invalid main app exe name: '$main' (file name ending in .exe)" }
        if (-not (Test-LcExeFileName $exeName)) { throw "Invalid companion exe name: '$exeName' (file name ending in .exe)" }
        $exe = ([string]$item.exe).Trim()
        if ($exe -and -not [System.IO.Path]::IsPathRooted($exe)) { throw "Companion path must be absolute: '$exe'" }
        $row = New-LcRow -MainExe $main -ExeName $exeName -Exe $exe -SearchDir ([string]$item.searchDir) -DelayMs $item.delayMs
        $key = Get-LcRowKey $row
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [void]$rows.Add($row)
    }
    return , $rows
}

function Add-LcDefaultRows {
    param([System.Collections.Generic.List[object]]$Rows)

    if (-not (Test-Path -LiteralPath $DefaultsPath)) {
        Write-LcLog "[WARN] Defaults file not found: $DefaultsPath"
        return 0
    }
    $doc = Get-Content -LiteralPath $DefaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $existing = @{}
    foreach ($row in $Rows) { $existing[(Get-LcRowKey $row)] = $true }

    $added = 0
    foreach ($item in @($doc.companions)) {
        if ($null -eq $item) { continue }
        $row = New-LcRow -MainExe ([string]$item.mainExe) -ExeName ([string]$item.exeName) -Exe '' -SearchDir '' -DelayMs $item.delayMs
        if (-not (Test-LcExeFileName $row.MainExe) -or -not (Test-LcExeFileName $row.ExeName)) { continue }
        $key = Get-LcRowKey $row
        if ($existing.ContainsKey($key)) { continue }
        $existing[$key] = $true
        [void]$Rows.Add($row)
        $added++
        Write-LcLog "[+] Default companion: $($row.MainExe) -> $($row.ExeName)"
    }
    return $added
}

# --- Path search (Everything via Playnite-Common helpers, folder walk fallback) ---

function Initialize-LcSearch {
    # Playnite-Common.ps1 is dot-sourced at script scope (see Main) so its helpers stay visible here.
    $logAction = { param($Message, $Level) if ($Level -eq 'WARN') { Write-LcLog "[WARN] $Message" } }
    $script:EsReady = $false
    try {
        $script:EsReady = [bool](Ensure-EverythingReady -RepoRoot $script:WatcherRoot -SkipInstall:$NoEverythingInstall -LogAction $logAction)
    }
    catch {
        Write-LcLog "[WARN] Everything check failed: $($_.Exception.Message)"
    }
    $script:EsExe = if ($script:EsReady) { Get-EverythingEsExePath -RepoRoot $script:WatcherRoot } else { $null }
    if ($script:EsReady) {
        Write-LcLog "[*] Search: Everything ($script:EsExe)"
    }
    else {
        Write-LcLog '[*] Search: Everything not reachable; using folder walk.'
    }
}

function Find-LcFiles {
    <# Full paths of files named $Name under $Root (whole index when $Root is empty). #>
    param([string]$Name, [string]$Root = '', [int]$WalkDepth = 8)

    $found = New-Object System.Collections.Generic.List[string]
    if ($Root -and -not (Test-Path -LiteralPath $Root -PathType Container)) {
        return , $found
    }

    if ($script:EsReady) {
        $scanRoot = if ($Root) { Normalize-EverythingSearchPath -Path $Root } else { $null }
        foreach ($query in @($Name, "wfn:$Name", "=$Name")) {
            $search = Invoke-EverythingEsSearchLines -EsExe $script:EsExe -SearchQuery $query -ScanRootFull $scanRoot -MaxResults 100 -TimeoutMs 15000
            if ($search.ExitCode -ne 0) { continue }
            foreach ($line in $search.Lines) {
                $path = ConvertFrom-EverythingSearchOutputLine -Line $line
                if (-not $path) { continue }
                $path = Normalize-EverythingSearchPath -Path $path
                if ([System.IO.Path]::GetFileName($path) -ine $Name) { continue }
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
                if (-not $found.Contains($path)) { [void]$found.Add($path) }
            }
            if ($found.Count -gt 0) { break }
        }
        return , $found
    }

    $roots = if ($Root) {
        @($Root)
    }
    else {
        $excluded = @(Get-ExcludedSystemDriveRoots)
        @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
                Where-Object { $_.Root -match '^[A-Za-z]:\\$' -and ($excluded -notcontains $_.Root) -and
                    ([System.IO.DriveInfo]::new($_.Root).DriveType -eq 'Fixed') } |
                ForEach-Object { $_.Root })
    }
    foreach ($walkRoot in $roots) {
        $hits = @(Find-AllowlistedExesUnderPathWalk -ScanRoot $walkRoot -Allowlist @([PSCustomObject]@{ Exe = $Name }) -MaxDepth $WalkDepth)
        foreach ($hit in $hits) {
            if ($hit.FullPath -and -not $found.Contains($hit.FullPath)) { [void]$found.Add($hit.FullPath) }
        }
    }
    return , $found
}

function Select-LcNewest {
    param([System.Collections.Generic.List[string]]$Paths)
    if ($Paths.Count -eq 0) { return $null }
    return @($Paths | Sort-Object -Property @{ Expression = { (Get-Item -LiteralPath $_).LastWriteTimeUtc } } -Descending)[0]
}

function Get-LcPlayniteGames {
    try {
        $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $script:WatcherRoot
        $installDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
        if (-not $installDir) { return @() }
        return @(Normalize-PlayniteGamesArray -Games (Get-PlayniteGamesWithPlayActions -InstallDir $installDir))
    }
    catch {
        Write-LcLog "[WARN] Playnite library not readable ($($_.Exception.Message)); using Everything only."
        return @()
    }
}

function Resolve-LcMainExePath {
    param([string]$Name, [object[]]$Games)

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($game in $Games) {
        $paths = @()
        if ($game.PrimaryPlayPath) { $paths += [string]$game.PrimaryPlayPath }
        foreach ($action in @($game.PlayActions)) {
            if ($action -and "$($action.Arguments)" -match '--exe\s+"([^"]+)"') { $paths += $Matches[1] }
        }
        if ($game.InstallDirectory) { $paths += (Join-Path ([string]$game.InstallDirectory) $Name) }
        if ($game.PrimaryWorkingDir) { $paths += (Join-Path ([string]$game.PrimaryWorkingDir) $Name) }
        foreach ($p in $paths) {
            if ([System.IO.Path]::GetFileName($p) -ine $Name) { continue }
            if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not $candidates.Contains($p)) { [void]$candidates.Add($p) }
        }
    }
    if ($candidates.Count -gt 0) { return (Select-LcNewest $candidates) }

    return (Select-LcNewest (Find-LcFiles -Name $Name -WalkDepth 6))
}

function Invoke-LcSeed {
    param([System.Collections.Generic.List[object]]$Rows)

    Initialize-LcSearch
    $games = Get-LcPlayniteGames
    $mainCache = @{}
    $found = 0

    foreach ($row in $Rows) {
        if ($MainExe -and $row.MainExe -ine $MainExe) { continue }

        if ($row.SearchDir -and (Test-Path -LiteralPath $row.SearchDir -PathType Container)) {
            $dirHits = Find-LcFiles -Name $row.ExeName -Root $row.SearchDir
            $dirPick = Select-LcNewest $dirHits
            if ($dirPick) {
                $row.Exe = $dirPick
                $row.Status = if ($dirHits.Count -gt 1) { "Multiple (picked newest of $($dirHits.Count))" } else { 'Found' }
                $found++
                Write-LcLog "[FOUND] $($row.MainExe) -> $dirPick ($($row.Status); searchDir $($row.SearchDir))"
                continue
            }
        }

        $mainKey = $row.MainExe.ToLowerInvariant()
        if (-not $mainCache.ContainsKey($mainKey)) {
            $mainCache[$mainKey] = Resolve-LcMainExePath -Name $row.MainExe -Games $games
        }
        $mainPath = $mainCache[$mainKey]

        $hits = New-Object System.Collections.Generic.List[string]
        if ($mainPath) {
            $mainDir = Split-Path -Parent $mainPath
            $hits = Find-LcFiles -Name $row.ExeName -Root $mainDir
            if ($hits.Count -eq 0) {
                $parent = Split-Path -Parent $mainDir
                if ($parent) { $hits = Find-LcFiles -Name $row.ExeName -Root $parent }
            }
        }
        if ($hits.Count -eq 0 -and $script:EsReady) {
            $hits = Find-LcFiles -Name $row.ExeName
        }

        $pick = Select-LcNewest $hits
        if (-not $pick) {
            $row.Status = 'Missing'
            $where = if ($mainPath) { "near $mainPath" } else { "($($row.MainExe) not found either)" }
            Write-LcLog "[MISSING] $($row.MainExe) -> $($row.ExeName) $where"
            continue
        }

        $row.Exe = $pick
        $row.SearchDir = if ($mainPath) { Split-Path -Parent $mainPath } else { Split-Path -Parent $pick }
        $row.Status = if ($hits.Count -gt 1) { "Multiple (picked newest of $($hits.Count))" } else { 'Found' }
        $found++
        Write-LcLog "[FOUND] $($row.MainExe) -> $pick ($($row.Status); searchDir $($row.SearchDir))"
    }
    return $found
}

function Get-LcStatusObjects {
    param([System.Collections.Generic.List[object]]$Rows)

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($row in $Rows) {
        $running = New-Object System.Collections.Generic.List[string]
        try {
            $filterName = $row.ExeName.Replace("'", "''")
            foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='$filterName'" -ErrorAction SilentlyContinue)) {
                $owner = ''
                try {
                    $o = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
                    if ($o.User) { $owner = "$($o.Domain)\$($o.User)" }
                }
                catch { }
                [void]$running.Add(("PID {0} {1} session {2}" -f $proc.ProcessId, $owner, $proc.SessionId).Trim())
            }
        }
        catch { }

        [void]$result.Add([ordered]@{
                mainExe   = $row.MainExe
                exeName   = $row.ExeName
                exe       = $row.Exe
                searchDir = $row.SearchDir
                delayMs   = $row.DelayMs
                exists    = [bool]($row.Exe -and (Test-Path -LiteralPath $row.Exe -PathType Leaf))
                running   = $running.ToArray()
            })
    }
    return , $result
}

# --- Main ---

$writes = $SeedDefaults -or $Seed -or -not [string]::IsNullOrWhiteSpace($SaveJson)
if ($writes -and -not (Test-LcIsAdmin)) {
    throw 'Run as Administrator: launch-companions.json must stay admin-only.'
}

try {
    $rows = Read-LcRows
}
catch {
    if (-not $writes) { throw }
    Write-LcLog "[WARN] Existing $script:ConfigPath is not valid JSON ($($_.Exception.Message)); starting from an empty list."
    $rows = New-Object System.Collections.Generic.List[object]
}

if ($writes) {
    $ops = @()
    if ($SaveJson) { $ops += 'save' }
    if ($SeedDefaults) { $ops += 'defaults' }
    if ($Seed) { $ops += 'seed' }
    Write-LcLog "=== Update-LaunchCompanions ($($ops -join ', ')) ==="
}
if (-not [string]::IsNullOrWhiteSpace($SaveJson)) {
    $rows = Import-LcRowsFromJson -Path $SaveJson
    Write-LcLog "[*] Loaded $($rows.Count) row(s) from the editor."
}
if ($SeedDefaults) {
    [void](Add-LcDefaultRows -Rows $rows)
}
if ($Seed) {
    if ($rows.Count -eq 0) {
        Write-LcLog '[*] No companion rows to seed.'
    }
    else {
        $common = Join-Path $script:WatcherRoot 'Playnite-Common.ps1'
        if (-not (Test-Path -LiteralPath $common)) {
            throw "Playnite-Common.ps1 not found: $common"
        }
        . $common 3>$null
        $ErrorActionPreference = 'Stop'
        $foundCount = Invoke-LcSeed -Rows $rows
        Write-LcLog "[*] Seed: $foundCount of $($rows.Count) row(s) resolved."
    }
}
if ($writes) {
    Write-LcRows -Rows $rows
}

if ($StatusOnly) {
    $status = Get-LcStatusObjects -Rows $rows
    Write-Output ($script:StatusMarker + (ConvertTo-Json -InputObject @($status.ToArray()) -Depth 5 -Compress))
}
elseif (-not $writes) {
    Write-Host "$($rows.Count) companion row(s) in $script:ConfigPath"
    foreach ($row in $rows) {
        Write-Host ("  {0} -> {1}  {2}" -f $row.MainExe, $row.ExeName, $(if ($row.Exe) { $row.Exe } else { '(path not resolved)' }))
    }
}
exit 0
