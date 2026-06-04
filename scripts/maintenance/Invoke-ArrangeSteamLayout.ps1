#Requires -Version 5.1
# Dot-sourced by Arrange-GamesApps.ps1 — reads sync-games-apps-downloaded.txt extract= paths;
# uses type=Steam app extract as Steam root, else auto-detect, else folder picker.

function Write-ArrangeLog {
    param([string]$LogPath, [string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
}

function Normalize-PathKey([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    try { return [System.IO.Path]::GetFullPath($Path).TrimEnd('\').ToUpperInvariant() }
    catch { return $Path.TrimEnd('\').ToUpperInvariant() }
}

function Test-PathEquals {
    param([string]$A, [string]$B)
    $ka = Normalize-PathKey $A
    $kb = Normalize-PathKey $B
    return ($ka -and $kb -and $ka -eq $kb)
}

function Test-DirectoryHasFiles {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return $false }
    return [bool](Get-ChildItem -LiteralPath $Dir -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-IsUnderPath {
    param([string]$Child, [string]$Parent)
    $ck = Normalize-PathKey $Child
    $pk = Normalize-PathKey $Parent
    if (-not $ck -or -not $pk) { return $false }
    return $ck.StartsWith($pk + '\')
}

function Get-RootAppManifestAtExtract {
    param([Parameter(Mandatory)][string]$ExtractPath)
    $files = @(Get-ChildItem -LiteralPath $ExtractPath -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -like 'appmanifest*.acf' -or $_.Name -like 'appmanifest*.txt'
    })
    return ,@($files)
}

function Get-SteamGameLayout {
    param([Parameter(Mandatory)][string]$ExtractPath)
    $commonDir = Join-Path $ExtractPath 'common'
    if (-not (Test-Path -LiteralPath $commonDir -PathType Container)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'INVALID_LAYOUT'; GameFolder = ''; CommonSource = ''; ManifestFile = $null }
    }
    $children = @(Get-ChildItem -LiteralPath $commonDir -Directory -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'NO_GAME_FOLDER'; GameFolder = ''; CommonSource = ''; ManifestFile = $null }
    }
    if ($children.Count -gt 1) {
        return [pscustomobject]@{ Ok = $false; Reason = 'AMBIGUOUS_COMMON'; GameFolder = ''; CommonSource = ''; ManifestFile = $null }
    }
    $gameFolder = $children[0].Name
    $commonSource = $children[0].FullName
    $manifests = @(Get-RootAppManifestAtExtract -ExtractPath $ExtractPath)
    if ($manifests.Count -eq 0) {
        return [pscustomobject]@{ Ok = $false; Reason = 'NO_MANIFEST'; GameFolder = $gameFolder; CommonSource = $commonSource; ManifestFile = $null }
    }
    if ($manifests.Count -gt 1) {
        return [pscustomobject]@{ Ok = $false; Reason = 'AMBIGUOUS_MANIFEST'; GameFolder = $gameFolder; CommonSource = $commonSource; ManifestFile = $null }
    }
    return [pscustomobject]@{
        Ok           = $true
        Reason       = ''
        GameFolder   = $gameFolder
        CommonSource = $commonSource
        ManifestFile = $manifests[0]
    }
}

function Add-SteamRootCandidate {
    param(
        [System.Collections.Generic.List[string]]$List,
        [string]$Path
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-IsSteamClientPath -Path $Path)) { return }
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($List -notcontains $full) { [void]$List.Add($full) }
}

function Get-ManifestSteamRootFromExtracts {
    <#
        Resolve Steam client root from sync-games-apps-downloaded.txt extract= lines (type=Steam app first).
    #>
    param([Parameter(Mandatory)][object[]]$Entries)
    $Entries = ConvertTo-ObjectArray $Entries

    Write-Host 'Manifest extract paths:' -ForegroundColor DarkGray
    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        $type = Get-ManifestEntryType -Entry $e
        if (-not $type) { $type = '(unknown)' }
        $extract = Get-ManifestEntryExtractPath -Entry $e
        Write-Host ("  [{0}] extract={1}" -f $type, $extract) -ForegroundColor DarkGray
    }

    $steamAppEntries = @($Entries | Where-Object { Test-ManifestEntryIsSteamClient $_ })
    if ($steamAppEntries.Count -eq 0) {
        Write-Warn 'No Steam client entry in manifest (type=Steam app or steam.exe under extract=).'
        return $null
    }

    $picked = $steamAppEntries[-1]
    if ($steamAppEntries.Count -gt 1) {
        Write-Warn ('Multiple Steam client entries; using last extract: {0}' -f (Get-ManifestEntryExtractPath -Entry $picked))
    }

    $root = Get-ManifestEntryExtractPath -Entry $picked
    if ([string]::IsNullOrWhiteSpace($root)) { return $null }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Write-Warn "Manifest Steam app extract path not found on disk: $root"
        return $null
    }

    $full = [System.IO.Path]::GetFullPath($root)
    if (Test-IsSteamClientPath -Path $full) {
        Write-Ok "Steam root from manifest extract (validated): $full"
        return $full
    }

    $nested = Find-SteamClientPathUnderDirectory -Root $full
    if ($nested) {
        Write-Ok "Steam root from manifest extract (nested): $nested"
        return $nested
    }

    Write-Ok "Steam root from manifest extract (trusted): $full"
    return $full
}

function Get-SteamFolderPickerInitialPath {
    param([Parameter(Mandatory)][object[]]$Entries)
    $Entries = ConvertTo-ObjectArray $Entries

    $configured = Get-ConfiguredSteamInstallPath
    if ($configured) { return $configured }

    $steamAppEntries = @($Entries | Where-Object { Test-ManifestEntryIsSteamClient $_ })
    if ($steamAppEntries.Count -gt 0) {
        $p = Get-ManifestEntryExtractPath -Entry $steamAppEntries[-1]
        if (-not [string]::IsNullOrWhiteSpace($p)) {
            if (Test-Path -LiteralPath $p -PathType Container) {
                return [System.IO.Path]::GetFullPath($p)
            }
            $parent = Split-Path -Parent $p
            if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
                return [System.IO.Path]::GetFullPath($parent)
            }
            return $p
        }
    }

    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        $p = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if (Test-Path -LiteralPath $p -PathType Container) {
            return [System.IO.Path]::GetFullPath((Split-Path -Parent $p))
        }
    }

    foreach ($candidate in @(Get-SteamInstallCandidatesFromManifest -Entries $Entries)) {
        if ($candidate) { return $candidate }
    }

    $regSteam = Get-SteamInstallPathFromRegistry
    if ($regSteam) { return $regSteam }

    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        $p = Get-ManifestEntryExtractPath -Entry $e
        if (-not [string]::IsNullOrWhiteSpace($p)) { return $p }
    }
    return ''
}

