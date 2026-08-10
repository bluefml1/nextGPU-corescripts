#Requires -Version 5.1
<#
.SYNOPSIS
  Rewrite Playnite play actions so Steam + Admin-marked Desktop games elevate via NextGPUService.

.DESCRIPTION
  Deploys NextGPU-PlayElevated.ps1 to %ProgramData%\nextGPU\scripts\, then updates games.db:

  - Steam (PluginId CB91DFC9-...): always File action -> powershell + NextGPU-PlayElevated
    -Exe steam.exe -Args "-applaunch {SteamAppId}"
    (does not nest Playnite --start; avoids single-instance handoff as nextGPU).
  - Epic: left on library plugin action (skip).
  - Desktop: only allowlist runAsAdmin=true or resolved-appids.txt @ADMIN File exes.

  Requires NextGPUService running when the user clicks Play.
  Moonlight/Sunshine still uses elevated Playnite --start via launchGame.ps1.

.PARAMETER PlayniteInstallDir
  Override Playnite root (default: PlayniteInstall.path).

.PARAMETER AllowlistPath
  desktop-apps.allowlist.json path.

.PARAMETER ResolvedAppIdsPath
  Sunshine resolved-appids.txt path.

.PARAMETER WhatIf
  Report changes without writing games.db.
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = '',
    [string]$AllowlistPath = '',
    [string]$ResolvedAppIdsPath = 'C:\Program Files\Sunshine\config\resolved-appids.txt',
    [string]$ElevateScriptPath = '',
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$script:WatcherRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $script:WatcherRoot 'src\Playnite-Database.psm1'))) {
    throw "Playnite-Database.psm1 not found under $script:WatcherRoot\src"
}

$LogDir = Join-Path $env:ProgramData 'nextGPU\logs'
$LogFile = Join-Path $LogDir 'apply-playnite-elevated.log'

