param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $env:ProgramData 'nextGPU\logs'
$LogFile = Join-Path $LogDir 'launchGame.log'
$SunshineLog = 'C:\Program Files\Sunshine\config\sunshine.log'
$AppIDsFile = 'C:\Program Files\Sunshine\config\resolved-appids.txt'
$AppIDsJsonFile = 'C:\Program Files\Sunshine\config\resolved-appids.json'
$MaxAttempts = 30
$SteamStartupWaitSeconds = 15

function Ensure-LaunchGameLogAccess {
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [Parameter(Mandatory)][string]$LogFile
    )

    $nextGpuRoot = Split-Path -Parent $LogDir
    foreach ($path in @($nextGpuRoot, $LogDir)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    # Full control for all standard users; inherited on new files under $LogDir.
    # Succeeds when task runs elevated (admin/SYSTEM); no-op if caller lacks ACL rights.
    foreach ($grant in @('Users:(OI)(CI)F', 'Authenticated Users:(OI)(CI)F')) {
        $null = & icacls.exe $LogDir /grant $grant /C 2>&1
    }

    if (Test-Path -LiteralPath $LogFile) {
        foreach ($grant in @('Users:F', 'Authenticated Users:F')) {
            $null = & icacls.exe $LogFile /grant $grant /C 2>&1
        }
    }
}

Ensure-LaunchGameLogAccess -LogDir $LogDir -LogFile $LogFile

function Write-Log {
    param([string]$Level, [string]$Message)
    $ts   = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    try {
        Add-Content -Path $LogFile -Value $line -ErrorAction Stop
    }
    catch {
        Write-Host "[$ts] [WARN] Could not write log file: $_"
    }
}

function Get-LatestAppID {
    param([string]$LogPath)

    if (-not (Test-Path $LogPath)) {
        Write-Log 'ERROR' "Sunshine log not found: $LogPath"
        return $null
    }

    try {
        $lines = @(Get-Content -Path $LogPath)

        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            $line = $lines[$i]
            if ($line -match 'Debug: appid -- (\d+)') {
                $appID = $Matches[1]
                Write-Log 'INFO' "Found app ID at line $($i+1): $appID (from: $line)"
                return $appID
            }
        }

        Write-Log 'WARN' 'No app ID entries found in sunshine log'
    }
    catch {
        Write-Log 'ERROR' "Failed to parse sunshine log: $_"
    }

    return $null
}

function Get-LaunchSourceFromTxt {
    param([string]$AppID, [string]$AppIDsFilePath)

    if (-not (Test-Path $AppIDsFilePath)) {
        return $null
    }

    try {
        $currentSection = $null
        foreach ($line in Get-Content -Path $AppIDsFilePath) {
            if ($line -match '^(Steam|Epic|Desktop):\s*$') {
                $currentSection = $Matches[1]
                continue
            }

            if ($line -match '^\s*' + [regex]::Escape($AppID) + '\s*:') {
                return $currentSection
            }
        }
    }
    catch {
        Write-Log 'WARN' "Failed to parse AppIDs section for source: $_"
    }

    return $null
}

function Get-LaunchSourceFromJson {
    param([string]$AppID, [string]$AppIDsJsonPath)

    if (-not (Test-Path $AppIDsJsonPath)) {
        return $null
    }

    try {
        $entries = @(Get-Content -Path $AppIDsJsonPath -Raw | ConvertFrom-Json)
        $entry = $entries | Where-Object { [string]$_.AppID -eq [string]$AppID } | Select-Object -First 1
        if ($entry -and $entry.Source) {
            return [string]$entry.Source
        }
    }
    catch {
        Write-Log 'WARN' "Failed to parse AppIDs JSON for source: $_"
    }

    return $null
}

function Get-LaunchInfo {
    param(
        [string]$AppID,
        [string]$AppIDsFilePath,
        [string]$AppIDsJsonPath
    )

    if (-not (Test-Path $AppIDsFilePath)) {
        Write-Log 'ERROR' "AppIDs file not found: $AppIDsFilePath"
        return $null
    }

    $launchPath = $null

    try {
        $content = Get-Content -Path $AppIDsFilePath -Raw
        $pattern = [regex]::Escape($AppID) + '\s*:\s*(.+?)(?=\r?\n|$)'
        $match = [regex]::Match($content, $pattern)

        if ($match.Success) {
            $launchPath = $match.Groups[1].Value.Trim()
        }
    }
    catch {
        Write-Log 'ERROR' "Failed to parse AppIDs file: $_"
        return $null
    }

    if (-not $launchPath) {
        return $null
    }

    $source = Get-LaunchSourceFromJson -AppID $AppID -AppIDsJsonPath $AppIDsJsonPath
    if (-not $source) {
        $source = Get-LaunchSourceFromTxt -AppID $AppID -AppIDsFilePath $AppIDsFilePath
    }

    return [PSCustomObject]@{
        LaunchPath = $launchPath
        Source     = $source
    }
}

function Get-SteamInstallRoot {
    $registryPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )

    foreach ($keyPath in $registryPaths) {
        try {
            $installPath = (Get-ItemProperty -LiteralPath $keyPath -Name InstallPath -ErrorAction Stop).InstallPath
            if ($installPath -and (Test-Path -LiteralPath (Join-Path $installPath 'steam.exe'))) {
                return $installPath.TrimEnd('\')
            }
        }
        catch { }
    }

    foreach ($candidate in @(
            'C:\Program Files (x86)\Steam',
            'C:\Program Files\Steam',
            'D:\Steam', 'D:\Games\Steam',
            'E:\Steam', 'E:\Games\Steam'
        )) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'steam.exe')) {
            return $candidate.TrimEnd('\')
        }
    }

    return $null
}