function Pick-SteamClientRootFolder {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [bool]$UseGui = $true
    )

    $initial = Get-SteamFolderPickerInitialPath -Entries $Entries
    Write-Warn 'Could not resolve Steam folder from manifest extract paths.'
    Write-Host ("Suggested folder: $initial") -ForegroundColor Yellow

    if ($UseGui) {
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select the Steam client folder (contains or will contain steamapps).'
        if ($initial -and (Test-Path -LiteralPath $initial -PathType Container)) {
            $dlg.SelectedPath = $initial
        }
        elseif ($initial) {
            $parent = Split-Path -Parent $initial
            if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
                $dlg.SelectedPath = $parent
            }
        }
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($dlg.SelectedPath)) {
            Write-Warn 'Steam folder picker cancelled.'
            return $null
        }
        $picked = [System.IO.Path]::GetFullPath($dlg.SelectedPath.Trim())
        Write-Ok "Steam root (user selected): $picked"
        return $picked
    }

    $raw = Read-Host "Steam client folder path (Enter = $initial)"
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if (-not (Test-Path -LiteralPath $initial -PathType Container)) {
            Write-Warn 'Default manifest path does not exist; cancelled.'
            return $null
        }
        $picked = [System.IO.Path]::GetFullPath($initial)
    }
    else {
        $picked = [System.IO.Path]::GetFullPath($raw.Trim().Trim('"'))
    }
    if (-not (Test-Path -LiteralPath $picked -PathType Container)) {
        Write-Warn "Folder does not exist: $picked"
        return $null
    }
    Write-Ok "Steam root (user entered): $picked"
    return $picked
}

