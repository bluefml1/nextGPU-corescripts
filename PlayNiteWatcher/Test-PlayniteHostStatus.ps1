#Requires -Version 5.1
<#
.SYNOPSIS
    Verify PlayNite host readiness for Moonlight streaming. Outputs JSON for NextGPU UI.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Playnite-Common.ps1')

function New-StatusCheck {
    param(
        [string]$Id,
        [string]$Name,
        [ValidateSet('Pass', 'Fail', 'Warn', 'Skip')]
        [string]$Status,
        [string]$Detail = '',
        [string]$FixAction = '',
        [string]$FixLabel = '',
        [bool]$Required = $true
    )
    return [PSCustomObject]@{
        id        = $Id
        name      = $Name
        status    = $Status
        detail    = $Detail
        fixAction = $FixAction
        fixLabel  = $FixLabel
        required  = $Required
    }
}

function Get-SteamManifestCount {
    param([string]$SteamPath)
    if ([string]::IsNullOrWhiteSpace($SteamPath)) { return 0 }
    $steamApps = Join-Path $SteamPath 'steamapps'
    if (-not (Test-Path -LiteralPath $steamApps)) { return 0 }
    return @(Get-ChildItem -LiteralPath $steamApps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue).Count
}

function Get-EpicManifestCount {
    $manifestDir = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (-not (Test-Path -LiteralPath $manifestDir)) { return 0 }
    return @(Get-ChildItem -LiteralPath $manifestDir -Filter '*.item' -File -ErrorAction SilentlyContinue).Count
}

function Get-AllowlistDesktopMatchCount {
    param(
        [string]$InstallDir,
        [array]$Allowlist
    )
    if ([string]::IsNullOrWhiteSpace($InstallDir) -or -not $Allowlist -or $Allowlist.Count -eq 0) {
        return 0
    }
    try {
        $games = Get-PlayniteGameRecordsFromLiteDb -InstallDir $InstallDir
    }
    catch {
        return 0
    }
    $matched = 0
    foreach ($entry in $Allowlist) {
        $exeKey = $entry.Exe.ToLowerInvariant()
        foreach ($game in $games) {
            $path = if ($game.InstallDirectory) { $game.InstallDirectory.ToString() } else { '' }
            $name = if ($game.Name) { $game.Name.ToString() } else { '' }
            if ($path -like "*$exeKey" -or $name -like "*$([System.IO.Path]::GetFileNameWithoutExtension($entry.Exe))*") {
                $matched++
                break
            }
        }
    }
    return $matched
}

function Test-LogContainsImportFinished {
    param([string[]]$LogPaths)
    $patterns = @(
        'Steam library import finished',
        'Steam library update finished',
        'Epic library import finished',
        'Epic library update finished'
    )
    foreach ($log in $LogPaths) {
        if (-not (Test-Path -LiteralPath $log)) { continue }
        $tail = Get-Content -LiteralPath $log -Tail 400 -ErrorAction SilentlyContinue
        foreach ($line in $tail) {
            foreach ($pat in $patterns) {
                if ($line -like "*$pat*") { return $true }
            }
        }
    }
    return $false
}

function Test-IsPlayniteManagedSunshineApp {
    param($App)
    if ($App.'playnite-id') { return $true }
    if ($App.'image-path' -and ($App.'image-path' -match 'Apps\\')) { return $true }
    if ($App.cmd -like '*PlayniteWatcher*' -or $App.cmd -like '*Playnite.DesktopApp*') { return $true }
    if ($App.detached -like '*playnite*' -or $App.detached -like '*Playnite*') { return $true }
    if ($App.'prep-cmd') {
        foreach ($prep in @($App.'prep-cmd')) {
            if ($prep.undo -like '*eventLogs.ps1*') { return $true }
        }
    }
    return $false
}

function Get-SunshineConfigDir {
    return 'C:\Program Files\Sunshine\config'
}

$checks = New-Object System.Collections.Generic.List[object]
$installDir = $null
$steamResolved = Resolve-PlayniteSteamInstallPath -WatcherRoot $scriptRoot
$steamPath = if ($steamResolved) { $steamResolved.Path } else { $null }
$steamSource = if ($steamResolved) { $steamResolved.Source } else { '' }
$steamManifestCount = Get-SteamManifestCount -SteamPath $steamPath
$stats = @{ TotalGames = 0; SteamGames = 0; EpicGames = 0; DbExists = $false }

