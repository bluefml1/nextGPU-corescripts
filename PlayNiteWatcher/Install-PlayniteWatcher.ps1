#Requires -Version 5.1
<#
.SYNOPSIS
    Headless PlayNiteWatcher install (no WatcherUI). Applies prep-cmd hooks and global cleanup.
.EXAMPLE
    .\Install-PlayniteWatcher.ps1
    .\Install-PlayniteWatcher.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = "",
    [string]$SunshineConfigDir = "",
    [string]$AllowlistPath = "",
    [switch]$Uninstall,
    [switch]$NoElevate,
    [switch]$SkipExport
)

$ErrorActionPreference = "Stop"
$script:InstallModuleRoot = $PSScriptRoot
$script:InstallScriptPath = Join-Path $script:InstallModuleRoot "Install-PlayniteWatcher.ps1"
$script:InstallLogFile = Join-Path $script:InstallModuleRoot "Install-PlayniteWatcher.log"

function Write-InstallLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $script:InstallLogFile -Value $line -Encoding utf8
}

function Ensure-PlayniteWatcherAdministrator {
    param(
        [switch]$NoElevateSwitch,
        [string]$PlayniteInstallDirParam = "",
        [string]$SunshineConfigDirParam = "",
        [switch]$UninstallSwitch
    )

    if ($NoElevateSwitch) {
        return
    }

    if (-not (Get-Command Test-IsAdministrator -ErrorAction SilentlyContinue)) {
        . (Join-Path $script:InstallModuleRoot "Playnite-Common.ps1")
    }

    if (Test-IsAdministrator) {
        return
    }

    $argList = @(
        "-ExecutionPolicy", "Bypass",
        "-NoProfile",
        "-File", "`"$script:InstallScriptPath`""
    )
    if ($UninstallSwitch) { $argList += "-Uninstall" }
    if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDirParam)) {
        $argList += "-PlayniteInstallDir", "`"$PlayniteInstallDirParam`""
    }
    if (-not [string]::IsNullOrWhiteSpace($SunshineConfigDirParam)) {
        $argList += "-SunshineConfigDir", "`"$SunshineConfigDirParam`""
    }

    Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList $argList
    exit $LASTEXITCODE
}

function Get-EventLogsPrepCmd {
    return [PSCustomObject]@{
        do       = ""
        undo     = 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Program Files\Sunshine\scripts\eventLogs.ps1"'
        elevated = $true
    }
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

function Get-ParsedPlayniteApps {
    param([string]$ConfigPath)

    $appsPath = Join-Path $ConfigPath "apps.json"
    if (-not (Test-Path -LiteralPath $appsPath)) {
        return @()
    }

    $jsonContent = Get-Content -LiteralPath $appsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $apps = @()

    foreach ($_ in @($jsonContent.apps)) {
        $id = $null
        $useSteamEpic = $false
        $kioskOutput = ""
        $parsed = $false

        if ($_.'playnite-id') {
            $id = $_.'playnite-id'.ToString()
            $useSteamEpic = $true
            $kioskOutput = if ($_.output) { $_.output.ToString() } else { "" }
            $parsed = $true
        }
        elseif ($_.output -match '^([0-9a-fA-F-]{36})\.kiosk\.log$') {
            $id = $Matches[1]
            $useSteamEpic = $true
            $kioskOutput = $_.output.ToString()
            $parsed = $true
        }
        elseif ($_.'image-path' -match 'Apps\\(.*)\\') {
            $id = $Matches[1]
            $parsed = $true
        }

        if (-not $parsed) { continue }

        $apps += [PSCustomObject]@{
            applicationName    = $_.name
            uniqueId           = $id
            uuid               = if ($_.uuid) { $_.uuid.ToString() } else { $id.ToUpper() }
            imagePath          = if ($_.'image-path') { $_.'image-path'.ToString() } else { "" }
            cmd                = $_.cmd
            detached           = $_.detached
            exitTimeout        = if ($_.'exit-timeout') { [int]$_.'exit-timeout' } else { 0 }
            waitAll            = ($_.'wait-all' -eq $true) -or ($_.'wait-all' -eq "true")
            autoDetach         = ($_.'auto-detach' -eq $true) -or ($_.'auto-detach' -eq "true")
            useSteamEpicFormat = $useSteamEpic
            kioskOutput        = $kioskOutput
        }
    }

    return $apps
}

function Get-NonPlayniteSunshineApps {
    param([string]$ConfigPath)
    $appsPath = Join-Path $ConfigPath "apps.json"
    $jsonContent = Get-Content -LiteralPath $appsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    return @($jsonContent.apps | Where-Object { -not (Test-IsPlayniteManagedSunshineApp $_) })
}

function Save-PlayniteWatcherApps {
    param(
        [string]$ConfigPath,
        [object[]]$UpdatedApps
    )

    $appsJsonPath = Join-Path $ConfigPath "apps.json"
    $appConfiguration = Get-Content -LiteralPath $appsJsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    [object[]]$filteredApps = Get-NonPlayniteSunshineApps -ConfigPath $ConfigPath

    foreach ($app in $UpdatedApps) {
        if ([string]::IsNullOrWhiteSpace($app.uniqueId)) { continue }

        if ($app.useSteamEpicFormat) {
            $jsonApp = [PSCustomObject]@{
                name                      = $app.applicationName
                'playnite-id'             = $app.uniqueId
                output                    = $app.kioskOutput
                'prep-cmd'                = @(Get-EventLogsPrepCmd)
                'auto-detach'             = $true
                'exclude-global-prep-cmd' = $false
                'exit-timeout'            = 5
                'image-path'              = ""
                elevated                  = $true
                'wait-all'                = $false
                'wait-exit'               = $false
            }
        }
        else {
            $jsonApp = [PSCustomObject]@{
                'image-path'              = $app.imagePath
                name                      = $app.applicationName
                'prep-cmd'                = @(Get-EventLogsPrepCmd)
                'wait-all'                = $app.waitAll
                'exit-timeout'            = $app.exitTimeout
                'auto-detach'             = $app.autoDetach
                'exclude-global-prep-cmd' = $false
                uuid                      = $app.uuid
            }
            if (-not [string]::IsNullOrWhiteSpace($app.detached)) {
                $jsonApp | Add-Member -MemberType NoteProperty -Name "detached" -Value $app.detached -Force
            }
        }
        $filteredApps += $jsonApp
    }

    $appConfiguration.apps = $filteredApps
    $appConfiguration | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $appsJsonPath -Encoding utf8
}

function Update-WatcherScriptPaths {
    param(
        [string]$PlayniteExe,
        [string]$SunshineConfig,
        [string]$RepoRoot
    )

    $escapedConfig = $SunshineConfig.Replace('\', '\\')

    foreach ($fileName in @("PlayniteWatcher.ps1", "PrepCommandInstaller.ps1")) {
        $filePath = Join-Path $RepoRoot $fileName
        if (-not (Test-Path -LiteralPath $filePath)) { continue }
        $content = Get-Content -LiteralPath $filePath -Encoding UTF8
        $configPattern = '(\$sunshineConfigPath\s*=\s*")[^"]*(")'
        $updated = $content -replace $configPattern, "`$1$escapedConfig`$2"
        Set-Content -LiteralPath $filePath -Value $updated -Encoding UTF8
    }
}

function Invoke-PlayniteWatcherInstall {
    [CmdletBinding()]
    param(
        [string]$PlayniteInstallDir = "",
        [string]$SunshineConfigDir = "",
        [string]$AllowlistPath = "",
        [switch]$Uninstall,
        [switch]$NoElevate,
        [switch]$SkipExport
    )

    Ensure-PlayniteWatcherAdministrator -NoElevateSwitch:$NoElevate `
        -PlayniteInstallDirParam $PlayniteInstallDir `
        -SunshineConfigDirParam $SunshineConfigDir `
        -UninstallSwitch:$Uninstall

    if (Test-Path -LiteralPath $script:InstallLogFile) {
        Remove-Item -LiteralPath $script:InstallLogFile -Force -ErrorAction SilentlyContinue
    }

    Write-InstallLog "=== Install-PlayniteWatcher started (Uninstall=$Uninstall) ==="
    . (Join-Path $script:InstallModuleRoot "Playnite-Common.ps1")

    if (-not $Uninstall -and -not $SkipExport) {
        $allowFile = Resolve-DesktopAppAllowlistPath -RepoRoot $script:InstallModuleRoot -OverridePath $AllowlistPath
        if (Test-Path -LiteralPath $allowFile) {
            $exportScript = Join-Path $script:InstallModuleRoot "Export-SunshineFromPlaynite.ps1"
            if (Test-Path -LiteralPath $exportScript) {
                Write-InstallLog "Running Sunshine export (allowlist + Steam/Epic)..."
                if (-not (Get-Command Invoke-SunshineExportFromPlaynite -ErrorAction SilentlyContinue)) {
                    . $exportScript
                }
                $exportParams = @{ AllowlistPath = $AllowlistPath }
                if (-not [string]::IsNullOrWhiteSpace($PlayniteInstallDir)) {
                    $exportParams.PlayniteInstallDir = $PlayniteInstallDir
                }
                if (-not [string]::IsNullOrWhiteSpace($SunshineConfigDir)) {
                    $exportParams.SunshineConfigDir = $SunshineConfigDir
                }
                Invoke-SunshineExportFromPlaynite @exportParams
            }
        }
    }

    $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $script:InstallModuleRoot -OverrideDir $PlayniteInstallDir
    $installDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
    if (-not $installDir) {
        throw "Playnite install folder is not set. Run Setup-PlayniteSteam.bat or pass -PlayniteInstallDir."
    }

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $installDir
    $playniteRoot = Split-Path -Path $playniteExe -Parent
    $fullScreenExe = Join-Path $playniteRoot "Playnite.FullscreenApp.exe"
    Save-PlayniteInstallPath -RepoRoot $script:InstallModuleRoot -InstallDir $installDir | Out-Null
    Write-InstallLog "Playnite install path saved to PlayniteInstall.path"

    $configPath = if ([string]::IsNullOrWhiteSpace($SunshineConfigDir)) {
        Get-DefaultSunshineConfigPath
    }
    else {
        $SunshineConfigDir.TrimEnd('\')
    }

    if (-not (Test-Path -LiteralPath (Join-Path $configPath "apps.json"))) {
        throw "Sunshine apps.json not found at $configPath. Run Export-SunshineFromPlaynite.ps1 first."
    }

    Update-WatcherScriptPaths -PlayniteExe $playniteExe -SunshineConfig $configPath -RepoRoot $script:InstallModuleRoot

    if ($Uninstall) {
        $parsedApps = Get-ParsedPlayniteApps -ConfigPath $configPath | ForEach-Object {
            $_.uniqueId = ""
            $_
        }
        Save-PlayniteWatcherApps -ConfigPath $configPath -UpdatedApps $parsedApps
        . (Join-Path $script:InstallModuleRoot "PrepCommandInstaller.ps1") $false
        Remove-Item -LiteralPath (Join-Path $playniteRoot "Extensions\PlayNiteWatcherExt") -Recurse -Force -ErrorAction SilentlyContinue
        Write-InstallLog "Uninstall finished."
        return
    }

    $updatedApps = Get-ParsedPlayniteApps -ConfigPath $configPath
    $deduped = @{}
    foreach ($app in $updatedApps) {
        if (-not $deduped.ContainsKey($app.uniqueId)) {
            $deduped[$app.uniqueId] = $app
        }
    }
    $updatedApps = @($deduped.Values)

    foreach ($app in $updatedApps) {
        $app.cmd = ""
        if ($app.useSteamEpicFormat) {
            $app.detached = ""
        }
    }

    if ($null -eq ($updatedApps | Where-Object { $_.applicationName -eq "PlayNite FullScreen App" })) {
        $updatedApps = , [PSCustomObject]@{
            applicationName    = "PlayNite FullScreen App"
            imagePath          = Join-Path $script:InstallModuleRoot "playnite-boxart.png"
            cmd                = "`"$fullScreenExe`""
            detached           = ""
            waitAll            = $false
            autoDetach         = $false
            exitTimeout        = 0
            uuid               = "14D9821B-7EA2-48C2-9AF7-970608282F93"
            useSteamEpicFormat = $false
            uniqueId           = "14D9821B-7EA2-48C2-9AF7-970608282F93"
            kioskOutput        = ""
        } + $updatedApps
    }

    Remove-Item -LiteralPath (Join-Path $playniteRoot "Extensions\PlayNiteWatcherExt") -Recurse -Force -ErrorAction SilentlyContinue
    $extSource = Join-Path $script:InstallModuleRoot "PlayNiteWatcherExt"
    if (-not (Test-Path -LiteralPath $extSource)) {
        Write-InstallLog "PlayNiteWatcherExt folder not found; skipping extension copy." "WARN"
    }
    else {
        Copy-Item -LiteralPath $extSource -Destination (Join-Path $playniteRoot "Extensions\PlayNiteWatcherExt") -Recurse -Force
    }

    Save-PlayniteWatcherApps -ConfigPath $configPath -UpdatedApps $updatedApps
    . (Join-Path $script:InstallModuleRoot "PrepCommandInstaller.ps1") $true

    Write-InstallLog ("Installed PlayNiteWatcher hooks for {0} app(s)." -f $updatedApps.Count)
    Write-InstallLog "=== Install finished ==="
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-PlayniteWatcherInstall @PSBoundParameters
    }
    catch {
        Write-InstallLog $_.Exception.Message "ERROR"
        exit 1
    }
}