function Resolve-SteamClientRoot {
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [bool]$UseGui = $true
    )
    $Entries = ConvertTo-ObjectArray $Entries

    $configured = Get-ConfiguredSteamInstallPath
    if ($configured -and (Test-IsSteamClientPath -Path $configured)) {
        Write-Ok "Steam root from NEXTGPU_STEAM_INSTALL_PATH: $configured"
        return $configured
    }

    $fromManifest = Get-ManifestSteamRootFromExtracts -Entries $Entries
    if ($fromManifest) { return $fromManifest }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($candidate in @(Get-SteamInstallCandidatesFromManifest -Entries $Entries)) {
        Add-SteamRootCandidate -List $candidates -Path $candidate
    }
    if ($candidates.Count -gt 0) {
        $regSteam = Get-SteamInstallPathFromRegistry
        if ($regSteam -and ($candidates -contains $regSteam)) {
            Write-Ok ("Steam client from registry: $regSteam")
        }
    }

    if ($candidates.Count -eq 0) { return $null }
    if ($candidates.Count -eq 1) { return $candidates[0] }

    Write-Warn 'Multiple Steam client candidates in manifest:'
    for ($i = 0; $i -lt $candidates.Count; $i++) {
        Write-Host ('  [{0}] {1}' -f ($i + 1), $candidates[$i])
    }
    if ($UseGui) {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $pick = [Microsoft.VisualBasic.Interaction]::InputBox(
            'Enter number for Steam client folder:', 'Steam root', '1')
        $n = 0
        if ([int]::TryParse($pick, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
            return $candidates[$n - 1]
        }
    }
    else {
        $raw = Read-Host 'Steam client number'
        $n = 0
        if ([int]::TryParse($raw, [ref]$n) -and $n -ge 1 -and $n -le $candidates.Count) {
            return $candidates[$n - 1]
        }
    }
    return $candidates[-1]
}

function New-SteamArrangePlanRow {
    param(
        [string]$ExtractPath,
        [string]$Action,
        [string]$Reason = '',
        [string]$GameFolder = '',
        [string]$CommonSource = '',
        [string]$CommonDest = '',
        [string]$ManifestSource = '',
        [string]$ManifestDest = ''
    )
    return [pscustomobject]@{
        ExtractPath     = $ExtractPath
        Action          = $Action
        Reason          = $Reason
        GameFolder      = $GameFolder
        CommonSource    = $CommonSource
        CommonDest      = $CommonDest
        ManifestSource  = $ManifestSource
        ManifestDest    = $ManifestDest
        MoveCommon      = $false
        MoveManifest    = $false
    }
}