try {
    $savedPath = Read-SavedPlayniteInstallPath -RepoRoot $scriptRoot
    if (-not [string]::IsNullOrWhiteSpace($savedPath)) {
        $installDir = Resolve-PlayniteInstallDir -PreferredDir $savedPath
    }
}
catch { }

# P1
if (-not [string]::IsNullOrWhiteSpace($installDir)) {
    [void]$checks.Add((New-StatusCheck -Id 'P1' -Name 'Install path configured' -Status 'Pass' -Detail $installDir))
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'P1' -Name 'Install path configured' -Status 'Fail' -Detail 'PlayniteInstall.path missing' -FixAction 'FullSetup' -FixLabel 'Run Full PlayNite Setup'))
}

# P2
if ($installDir -and (Test-PlayniteInstalledAt -InstallDir $installDir)) {
    [void]$checks.Add((New-StatusCheck -Id 'P2' -Name 'Playnite executable' -Status 'Pass' -Detail (Join-Path $installDir 'Playnite.DesktopApp.exe')))
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'P2' -Name 'Playnite executable' -Status 'Fail' -Detail 'Playnite.DesktopApp.exe not found' -FixAction 'FullSetup' -FixLabel 'Run Full PlayNite Setup'))
}

# P3
if ($installDir -and (Test-PlaynitePortableLayout -InstallDir $installDir)) {
    [void]$checks.Add((New-StatusCheck -Id 'P3' -Name 'Portable layout' -Status 'Pass' -Detail 'No installer artifacts'))
}
elseif ($installDir) {
    [void]$checks.Add((New-StatusCheck -Id 'P3' -Name 'Portable layout' -Status 'Fail' -Detail 'unins000.exe or invalid layout' -FixAction 'FullSetup' -FixLabel 'Run Full PlayNite Setup'))
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'P3' -Name 'Portable layout' -Status 'Fail' -Detail 'Install path unknown' -FixAction 'FullSetup' -FixLabel 'Run Full PlayNite Setup'))
}

# P7 — rental ACL on portable install folder (BUILTIN\Users Modify for nextGPU)
if ($installDir) {
    $aclStatus = Get-PlayniteRentalAclStatus -InstallDir $installDir
    if ($aclStatus.Granted) {
        $p7Detail = $aclStatus.Detail
        if (-not $aclStatus.CurrentWrite) {
            $p7Detail += ' (current user cannot write; re-run grant elevated if needed)'
        }
        [void]$checks.Add((New-StatusCheck -Id 'P7' -Name 'Rental write access' -Status 'Pass' -Detail $p7Detail))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'P7' -Name 'Rental write access' -Status 'Fail' -Detail $aclStatus.Detail -FixAction 'GrantPlayniteRentalAccess' -FixLabel 'Grant Playnite rental access'))
    }
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'P7' -Name 'Rental write access' -Status 'Fail' -Detail 'Install path unknown' -FixAction 'GrantPlayniteRentalAccess' -FixLabel 'Grant Playnite rental access'))
}

# P4/P5 + stats
if ($installDir) {
    try {
        $stats = Get-PlayniteLibraryGameStats -InstallDir $installDir
    }
    catch { }

    if ($stats.DbExists -and (Test-PlayniteLiteDbDatabase -Path (Get-PlayniteLibraryGamesDbPath -InstallDir $installDir))) {
        [void]$checks.Add((New-StatusCheck -Id 'P4' -Name 'Library database' -Status 'Pass' -Detail 'games.db valid LiteDB'))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'P4' -Name 'Library database' -Status 'Fail' -Detail 'games.db missing or invalid' -FixAction 'RerunSetupSkipInstall' -FixLabel 'Re-run Setup (Skip Install)'))
    }

    if ($stats.TotalGames -ge 1) {
        [void]$checks.Add((New-StatusCheck -Id 'P5' -Name 'Library not empty' -Status 'Pass' -Detail "$($stats.TotalGames) total games"))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'P5' -Name 'Library not empty' -Status 'Fail' -Detail '0 games in games.db' -FixAction 'UpdateLibraries' -FixLabel 'Update Libraries'))
    }
}