function Write-ApplyLog {
    param([string]$Level, [string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    try {
        if (-not (Test-Path -LiteralPath $LogDir)) {
            New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch { }
    Write-Host $line
}

function Deploy-NextGpuPlayElevatedScript {
    <#
    .SYNOPSIS
      Copy NextGPU-PlayElevated.ps1 (+ .cmd) from repo runtime to ProgramData.
    #>
    $destDir = Join-Path $env:ProgramData 'nextGPU\scripts'
    $destPs1 = Join-Path $destDir 'NextGPU-PlayElevated.ps1'
    $repoRoot = Split-Path -Parent $script:WatcherRoot
    $srcPs1 = Join-Path $repoRoot 'scripts\runtime\NextGPU-PlayElevated.ps1'
    $srcCmd = Join-Path $repoRoot 'scripts\runtime\NextGPU-PlayElevated.cmd'

    if (-not (Test-Path -LiteralPath $srcPs1)) {
        Write-ApplyLog 'WARN' "Repo elevate script not found: $srcPs1"
        return $false
    }

    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $srcPs1 -Destination $destPs1 -Force
    if (Test-Path -LiteralPath $srcCmd) {
        Copy-Item -LiteralPath $srcCmd -Destination (Join-Path $destDir 'NextGPU-PlayElevated.cmd') -Force
    }
    Write-ApplyLog 'INFO' "Deployed elevate wrapper: $destPs1"
    return $true
}

Import-Module (Join-Path $script:WatcherRoot 'src\Playnite-Path.psm1') -Force
Import-Module (Join-Path $script:WatcherRoot 'src\Playnite-Database.psm1') -Force

# Module $script: vars are not visible here; use the same well-known Playnite PluginIds.
$SteamPluginId = 'CB91DFC9-B977-43BF-8E70-55F46E410FAB'
$EpicPluginId = '00000002-DBD1-46C6-B5D0-B1BA559D10E4'

$null = Deploy-NextGpuPlayElevatedScript

if ([string]::IsNullOrWhiteSpace($ElevateScriptPath)) {
    $ElevateScriptPath = Join-Path $env:ProgramData 'nextGPU\scripts\NextGPU-PlayElevated.ps1'
}
if (-not (Test-Path -LiteralPath $ElevateScriptPath)) {
    $repoCopy = Join-Path (Split-Path -Parent $script:WatcherRoot) 'scripts\runtime\NextGPU-PlayElevated.ps1'
    if (Test-Path -LiteralPath $repoCopy) {
        $ElevateScriptPath = $repoCopy
        Write-ApplyLog 'WARN' "Using repo elevate script (not yet in ProgramData): $ElevateScriptPath"
    }
    else {
        throw "Elevate script not found. Deploy NextGPU-PlayElevated.ps1 first: $ElevateScriptPath"
    }
}

$powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellExe)) {
    $powershellExe = 'powershell.exe'
}

$installDir = $PlayniteInstallDir
if ([string]::IsNullOrWhiteSpace($installDir)) {
    $installDir = Resolve-PlayniteInstallPathFromConfig -RepoRoot $script:WatcherRoot
}
if ([string]::IsNullOrWhiteSpace($installDir)) {
    $pathFile = Join-Path $script:WatcherRoot 'PlayniteInstall.path'
    throw "Playnite install path is not configured. Run Setup-PlayniteSteam and choose a folder, or pass -PlayniteInstallDir. Expected: $pathFile"
}
$installDir = Expand-PlayniteInstallDirectory -Path $installDir
if (-not (Test-PlayniteInstalledAt -InstallDir $installDir)) {
    Write-ApplyLog 'WARN' "Playnite install may be incomplete at: $installDir"
}

$playniteDesktopExe = $null
try {
    $playniteDesktopExe = Get-PlayniteDesktopExe -InstallDir $installDir
}
catch { }
if ([string]::IsNullOrWhiteSpace($playniteDesktopExe)) {
    $playniteDesktopExe = Join-Path $installDir 'Playnite.DesktopApp.exe'
}
if (-not (Test-Path -LiteralPath $playniteDesktopExe)) {
    Write-ApplyLog 'WARN' "Playnite.DesktopApp.exe not found at: $playniteDesktopExe"
}

if ([string]::IsNullOrWhiteSpace($AllowlistPath)) {
    $AllowlistPath = Join-Path $script:WatcherRoot 'config\playnite\desktop-apps.allowlist.json'
}

Write-ApplyLog 'INFO' "Playnite install: $installDir"
Write-ApplyLog 'INFO' "Elevate script: $ElevateScriptPath"
Write-ApplyLog 'INFO' "Playnite DesktopApp: $playniteDesktopExe"
Write-ApplyLog 'INFO' "Allowlist: $AllowlistPath"

# --- Build Admin match sets ---
$adminExeNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$adminInstallDirs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

if (Test-Path -LiteralPath $AllowlistPath) {
    $allowDoc = Get-Content -LiteralPath $AllowlistPath -Raw | ConvertFrom-Json
    $apps = @($allowDoc.apps)
    foreach ($app in $apps) {
        if ($app.runAsAdmin -eq $true -and $app.exe) {
            [void]$adminExeNames.Add([string]$app.exe)
            Write-ApplyLog 'INFO' "Allowlist runAsAdmin exe=$($app.exe)"
        }
    }
}
else {
    Write-ApplyLog 'WARN' "Allowlist not found: $AllowlistPath"
}

if (Test-Path -LiteralPath $ResolvedAppIdsPath) {
    foreach ($line in Get-Content -LiteralPath $ResolvedAppIdsPath) {
        if ($line -notmatch '@ADMIN') { continue }
        $rest = $line
        if ($rest -match '^\s*\d+\s*:\s*(.+)$') { $rest = $Matches[1].Trim() }
        $rest = $rest -replace '\s*@ADMIN\b\s*', ' '
        $installSide = $null
        if ($rest -match '\|\s*(.+)$') {
            $installSide = $Matches[1].Trim().Trim('"')
        }
        if ($installSide -and (Test-Path -LiteralPath $installSide)) {
            [void]$adminInstallDirs.Add([System.IO.Path]::GetFullPath($installSide).TrimEnd('\', '/'))
            Write-ApplyLog 'INFO' "resolved-appids @ADMIN installDir=$installSide"
        }
        # If line launches a direct exe (not Playnite --start), capture filename
        if ($rest -match '(?i)(?:&)?\"?([^\"|]+\.exe)\"?' -and $rest -notmatch '(?i)Playnite\.DesktopApp\.exe') {
            $exePath = $Matches[1].Trim()
            [void]$adminExeNames.Add([System.IO.Path]::GetFileName($exePath))
            $parent = Split-Path -Parent $exePath
            if ($parent) {
                try { [void]$adminInstallDirs.Add([System.IO.Path]::GetFullPath($parent).TrimEnd('\', '/')) } catch { }
            }
        }
    }
}
else {
    Write-ApplyLog 'WARN' "resolved-appids not found: $ResolvedAppIdsPath"
}

function Test-IsAlreadyElevatedAction {
    param([string]$Path, [string]$Arguments)
    $blob = "$Path $Arguments"
    return ($blob -match '(?i)NextGPU-PlayElevated')
}

function Test-IsSteamElevatedApplaunchAction {
    param(
        [string]$Path,
        [string]$Arguments,
        [string]$SteamAppId,
        [string]$SteamExe
    )
    if (-not (Test-IsAlreadyElevatedAction -Path $Path -Arguments $Arguments)) { return $false }
    if ([string]::IsNullOrWhiteSpace($SteamAppId)) { return $false }
    $blob = "$Path $Arguments"
    if ($blob -notmatch '(?i)steam\.exe') { return $false }
    $escapedApp = [regex]::Escape($SteamAppId)
    return ($blob -match ("(?i)-applaunch\s+$escapedApp\b"))
}

function Resolve-SteamExePath {
    # Prefer shared resolver (no hardcoded Z:); pass Playnite install so same-drive Steam is preferred.
    return (Resolve-NextGpuSteamExePath -PreferNearPath $installDir)
}

function Get-SteamAppIdFromPlayniteGame {
    param($Game, $Doc)
    # Playnite Steam library stores numeric AppID in GameId.
    $gid = [string]$Game.GameId
    if ($gid -match '^\d{1,10}$') { return $gid }
    if ($Doc -and $Doc.ContainsKey('GameId')) {
        $raw = Get-BsonValueAsString -Value $Doc['GameId']
        if ($raw -match '^\d{1,10}$') { return $raw }
    }
    return $null
}

function Test-IsAdminMarkedGame {
    param($Game)
    $path = [string]$Game.PrimaryPlayPath
    if ([string]::IsNullOrWhiteSpace($path)) { return $false }
    if ($path -match '(?i)Playnite\.DesktopApp\.exe') { return $false }

    $leaf = [System.IO.Path]::GetFileName($path)
    if ($adminExeNames.Contains($leaf)) { return $true }

    $dir = [string]$Game.InstallDirectory
    if (-not $dir) { $dir = Split-Path -Parent $path }
    if ($dir) {
        try {
            $full = [System.IO.Path]::GetFullPath($dir).TrimEnd('\', '/')
            if ($adminInstallDirs.Contains($full)) { return $true }
            foreach ($adminDir in $adminInstallDirs) {
                if ($full.StartsWith($adminDir, [StringComparison]::OrdinalIgnoreCase)) { return $true }
                if ($path.StartsWith($adminDir + '\', [StringComparison]::OrdinalIgnoreCase) -or
                    $path.StartsWith($adminDir + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
        catch { }
    }
    return $false
}

function New-ElevateWrapperArguments {
    param(
        [Parameter(Mandatory)][string]$ElevateScript,
        [Parameter(Mandatory)][string]$TargetExe,
        [string]$WorkingDir = '',
        [string]$TargetArgs = '',
        [switch]$Wait
    )

    $argParts = New-Object System.Collections.Generic.List[string]
    [void]$argParts.Add('-NoProfile')
    [void]$argParts.Add('-ExecutionPolicy Bypass')
    [void]$argParts.Add('-File')
    [void]$argParts.Add(('"{0}"' -f $ElevateScript))
    [void]$argParts.Add('-Exe')
    [void]$argParts.Add(('"{0}"' -f $TargetExe))
    if ($WorkingDir) {
        [void]$argParts.Add('-WorkingDir')
        [void]$argParts.Add(('"{0}"' -f $WorkingDir))
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetArgs)) {
        [void]$argParts.Add('-Args')
        [void]$argParts.Add(('"{0}"' -f ($TargetArgs -replace '"', '\"')))
    }
    if ($Wait) {
        [void]$argParts.Add('-Wait')
    }
    return [string]::Join(' ', $argParts)
}

function Set-ElevatedPlayniteGameAction {
    param(
        $Collection,
        $Doc,
        [string]$Name,
        [string]$InstallDirectoryKeep,
        [string]$WrapperArgs,
        [string]$ActionWorkingDir,
        [switch]$WhatIfMode
    )

    $msg = "Elevate play action: $Name"
    if ($WhatIfMode) {
        Write-ApplyLog 'INFO' "WhatIf: $msg"
        return $true
    }

    if ($InstallDirectoryKeep) {
        Set-LiteDbBsonField -Document $Doc -Name 'InstallDirectory' -Value $InstallDirectoryKeep
    }
    Set-LiteDbBsonField -Document $Doc -Name 'IsInstalled' -Value $true
    Set-LiteDbBsonField -Document $Doc -Name 'IncludeLibraryPluginAction' -Value $false

    $action = New-PlayniteFilePlayActionBson -ExePath $powershellExe -WorkingDir $ActionWorkingDir -Arguments $WrapperArgs
    $arr = New-Object LiteDB.BsonArray
    Add-LiteDbBsonArrayItem -Array $arr -Value $action
    Set-LiteDbBsonField -Document $Doc -Name 'GameActions' -Value $arr

    [void]$Collection.Update($Doc)
    Write-ApplyLog 'INFO' "Updated: $msg"
    return $true
}

# --- Apply ---
$steamExe = Resolve-SteamExePath
if (-not $steamExe) {
    Write-ApplyLog 'WARN' 'steam.exe not found (registry / fixed-drive scan). Steam elevate rewrites will be skipped.'
}
else {
    Write-ApplyLog 'INFO' "Steam exe: $steamExe"
}

Ensure-PlayniteLibraryDatabaseUnlocked -InstallDir $installDir -LogAction { param($m) Write-ApplyLog 'INFO' $m }

$dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $installDir
Initialize-LiteDbFromPlayniteInstall -InstallDir $installDir
$connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
$db = New-Object LiteDB.LiteDatabase($connectionString)

$updated = 0
$skipped = 0
$already = 0

try {
    $collection = $db.GetCollection('Game')
    foreach ($doc in @($collection.FindAll())) {
        $game = New-PlayniteGameRecordFromBsonDocument -Doc $doc
        if (-not $game) { continue }

        $pluginId = [string]$game.PluginId
        $path = [string]$game.PrimaryPlayPath
        $work = [string]$game.PrimaryWorkingDir
        $rawActions = Get-RawPlayActionDocumentsFromGameDocument -Doc $doc
        $existingArgs = ''
        if ($rawActions.Count -gt 0) {
            $existingArgs = Get-BsonValueAsString -Value $rawActions[0]['Arguments']
        }

        # Epic: leave library plugin action (Moonlight still elevates Epic via launchGame).
        if ($pluginId -ieq $EpicPluginId) {
            $skipped++
            continue
        }

        # Steam: elevate steam.exe -applaunch {AppId} as NextGPU-Admin (no nested Playnite --start).
        if ($pluginId -ieq $SteamPluginId) {
            $isInstalled = $true
            if ($doc.ContainsKey('IsInstalled')) {
                $isInstalled = Get-BsonValueAsBool -Value $doc['IsInstalled']
            }
            if (-not $isInstalled) {
                $skipped++
                continue
            }

            if (-not $steamExe) {
                Write-ApplyLog 'WARN' "Skip Steam (steam.exe missing): $($game.Name)"
                $skipped++
                continue
            }

            $steamAppId = Get-SteamAppIdFromPlayniteGame -Game $game -Doc $doc
            if ([string]::IsNullOrWhiteSpace($steamAppId)) {
                Write-ApplyLog 'WARN' "Skip Steam (no numeric GameId/AppID): $($game.Name) GameId=$($game.GameId)"
                $skipped++
                continue
            }

            if (Test-IsSteamElevatedApplaunchAction -Path $path -Arguments $existingArgs -SteamAppId $steamAppId -SteamExe $steamExe) {
                $already++
                continue
            }

            $steamWork = Split-Path -Parent $steamExe
            $applaunchArgs = "-applaunch $steamAppId"
            $wrapperArgs = New-ElevateWrapperArguments `
                -ElevateScript $ElevateScriptPath `
                -TargetExe $steamExe `
                -WorkingDir $steamWork `
                -TargetArgs $applaunchArgs

            $keepInstall = [string]$game.InstallDirectory
            if (Set-ElevatedPlayniteGameAction `
                    -Collection $collection `
                    -Doc $doc `
                    -Name ("Steam: {0} => steam -applaunch {1}" -f $game.Name, $steamAppId) `
                    -InstallDirectoryKeep $keepInstall `
                    -WrapperArgs $wrapperArgs `
                    -ActionWorkingDir $steamWork `
                    -WhatIfMode:$WhatIf) {
                $updated++
            }
            continue
        }

        # Desktop / manual games: allowlist / @ADMIN only.
        if (Test-IsAlreadyElevatedAction -Path $path -Arguments $existingArgs) {
            $already++
            continue
        }

        if (-not (Test-IsAdminMarkedGame -Game $game)) {
            $skipped++
            continue
        }

        if ([string]::IsNullOrWhiteSpace($path) -or $path -notmatch '\.(exe|cmd|bat)$') {
            Write-ApplyLog 'WARN' "Skip (not File exe): $($game.Name) path=$path"
            $skipped++
            continue
        }

        $origExe = $path
        $origWork = if ($work) { $work } else { Split-Path -Parent $origExe }
        $origArgs = $existingArgs

        $wrapperArgs = New-ElevateWrapperArguments `
            -ElevateScript $ElevateScriptPath `
            -TargetExe $origExe `
            -WorkingDir $origWork `
            -TargetArgs $origArgs

        if (Set-ElevatedPlayniteGameAction `
                -Collection $collection `
                -Doc $doc `
                -Name ("{0} => {1}" -f $game.Name, $origExe) `
                -InstallDirectoryKeep $origWork `
                -WrapperArgs $wrapperArgs `
                -ActionWorkingDir $origWork `
                -WhatIfMode:$WhatIf) {
            $updated++
        }
    }
}
finally {
    $db.Dispose()
}

Write-ApplyLog 'INFO' "Done. updated=$updated alreadyElevated=$already skipped=$skipped WhatIf=$($WhatIf.IsPresent)"
exit 0