function Build-SteamArrangePlan {
    param(
        [Parameter(Mandatory)][string]$SteamRoot,
        [Parameter(Mandatory)][object[]]$Entries
    )
    $steamRootFull = [System.IO.Path]::GetFullPath($SteamRoot)
    $steamApps = Join-Path $steamRootFull 'steamapps'
    $commonDestRoot = Join-Path $steamApps 'common'
    $plan = New-Object System.Collections.Generic.List[object]
    $seenGameFolders = @{}

    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        if (Test-ManifestEntryIsSteamClient -Entry $e) { continue }
        $type = Get-ManifestEntryType -Entry $e
        if ($type -ine 'steam') { continue }

        $extract = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }

        if (Test-PathEquals $extract $steamRootFull) {
            [void]$plan.Add((New-SteamArrangePlanRow -ExtractPath $extract -Action 'SKIP' -Reason 'IS_STEAM_ROOT'))
            continue
        }

        if (Test-IsSteamClientPath -Path $extract) {
            [void]$plan.Add((New-SteamArrangePlanRow -ExtractPath $extract -Action 'SKIP' -Reason 'IS_STEAM_CLIENT'))
            continue
        }

        if (-not (Test-Path -LiteralPath $extract -PathType Container)) {
            [void]$plan.Add((New-SteamArrangePlanRow -ExtractPath $extract -Action 'SKIP' -Reason 'SOURCE_MISSING'))
            continue
        }

        $extractFull = [System.IO.Path]::GetFullPath($extract)
        if (Test-IsUnderPath -Child $extractFull -Parent $steamApps) {
            [void]$plan.Add((New-SteamArrangePlanRow -ExtractPath $extract -Action 'SKIP' -Reason 'SKIP_ALREADY_ARRANGED'))
            continue
        }

        $layout = Get-SteamGameLayout -ExtractPath $extractFull
        if (-not $layout.Ok) {
            [void]$plan.Add((New-SteamArrangePlanRow -ExtractPath $extract -Action 'SKIP' -Reason $layout.Reason -GameFolder $layout.GameFolder))
            continue
        }

        $gameFolder = $layout.GameFolder
        if ($seenGameFolders.ContainsKey($gameFolder)) {
            [void]$plan.Add((New-SteamArrangePlanRow -ExtractPath $extract -Action 'SKIP' -Reason 'DUPLICATE_IN_RUN' -GameFolder $gameFolder))
            continue
        }

        $destCommon = Join-Path $commonDestRoot $gameFolder
        $destManifest = Join-Path $steamApps $layout.ManifestFile.Name
        $row = New-SteamArrangePlanRow -ExtractPath $extract -Action 'MOVE' -GameFolder $gameFolder `
            -CommonSource $layout.CommonSource -CommonDest $destCommon `
            -ManifestSource $layout.ManifestFile.FullName -ManifestDest $destManifest

        if (-not (Test-Path -LiteralPath $layout.CommonSource -PathType Container)) {
            $row.Action = 'SKIP'
            $row.Reason = 'SOURCE_MISSING'
            [void]$plan.Add($row)
            continue
        }
        if (-not (Test-Path -LiteralPath $layout.ManifestFile.FullName -PathType Leaf)) {
            $row.Action = 'SKIP'
            $row.Reason = 'SOURCE_MISSING'
            [void]$plan.Add($row)
            continue
        }

        $commonExists = Test-Path -LiteralPath $destCommon -PathType Container
        $commonHasFiles = $commonExists -and (Test-DirectoryHasFiles -Dir $destCommon)
        $manifestExists = Test-Path -LiteralPath $destManifest -PathType Leaf

        if ($commonHasFiles) {
            $row.Action = 'SKIP'
            $row.Reason = 'SKIP_EXISTS common'
            [void]$plan.Add($row)
            continue
        }

        if ($commonExists -and -not $commonHasFiles) {
            $row.MoveCommon = $true
            $row.Reason = 'MOVE_INTO_EMPTY'
        }
        else {
            $row.MoveCommon = $true
            $row.Reason = 'MOVE'
        }

        if ($manifestExists) {
            $row.MoveManifest = $false
            if ($row.MoveCommon) {
                $row.Reason = 'MOVE_COMMON_ONLY'
            }
            else {
                $row.Action = 'SKIP'
                $row.Reason = 'SKIP_EXISTS acf'
            }
        }
        else {
            $row.MoveManifest = $true
        }

        if (-not $row.MoveCommon -and -not $row.MoveManifest) {
            $row.Action = 'SKIP'
            if (-not $row.Reason) { $row.Reason = 'SKIP_EXISTS' }
        }
        else {
            [void]$seenGameFolders.Add($gameFolder, $true)
        }

        [void]$plan.Add($row)
    }

    return ,@{
        SteamRoot      = $steamRootFull
        SteamApps      = $steamApps
        CommonDestRoot = $commonDestRoot
        Rows           = @($plan.ToArray())
    }
}