# L* Steam/Epic
if ($steamPath) {
    $steamDetail = if ($steamSource) { "$steamSource`: $steamPath" } else { $steamPath }
    [void]$checks.Add((New-StatusCheck -Id 'L1' -Name 'Steam client detected' -Status 'Pass' -Detail $steamDetail))
    if ($steamManifestCount -ge 1) {
        [void]$checks.Add((New-StatusCheck -Id 'L2' -Name 'Steam games on disk' -Status 'Pass' -Detail "$steamManifestCount appmanifest files"))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'L2' -Name 'Steam games on disk' -Status 'Fail' -Detail '0 appmanifest files' -FixAction 'UpdateLibraries' -FixLabel 'Update Libraries'))
    }

    if ($steamManifestCount -ge 1) {
        if ($stats.SteamGames -ge 1) {
            [void]$checks.Add((New-StatusCheck -Id 'L3' -Name 'Steam games stored in Playnite' -Status 'Pass' -Detail "$($stats.SteamGames) Steam games in games.db"))
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'L3' -Name 'Steam games stored in Playnite' -Status 'Fail' -Detail "0 Steam games in games.db ($steamManifestCount on disk)" -FixAction 'UpdateLibraries' -FixLabel 'Update Libraries'))
        }

        $logOk = Test-LogContainsImportFinished -LogPaths @(
            (Join-Path $scriptRoot 'Update-PlayniteLibraries.log'),
            (Join-Path $scriptRoot 'Setup-PlayniteSteam.log')
        )
        if ($logOk -or $stats.SteamGames -ge 1) {
            [void]$checks.Add((New-StatusCheck -Id 'L4' -Name 'Library scan completed' -Status 'Pass' -Detail 'Import finished in log or Steam games present'))
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'L4' -Name 'Library scan completed' -Status 'Fail' -Detail 'No import-finished line in logs' -FixAction 'UpdateLibraries' -FixLabel 'Update Libraries'))
        }

        if ($stats.SteamGames -ge 1 -and $stats.SteamGames -le $steamManifestCount) {
            [void]$checks.Add((New-StatusCheck -Id 'L7' -Name 'Scan vs storage alignment' -Status 'Pass' -Detail "$($stats.SteamGames) Playnite / $steamManifestCount disk"))
        }
        elseif ($stats.SteamGames -lt 1) {
            [void]$checks.Add((New-StatusCheck -Id 'L7' -Name 'Scan vs storage alignment' -Status 'Fail' -Detail 'No Steam games in Playnite' -FixAction 'UpdateLibraries' -FixLabel 'Update Libraries'))
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'L7' -Name 'Scan vs storage alignment' -Status 'Warn' -Detail "$($stats.SteamGames) Playnite vs $steamManifestCount disk" -Required $false))
        }
    }
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'L1' -Name 'Steam client detected' -Status 'Skip' -Detail 'Not on machine or in R2 manifest (run Sync Game/Apps Officially first)' -Required $false))
}

$epicManifestCount = Get-EpicManifestCount
if ($epicManifestCount -ge 1) {
    [void]$checks.Add((New-StatusCheck -Id 'L5' -Name 'Epic games on disk' -Status 'Pass' -Detail "$epicManifestCount Epic manifest(s)" -Required $false))
    if ($stats.EpicGames -ge 1) {
        [void]$checks.Add((New-StatusCheck -Id 'L6' -Name 'Epic games stored in Playnite' -Status 'Pass' -Detail "$($stats.EpicGames) Epic games in games.db" -Required $false))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'L6' -Name 'Epic games stored in Playnite' -Status 'Fail' -Detail "0 Epic games in games.db ($epicManifestCount on disk)" -FixAction 'UpdateLibraries' -FixLabel 'Update Libraries' -Required $false))
    }
}