function Test-SteamRunning {
    return $null -ne (Get-Process -Name steam -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Ensure-SteamRunning {
    param([int]$WaitSeconds = $SteamStartupWaitSeconds)

    if (Test-SteamRunning) {
        Write-Log 'INFO' 'Steam is already running.'
        return $true
    }

    $steamRoot = Get-SteamInstallRoot
    if (-not $steamRoot) {
        Write-Log 'WARN' 'Steam install not found; skipping Steam startup.'
        return $false
    }

    $steamExe = Join-Path $steamRoot 'steam.exe'
    Write-Log 'INFO' "Starting Steam: $steamExe -silent (cwd: $steamRoot)"

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $steamExe
    $psi.Arguments = '-silent'
    $psi.WorkingDirectory = $steamRoot
    $psi.UseShellExecute = $true
    [System.Diagnostics.Process]::Start($psi) | Out-Null

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-SteamRunning) {
            Write-Log 'INFO' 'Steam process detected.'
            Start-Sleep -Seconds 2
            return $true
        }
        Start-Sleep -Milliseconds 500
    }

    Write-Log 'WARN' "Steam did not appear within ${WaitSeconds}s; continuing anyway."
    return $false
}

function Invoke-LaunchCommand {
    param([string]$LaunchCommand)

    if ([string]::IsNullOrWhiteSpace($LaunchCommand)) {
        throw 'Launch command is empty.'
    }

    # Playnite export format: &"D:\Playnite\Playnite.DesktopApp.exe" --start {guid}
    # Always add --startdesktop so the library UI is visible alongside the game launch.
    if ($LaunchCommand -match '^&"(.+?)"\s+--start\s+(\S+)\s*$') {
        $exe = $Matches[1]
        $gameId = $Matches[2]

        if (-not (Test-Path -LiteralPath $exe)) {
            throw "Executable not found: $exe"
        }

        $playniteRoot = Split-Path -Parent $exe
        $playniteArgs = "--startdesktop --start $gameId"
        Write-Log 'INFO' "Launching Playnite: $exe $playniteArgs (cwd: $playniteRoot)"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $playniteArgs
        $psi.WorkingDirectory = $playniteRoot
        $psi.UseShellExecute = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
        return
    }

    # Plain executable path
    if ($LaunchCommand -notmatch '[\s&"]' -and (Test-Path -LiteralPath $LaunchCommand)) {
        Write-Log 'INFO' "Launching executable: $LaunchCommand"
        Start-Process -FilePath $LaunchCommand
        return
    }

    # Fallback for other PowerShell-style commands
    Write-Log 'INFO' 'Using Invoke-Expression fallback for launch command.'
    Invoke-Expression $LaunchCommand
}

Write-Log 'INFO' '=========================================='
Write-Log 'INFO' "App Launcher script started (PID $PID, user $env:USERNAME)"
Write-Log 'INFO' "Sunshine Log  : $SunshineLog"
Write-Log 'INFO' "AppIDs File   : $AppIDsFile"
Write-Log 'INFO' "AppIDs JSON   : $AppIDsJsonFile"
Write-Log 'INFO' "Max attempts  : $MaxAttempts (retry every 2s)"
Write-Log 'INFO' "Log file      : $LogFile"
Write-Log 'INFO' '=========================================='

$latestAppID = Get-LatestAppID -LogPath $SunshineLog
if (-not $latestAppID) {
    Write-Log 'ERROR' 'Could not find latest app ID in sunshine log'
    exit 1
}
Write-Log 'INFO' "Latest App ID found: $latestAppID"

$launchInfo = Get-LaunchInfo -AppID $latestAppID -AppIDsFilePath $AppIDsFile -AppIDsJsonPath $AppIDsJsonFile
if (-not $launchInfo -or -not $launchInfo.LaunchPath) {
    Write-Log 'ERROR' "No launch path found for app ID: $latestAppID"
    exit 1
}

$launchPath = $launchInfo.LaunchPath
$launchSource = $launchInfo.Source
Write-Log 'INFO' "Launch path  : $launchPath"
Write-Log 'INFO' "Launch source: $(if ($launchSource) { $launchSource } else { '(unknown)' })"

if ($launchSource -eq 'Steam') {
    Write-Log 'INFO' 'Steam game detected; ensuring Steam is running before Playnite.'
    Ensure-SteamRunning | Out-Null
}
elseif ($launchSource) {
    Write-Log 'INFO' "Non-Steam source ($launchSource); skipping Steam startup."
}
else {
    Write-Log 'WARN' 'Launch source unknown; skipping Steam startup.'
}

$attempt = 0

while ($true) {
    $attempt++
    Write-Log 'INFO' "Attempt $attempt/$MaxAttempts -- launching: $launchPath ..."

    try {
        Invoke-LaunchCommand -LaunchCommand $launchPath
        Write-Log 'INFO' "SUCCESS -- application dispatched on attempt $attempt"
        Write-Log 'INFO' 'Application should be launching. Exiting launch script.'
        exit 0
    }
    catch {
        Write-Log 'WARN' "Attempt $attempt failed: $_"
    }

    if ($attempt -ge $MaxAttempts) {
        Write-Log 'ERROR' "FAILED -- reached max attempts ($MaxAttempts). Giving up."
        exit 1
    }

    Write-Log 'INFO' 'Retrying in 2s...'
    Start-Sleep -Seconds 2
}