function Confirm-SteamArrangePlan {
    param(
        [Parameter(Mandatory)][object[]]$MoveRows,
        [bool]$UseGui = $true
    )
    if ($MoveRows.Count -eq 0) {
        Write-Host 'Nothing to arrange (all entries skipped).' -ForegroundColor Yellow
        return $false
    }

    Write-Host ''
    Write-Host 'Planned moves:' -ForegroundColor Cyan
    foreach ($r in $MoveRows) {
        if ($r.MoveCommon) {
            Write-Host ('  common: {0} -> {1}' -f $r.CommonSource, $r.CommonDest) -ForegroundColor DarkGray
        }
        if ($r.MoveManifest) {
            Write-Host ('  manifest: {0} -> {1}' -f $r.ManifestSource, $r.ManifestDest) -ForegroundColor DarkGray
        }
        if ($r.Reason -and $r.Reason -notmatch '^MOVE') {
            Write-Host ('    note: {0}' -f $r.Reason) -ForegroundColor DarkYellow
        }
    }

    $msg = ('Move {0} game(s) into steamapps?' -f $MoveRows.Count)
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        return ([System.Windows.Forms.MessageBox]::Show($msg, 'Arrange Steam', 'YesNo', 'Question') -eq 'Yes')
    }
    $ans = Read-Host "$msg [y/N]"
    return ($ans -match '^(y|yes)$')
}