# Allowlist A*
$allowPath = Get-DesktopAppAllowlistPath -RepoRoot $scriptRoot
if (Test-Path -LiteralPath $allowPath) {
    [void]$checks.Add((New-StatusCheck -Id 'A1' -Name 'Allowlist file exists' -Status 'Pass' -Detail $allowPath -Required $false))
    try {
        $prevWarn = $WarningPreference
        $WarningPreference = 'SilentlyContinue'
        try {
            $allow = Get-DesktopAppAllowlist -RepoRoot $scriptRoot
        }
        finally {
            $WarningPreference = $prevWarn
        }
        [void]$checks.Add((New-StatusCheck -Id 'A2' -Name 'Allowlist valid' -Status 'Pass' -Detail "$($allow.Count) entries" -Required $false))
        if ($allow.Count -ge 1) {
            [void]$checks.Add((New-StatusCheck -Id 'A3' -Name 'Allowlist has entries' -Status 'Pass' -Detail "$($allow.Count) apps" -Required $false))
            if ($installDir) {
                $desktopMatches = Get-AllowlistDesktopMatchCount -InstallDir $installDir -Allowlist $allow
                if ($desktopMatches -ge 1) {
                    [void]$checks.Add((New-StatusCheck -Id 'A4' -Name 'Desktop games in library' -Status 'Pass' -Detail "$desktopMatches of $($allow.Count) allowlisted exes matched" -Required $false))
                }
                else {
                    [void]$checks.Add((New-StatusCheck -Id 'A4' -Name 'Desktop games in library' -Status 'Warn' -Detail "0 of $($allow.Count) allowlisted exes matched" -FixAction 'ImportDesktopApps' -FixLabel 'Import Desktop Apps' -Required $false))
                }
            }
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'A3' -Name 'Allowlist has entries' -Status 'Warn' -Detail '0 apps' -FixAction 'AddAllowlist' -FixLabel 'Add to Allowlist' -Required $false))
        }
    }
    catch {
        [void]$checks.Add((New-StatusCheck -Id 'A2' -Name 'Allowlist valid' -Status 'Warn' -Detail $_.Exception.Message -FixAction 'OpenAllowlistNotepad' -FixLabel 'Open Allowlist in Notepad' -Required $false))
    }
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'A1' -Name 'Allowlist file exists' -Status 'Warn' -Detail 'Missing allowlist JSON' -FixAction 'AddAllowlist' -FixLabel 'Add to Allowlist' -Required $false))
}

# Sunshine S* — skip S1/S2: gpu-sunshine is demand-start; Sunshine runs in-session (not required here)
$sunshineConfig = Get-SunshineConfigDir
[void]$checks.Add((New-StatusCheck -Id 'S1' -Name 'Sunshine service' -Status 'Skip' -Detail 'Not verified (in-session Sunshine; gpu-sunshine is demand-start only)' -Required $false))
[void]$checks.Add((New-StatusCheck -Id 'S2' -Name 'Sunshine HTTP' -Status 'Skip' -Detail 'Not verified (start Sunshine in session when streaming)' -Required $false))

$appsJson = Join-Path $sunshineConfig 'apps.json'
if (Test-Path -LiteralPath $appsJson) {
    [void]$checks.Add((New-StatusCheck -Id 'S3' -Name 'apps.json exists' -Status 'Pass' -Detail $appsJson))
    try {
        $json = Get-Content -LiteralPath $appsJson -Raw -Encoding UTF8 | ConvertFrom-Json
        $managed = @($json.apps | Where-Object { Test-IsPlayniteManagedSunshineApp $_ }).Count
        if ($managed -ge 1) {
            [void]$checks.Add((New-StatusCheck -Id 'S4' -Name 'Playnite apps exported' -Status 'Pass' -Detail "$managed Playnite-managed apps"))
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'S4' -Name 'Playnite apps exported' -Status 'Fail' -Detail '0 Playnite apps in apps.json' -FixAction 'ExportSunshine' -FixLabel 'Export to Sunshine'))
        }

        $prepCmdCount = 0
        foreach ($app in @($json.apps)) {
            if (-not $app.'prep-cmd') { continue }
            foreach ($prep in @($app.'prep-cmd')) {
                if ($prep.undo -like '*eventLogs.ps1*') {
                    $prepCmdCount++
                    break
                }
            }
        }
        if ($prepCmdCount -ge 1) {
            [void]$checks.Add((New-StatusCheck -Id 'W2' -Name 'Per-app prep-cmd' -Status 'Pass' -Detail "$prepCmdCount app(s) reference eventLogs.ps1"))
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'W2' -Name 'Per-app prep-cmd' -Status 'Fail' -Detail 'No eventLogs.ps1 prep-cmd on exported apps' -FixAction 'InstallWatcher' -FixLabel 'Install PlayNiteWatcher'))
        }

        $fsUuid = '14D9821B-7EA2-48C2-9AF7-970608282F93'
        $hasFs = @($json.apps | Where-Object { $_.uuid -eq $fsUuid -or $_.detached -like '*FullscreenApp*' }).Count -ge 1
        if ($hasFs) {
            [void]$checks.Add((New-StatusCheck -Id 'S6' -Name 'FullScreen app entry' -Status 'Pass' -Detail 'Playnite Fullscreen present'))
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'S6' -Name 'FullScreen app entry' -Status 'Fail' -Detail 'Missing Fullscreen entry' -FixAction 'InstallWatcher' -FixLabel 'Install PlayNiteWatcher'))
        }
    }
    catch {
        [void]$checks.Add((New-StatusCheck -Id 'S4' -Name 'Playnite apps exported' -Status 'Fail' -Detail $_.Exception.Message -FixAction 'ExportSunshine' -FixLabel 'Export to Sunshine'))
    }
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'S3' -Name 'apps.json exists' -Status 'Fail' -Detail 'apps.json missing' -FixAction 'ExportSunshine' -FixLabel 'Export to Sunshine'))
}