function Invoke-SteamArrangeExecution {
    param(
        [Parameter(Mandatory)][object[]]$MoveRows,
        [Parameter(Mandatory)][string]$LogPath
    )
    $moved = 0
    $skipped = 0
    $errors = 0

    foreach ($r in $MoveRows) {
        $ok = $true
        try {
            if ($r.MoveCommon) {
                $destParent = Split-Path -Parent $r.CommonDest
                if (-not (Test-Path -LiteralPath $destParent)) {
                    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
                }
                if ((Test-Path -LiteralPath $r.CommonDest -PathType Container) -and -not (Test-DirectoryHasFiles -Dir $r.CommonDest)) {
                    Remove-Item -LiteralPath $r.CommonDest -Recurse -Force -ErrorAction SilentlyContinue
                }
                Move-Item -LiteralPath $r.CommonSource -Destination $r.CommonDest -Force -ErrorAction Stop
                Write-ArrangeLog -LogPath $LogPath -Message ("MOVE common {0} -> {1}" -f $r.GameFolder, $r.CommonDest)
            }
            if ($r.MoveManifest) {
                $destParent = Split-Path -Parent $r.ManifestDest
                if (-not (Test-Path -LiteralPath $destParent)) {
                    New-Item -ItemType Directory -Path $destParent -Force | Out-Null
                }
                Move-Item -LiteralPath $r.ManifestSource -Destination $r.ManifestDest -Force -ErrorAction Stop
                Write-ArrangeLog -LogPath $LogPath -Message ("MOVE manifest {0} -> {1}" -f $r.ManifestSource, $r.ManifestDest)
            }
            if ($r.MoveCommon -or $r.MoveManifest) { $moved++ }
        }
        catch {
            $ok = $false
            $errors++
            Write-ArrangeLog -LogPath $LogPath -Message ("ERROR {0}: {1}" -f $r.ExtractPath, $_.Exception.Message)
            Write-Host ("[FAIL] {0}: {1}" -f $r.ExtractPath, $_.Exception.Message) -ForegroundColor Red
            if ($_.Exception.Message -match 'being used|another process') {
                Write-Warn 'Close Steam and retry if files are locked.'
            }
        }

        if ($r.MoveCommon -and $ok) {
            $extractCommonDir = Join-Path $r.ExtractPath 'common'
            if ((Test-Path -LiteralPath $extractCommonDir) -and -not (Test-DirectoryHasFiles -Dir $extractCommonDir)) {
                Remove-Item -LiteralPath $extractCommonDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return [pscustomobject]@{ Moved = $moved; Errors = $errors }
}

function Invoke-ArrangeSteamLayout {
    param([switch]$NoGui)

    $UseGui = -not $NoGui.IsPresent
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName Microsoft.VisualBasic
    }

    $logPath = Get-ArrangeGamesAppsLogPath
    Write-ArrangeLog -LogPath $logPath -Message '=== Arrange Steam layout started ==='

    $manifestPath = Get-ResolvedDownloadManifestPath
    Write-Host "Manifest: $manifestPath" -ForegroundColor Cyan
    Write-ArrangeLog -LogPath $logPath -Message "Manifest: $manifestPath"

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath. Run Sync Game/Apps Officially first."
    }

    $entries = ConvertTo-ObjectArray (Read-DownloadManifestEntries -ManifestPath $manifestPath)
    if ($entries.Count -eq 0) {
        throw 'No entries in download manifest.'
    }

    $steamRoot = Resolve-SteamClientRoot -Entries $entries -UseGui:$UseGui
    if (-not $steamRoot) {
        $steamRoot = Pick-SteamClientRootFolder -Entries $entries -UseGui:$UseGui
    }
    if (-not $steamRoot) {
        Write-Warn 'No Steam client folder selected. Arrange cancelled.'
        Write-ArrangeLog -LogPath $logPath -Message 'Cancelled: no Steam root.'
        return 0
    }

    $steamRoot = [System.IO.Path]::GetFullPath($steamRoot)
    Write-Host "Steam root: $steamRoot" -ForegroundColor Green
    Write-ArrangeLog -LogPath $logPath -Message "Steam root: $steamRoot"

    $steamApps = Join-Path $steamRoot 'steamapps'
    if (Test-Path -LiteralPath $steamApps -PathType Leaf) {
        throw "steamapps path is a file, not a folder: $steamApps"
    }

    $createdSteamApps = $false
    if (-not (Test-Path -LiteralPath $steamApps)) {
        New-Item -ItemType Directory -Path $steamApps -Force | Out-Null
        $createdSteamApps = $true
        Write-ArrangeLog -LogPath $logPath -Message "Created: $steamApps"
    }
    $commonRoot = Join-Path $steamApps 'common'
    if (-not (Test-Path -LiteralPath $commonRoot)) {
        New-Item -ItemType Directory -Path $commonRoot -Force | Out-Null
        Write-ArrangeLog -LogPath $logPath -Message "Created: $commonRoot"
    }

    $built = Build-SteamArrangePlan -SteamRoot $steamRoot -Entries $entries
    $allRows = @($built.Rows)
    $skipRows = @($allRows | Where-Object { $_.Action -eq 'SKIP' })
    $moveRows = @($allRows | Where-Object { $_.Action -eq 'MOVE' -and ($_.MoveCommon -or $_.MoveManifest) })

    foreach ($s in $skipRows) {
        Write-ArrangeLog -LogPath $logPath -Message ("SKIP {0} | {1} | {2}" -f $s.ExtractPath, $s.Reason, $s.GameFolder)
        Write-Host ("[SKIP] {0} ({1})" -f $s.ExtractPath, $s.Reason) -ForegroundColor Yellow
    }

    if (-not (Confirm-SteamArrangePlan -MoveRows $moveRows -UseGui:$UseGui)) {
        Write-ArrangeLog -LogPath $logPath -Message 'User cancelled.'
        return 0
    }

    $result = Invoke-SteamArrangeExecution -MoveRows $moveRows -LogPath $logPath
    Write-Host ''
    Write-Host ("Done. Moved: {0}, Errors: {1}, Skipped: {2}" -f $result.Moved, $result.Errors, $skipRows.Count) -ForegroundColor Cyan
    Write-ArrangeLog -LogPath $logPath -Message ("=== Finished moved={0} errors={1} skipped={2} ===" -f $result.Moved, $result.Errors, $skipRows.Count)

    if ($UseGui) {
        [void][System.Windows.Forms.MessageBox]::Show(
            ("Moved: {0}`nSkipped: {1}`nErrors: {2}`n`nLog: {3}" -f $result.Moved, $skipRows.Count, $result.Errors, $logPath),
            'Arrange Steam', 'OK', $(if ($result.Errors -gt 0) { 'Warning' } else { 'Information' }))
    }

    if ($result.Errors -gt 0) { return 1 }
    return 0
}