$resolvedTxt = Join-Path $sunshineConfig 'resolved-appids.txt'
if (Test-Path -LiteralPath $resolvedTxt) {
    [void]$checks.Add((New-StatusCheck -Id 'S5' -Name 'resolved-appids.txt' -Status 'Pass' -Detail $resolvedTxt))
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'S5' -Name 'resolved-appids.txt' -Status 'Fail' -Detail 'File missing' -FixAction 'ExportSunshine' -FixLabel 'Export to Sunshine'))
}

# Watcher W*
$eventLogs = 'C:\Program Files\Sunshine\scripts\eventLogs.ps1'
if (Test-Path -LiteralPath $eventLogs) {
    [void]$checks.Add((New-StatusCheck -Id 'W1' -Name 'eventLogs.ps1' -Status 'Pass' -Detail $eventLogs))
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'W1' -Name 'eventLogs.ps1' -Status 'Fail' -Detail 'Missing eventLogs.ps1' -FixAction 'InstallWatcher' -FixLabel 'Install PlayNiteWatcher'))
}

$sunshineConf = Join-Path $sunshineConfig 'sunshine.conf'
if (Test-Path -LiteralPath $sunshineConf) {
    $confText = Get-Content -LiteralPath $sunshineConf -Raw -ErrorAction SilentlyContinue
    if ($confText -like '*PlayNiteWatcher-EndScript.ps1*') {
        [void]$checks.Add((New-StatusCheck -Id 'W3' -Name 'Global end script' -Status 'Pass' -Detail 'global_prep_cmd configured'))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'W3' -Name 'Global end script' -Status 'Fail' -Detail 'EndScript not in sunshine.conf' -FixAction 'InstallWatcher' -FixLabel 'Install PlayNiteWatcher'))
    }
}

if (Test-Path -LiteralPath (Join-Path $scriptRoot 'PlayniteWatcher.ps1')) {
    [void]$checks.Add((New-StatusCheck -Id 'W4' -Name 'Watcher scripts on disk' -Status 'Pass' -Detail $scriptRoot))
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'W4' -Name 'Watcher scripts on disk' -Status 'Fail' -Detail 'Repo scripts missing' -FixAction 'InstallWatcher' -FixLabel 'Install PlayNiteWatcher'))
}

# Optional O*
if (Test-EverythingReady -RepoRoot $scriptRoot) {
    [void]$checks.Add((New-StatusCheck -Id 'O1' -Name 'Everything available' -Status 'Pass' -Detail 'es.exe IPC reachable' -Required $false))
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'O1' -Name 'Everything available' -Status 'Warn' -Detail 'es.exe not reachable' -FixAction 'ImportDesktopApps' -FixLabel 'Import Desktop Apps' -Required $false))
}

# T1 — Playnite logon scheduled task
$playniteLogonTaskName = 'nextGPU-PlayniteLogon'
if (-not [string]::IsNullOrWhiteSpace($installDir)) {
    $expectedExe = Join-Path $installDir 'Playnite.DesktopApp.exe'
    $task = Get-ScheduledTask -TaskName $playniteLogonTaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        [void]$checks.Add((New-StatusCheck -Id 'T1' -Name 'Playnite logon task' -Status 'Fail' -Detail "Scheduled task '$playniteLogonTaskName' not registered" -FixAction 'RegisterPlayniteLogonTask' -FixLabel 'Register Playnite Logon Task'))
    }
    elseif (-not $task.Settings.Enabled) {
        [void]$checks.Add((New-StatusCheck -Id 'T1' -Name 'Playnite logon task' -Status 'Fail' -Detail "Task '$playniteLogonTaskName' is disabled" -FixAction 'RegisterPlayniteLogonTask' -FixLabel 'Register Playnite Logon Task'))
    }
    else {
        $actionPaths = @($task.Actions | ForEach-Object { $_.Execute }) -join ';'
        if ($actionPaths -like "*Playnite.DesktopApp.exe*") {
            $state = if ($task.State) { $task.State.ToString() } else { 'Ready' }
            [void]$checks.Add((New-StatusCheck -Id 'T1' -Name 'Playnite logon task' -Status 'Pass' -Detail "$playniteLogonTaskName ($state) -> $expectedExe"))
        }
        else {
            [void]$checks.Add((New-StatusCheck -Id 'T1' -Name 'Playnite logon task' -Status 'Fail' -Detail "Task action does not target Playnite.DesktopApp.exe (got: $actionPaths)" -FixAction 'RegisterPlayniteLogonTask' -FixLabel 'Register Playnite Logon Task'))
        }
    }
}
else {
    [void]$checks.Add((New-StatusCheck -Id 'T1' -Name 'Playnite logon task' -Status 'Skip' -Detail 'Install path unknown' -Required $false))
}

$setupLog = Join-Path $scriptRoot 'Setup-PlayniteSteam.log'
if (Test-Path -LiteralPath $setupLog) {
    $hasError = Select-String -LiteralPath $setupLog -Pattern '\[ERROR\]' -Quiet -ErrorAction SilentlyContinue
    if (-not $hasError) {
        [void]$checks.Add((New-StatusCheck -Id 'O2' -Name 'Recent setup log clean' -Status 'Pass' -Detail 'No [ERROR] in Setup-PlayniteSteam.log' -Required $false))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'O2' -Name 'Recent setup log clean' -Status 'Warn' -Detail '[ERROR] found in setup log' -FixAction 'OpenSetupLog' -FixLabel 'Open Setup Log' -Required $false))
    }
}

if ($installDir) {
    $steamExt = Test-PlayniteLibraryExtensionInstalled -InstallDir $installDir -ExtensionId 'Crc32_FolderExtension' -PluginId $script:PlayniteSteamPluginId
    $epicExt = Test-PlayniteLibraryExtensionInstalled -InstallDir $installDir -ExtensionId 'Crc32_FolderExtension_Epic' -PluginId $script:PlayniteEpicPluginId
    if ($steamExt -and $epicExt) {
        [void]$checks.Add((New-StatusCheck -Id 'O3' -Name 'Steam/Epic extensions' -Status 'Pass' -Detail 'Steam and Epic .pext installed' -Required $false))
    }
    else {
        [void]$checks.Add((New-StatusCheck -Id 'O3' -Name 'Steam/Epic extensions' -Status 'Warn' -Detail "Steam=$steamExt Epic=$epicExt" -FixAction 'RerunSetupSkipInstall' -FixLabel 'Re-run Setup (Skip Install)' -Required $false))
    }
}

$requiredFailed = @($checks | Where-Object { $_.required -and $_.status -eq 'Fail' }).Count
$warnings = @($checks | Where-Object { $_.status -eq 'Warn' }).Count
$overall = if ($requiredFailed -gt 0) { 'NotReady' } elseif ($warnings -gt 0) { 'Degraded' } else { 'Healthy' }

$result = [PSCustomObject]@{
    overall        = $overall
    requiredFailed = $requiredFailed
    warnings       = $warnings
    checks         = $checks
}
$json = $result | ConvertTo-Json -Depth 6 -Compress
[Console]::Out.WriteLine($json)
