#Requires -Version 5.1

$script:_moduleRoot = $PSScriptRoot

#Requires -Version 5.1
<#
.SYNOPSIS
    Shared Playnite portable path and install helpers for PlayNiteWatcher scripts.
#>

$script:PlaynitePortableFolderName = "Playnite"
$script:LiteDbAssemblyLoadedFrom = $null
$script:LocalPlayniteInstallDir = Join-Path $env:LOCALAPPDATA "Playnite"
$script:PlayniteInstallPathFileName = "PlayniteInstall.path"

function Get-NormalizedDirectoryPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }
    $trimmed = $Path.Trim().TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') {
        return "$($trimmed)\"
    }
    if (-not (Test-Path -LiteralPath $trimmed)) {
        return $trimmed
    }
    return ([System.IO.Path]::GetFullPath($trimmed)).TrimEnd('\')
}

function Expand-PlayniteInstallDirectory {
    param([string]$Path)

    $normalized = Get-NormalizedDirectoryPath -Path $Path
    if (-not $normalized) {
        return $null
    }

    $folderName = $script:PlaynitePortableFolderName
    if ((Split-Path -Path $normalized -Leaf) -ieq $folderName) {
        return $normalized
    }

    return [System.IO.Path]::Combine("$normalized\", $folderName).TrimEnd('\')
}

function Get-PlayniteInstallPathFile {
    param([string]$RepoRoot)
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw "RepoRoot is required."
    }
    return Join-Path $RepoRoot $script:PlayniteInstallPathFileName
}

function Read-SavedPlayniteInstallPath {
    param([string]$RepoRoot)

    $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $pathFile)) {
        return $null
    }

    $line = (Get-Content -LiteralPath $pathFile -TotalCount 1 -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($line)) {
        return $null
    }

    return Expand-PlayniteInstallDirectory -Path $line.Trim()
}

function Resolve-PlayniteInstallPathFromConfig {
    param(
        [string]$RepoRoot,
        [string]$OverrideDir = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($OverrideDir)) {
        return Expand-PlayniteInstallDirectory -Path $OverrideDir
    }

    return Read-SavedPlayniteInstallPath -RepoRoot $RepoRoot
}

function Test-PlayniteInstalledAt {
    param([string]$InstallDir)
    return Test-Path -LiteralPath (Join-Path $InstallDir "Playnite.DesktopApp.exe")
}

function Test-PlaynitePortableLayout {
    param([string]$InstallDir)

    if (-not (Test-PlayniteInstalledAt -InstallDir $InstallDir)) {
        return $false
    }
    $unins = Join-Path $InstallDir "unins000.exe"
    if (Test-Path -LiteralPath $unins) {
        return $false
    }
    return $true
}

function Get-7ZipExecutable {
    $candidates = @(
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    $fromPath = Get-Command 7z -ErrorAction SilentlyContinue
    if ($fromPath) {
        return $fromPath.Source
    }
    return $null
}

function Get-PlayniteDownloadDir {
    param([string]$InstallDir)
    return Join-Path $InstallDir "Download"
}

function Normalize-FolderPickerPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $trimmed = $Path.Trim().TrimEnd('\')
    if ($trimmed -match '^[A-Za-z]:$') {
        return "$trimmed\"
    }

    if (Test-Path -LiteralPath $trimmed) {
        return ([System.IO.Path]::GetFullPath($trimmed)).TrimEnd('\')
    }

    return $trimmed
}

function Test-FolderPickerPathIsDriveRoot {
    param([string]$Path)

    $normalized = Normalize-FolderPickerPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $false
    }

    return ($normalized -match '^[A-Za-z]:\\$')
}

function Get-PlayniteFolderPickerInitialDirectory {
    param(
        [string]$PreferredPath,
        [switch]$AnchorToDriveRoot
    )

    if ($AnchorToDriveRoot -and -not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        $driveRoot = [System.IO.Path]::GetPathRoot($PreferredPath)
        if ($driveRoot -and (Test-Path -LiteralPath $driveRoot)) {
            return $driveRoot.TrimEnd('\')
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath)) {
        if (Test-Path -LiteralPath $PreferredPath) {
            return (Normalize-FolderPickerPath -Path $PreferredPath)
        }

        $parent = Split-Path -Path $PreferredPath -Parent
        if ($parent -and (Test-Path -LiteralPath $parent)) {
            return (Normalize-FolderPickerPath -Path $parent)
        }
    }

    $systemDrive = $env:SystemDrive
    if ($systemDrive -and (Test-Path -LiteralPath $systemDrive)) {
        return $systemDrive.TrimEnd('\')
    }

    return [Environment]::GetFolderPath('MyDocuments')
}

function Get-CommittedFolderBrowserPath {
    param(
        [System.Windows.Forms.FolderBrowserDialog]$Dialog
    )

    $path = $Dialog.SelectedPath
    $flags = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
    $field = $Dialog.GetType().GetField('selectedPath', $flags)
    if ($field) {
        $internalPath = [string]$field.GetValue($Dialog)
        if (-not [string]::IsNullOrWhiteSpace($internalPath)) {
            $path = $internalPath
        }
    }

    return Normalize-FolderPickerPath -Path $path
}

function Show-PlayniteFolderBrowserDialog {
    param(
        [string]$Description,
        [string]$InitialDirectory = "",
        [bool]$ShowNewFolderButton = $false,
        [switch]$AnchorInitialToDriveRoot
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null

    $start = Get-PlayniteFolderPickerInitialDirectory `
        -PreferredPath $InitialDirectory `
        -AnchorToDriveRoot:$AnchorInitialToDriveRoot

    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $ShowNewFolderButton
    $dialog.RootFolder = [Environment+SpecialFolder]::MyComputer

    if (-not [string]::IsNullOrWhiteSpace($start)) {
        $selected = $start
        if (Test-FolderPickerPathIsDriveRoot -Path $selected) {
            $selected = Normalize-FolderPickerPath -Path $selected
        }
        if ((Test-Path -LiteralPath $selected) -or (Test-FolderPickerPathIsDriveRoot -Path $selected)) {
            $dialog.SelectedPath = $selected
        }
    }

    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    return Get-CommittedFolderBrowserPath -Dialog $dialog
}

function Test-PlayniteInstallParentInsideWatcherScripts {
    param(
        [string]$ParentPath,
        [string]$WatcherScriptsRoot
    )

    if ([string]::IsNullOrWhiteSpace($ParentPath) -or [string]::IsNullOrWhiteSpace($WatcherScriptsRoot)) {
        return $false
    }

    try {
        $parent = Normalize-FolderPickerPath -Path $ParentPath
        $watcher = Normalize-FolderPickerPath -Path $WatcherScriptsRoot
        if (-not $parent -or -not $watcher) {
            return $false
        }

        return $parent.Equals($watcher, [StringComparison]::OrdinalIgnoreCase) -or
            $parent.StartsWith("$watcher\", [StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return $false
    }
}

function Show-PlayniteInstallFolderDialog {
    param(
        [string]$InitialDirectory = "",
        [switch]$AnchorInitialToDriveRoot
    )

    return Show-PlayniteFolderBrowserDialog `
        -Description "Select a parent folder for Playnite portable. A Playnite subfolder is created automatically inside your selection." `
        -InitialDirectory $InitialDirectory `
        -ShowNewFolderButton $true `
        -AnchorInitialToDriveRoot:$AnchorInitialToDriveRoot
}

function Resolve-PlayniteInstallDir {
    <#
        Resolves only the path from PlayniteInstall.path, -PlayniteInstallDir, or caller override.
        Does not fall back to %LocalAppData%\Playnite or Program Files.
    #>
    param([string]$PreferredDir)

    if ([string]::IsNullOrWhiteSpace($PreferredDir)) {
        return $null
    }

    $dir = Expand-PlayniteInstallDirectory -Path $PreferredDir
    if (Test-PlayniteInstalledAt -InstallDir $dir) {
        return $dir
    }

    return $dir
}

function Save-PlayniteInstallPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,
        [Parameter(Mandatory = $true)]
        [string]$InstallDir
    )

    $normalized = Expand-PlayniteInstallDirectory -Path $InstallDir
    if (-not $normalized) {
        throw "Invalid Playnite install path: $InstallDir"
    }
    $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
    Set-Content -LiteralPath $pathFile -Value $normalized -Encoding utf8 -NoNewline
    return $normalized
}

function Get-PlayniteDesktopExe {
    param([string]$InstallDir)

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw "Playnite install directory is not set. Run Setup-PlayniteSteam.bat and choose an install folder."
    }

    $exe = Join-Path $InstallDir "Playnite.DesktopApp.exe"
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Playnite.DesktopApp.exe not found at: $exe"
    }
    return $exe
}

function Get-PlayniteInstallRootFromExe {
    param([string]$PlayniteExe)

    if ([string]::IsNullOrWhiteSpace($PlayniteExe)) {
        throw "PlayniteExe is required."
    }
    if (-not (Test-Path -LiteralPath $PlayniteExe)) {
        throw "Playnite executable not found: $PlayniteExe"
    }
    return (Split-Path -Path $PlayniteExe -Parent)
}

function Get-ProcessByExecutablePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExePath,
        [int]$TimeoutSeconds = 45
    )

    $procName = [System.IO.Path]::GetFileName($ExePath)
    if ([string]::IsNullOrWhiteSpace($procName)) {
        return $null
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $match = Get-CimInstance -ClassName Win32_Process -Filter "Name='$procName'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $ExePath) } |
            Select-Object -First 1
        if ($match) {
            return Get-Process -Id $match.ProcessId -ErrorAction SilentlyContinue
        }
        Start-Sleep -Milliseconds 250
    }

    return $null
}

function Start-LimitedUserProcess {
    <#
        Start a process at the interactive user's non-elevated (Limited) run level.
        Used when setup scripts run elevated but must not launch Playnite as admin.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string[]]$ArgumentList = @(),
        [string]$WorkingDirectory = '',
        [ValidateSet('Normal', 'Hidden', 'Minimized', 'Maximized')]
        [string]$WindowStyle = 'Normal',
        [switch]$PassThru,
        [switch]$Wait
    )

    if (-not (Test-IsAdministrator)) {
        $params = @{
            FilePath = $FilePath
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $params.ArgumentList = $ArgumentList
        }
        if ($WorkingDirectory) {
            $params.WorkingDirectory = $WorkingDirectory
        }
        if ($PassThru) {
            $params.PassThru = $true
        }
        if ($Wait) {
            $params.Wait = $true
        }
        if ($PSBoundParameters.ContainsKey('WindowStyle')) {
            $params.WindowStyle = $WindowStyle
        }
        return Start-Process @params
    }

    $userId = if ($env:USERDOMAIN -and $env:USERNAME) {
        "$env:USERDOMAIN\$env:USERNAME"
    }
    else {
        $env:USERNAME
    }

    $taskName = "NextGPU-LimitedLaunch-$([guid]::NewGuid().ToString('N'))"
    $useHiddenLaunch = $PSBoundParameters.ContainsKey('WindowStyle') -and $WindowStyle -eq 'Hidden'

    if ($useHiddenLaunch) {
        $escapedExe = $FilePath.Replace("'", "''")
        $escapedWd = $WorkingDirectory.Replace("'", "''")
        $argLiteral = ($ArgumentList | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ','
        if (-not $argLiteral) {
            $argLiteral = '@()'
        }
        else {
            $argLiteral = "@($argLiteral)"
        }

        $launchScript = @"
Set-Location -LiteralPath '$escapedWd'
Start-Process -FilePath '$escapedExe' -ArgumentList $argLiteral -WindowStyle Hidden
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launchScript))
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
    }
    else {
        $actionParams = @{
            Execute = $FilePath
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $actionParams.Argument = ($ArgumentList -join ' ')
        }
        if ($WorkingDirectory) {
            $actionParams.WorkingDirectory = $WorkingDirectory
        }
        $action = New-ScheduledTaskAction @actionParams
    }

    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName | Out-Null
        $proc = $null
        if ($PassThru -or $Wait) {
            $proc = Get-ProcessByExecutablePath -ExePath $FilePath -TimeoutSeconds 60
        }
        if ($Wait -and $proc) {
            try { $proc.WaitForExit() } catch { }
            return $proc
        }
        if ($PassThru) {
            return $proc
        }
    }
    finally {
        Start-Sleep -Milliseconds 300
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }

    return $null
}

function Start-PlayniteProcess {
    <#
        Launch Playnite with install folder as working directory.
        When the caller is elevated, launches at the interactive user's limited (non-admin) token
        so Playnite does not show the elevated-privileges warning.
        Uses Push-Location on non-elevated paths because Start-Process -WorkingDirectory requires PowerShell 6+.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PlayniteExe,
        [string[]]$ArgumentList = @(),
        [ValidateSet('Normal', 'Hidden', 'Minimized', 'Maximized')]
        [string]$WindowStyle,
        [switch]$PassThru,
        [switch]$Wait
    )

    $playniteRoot = Get-PlayniteInstallRootFromExe -PlayniteExe $PlayniteExe

    if (Test-IsAdministrator) {
        $limitedParams = @{
            FilePath = $PlayniteExe
            WorkingDirectory = $playniteRoot
            PassThru = $PassThru
            Wait = $Wait
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $limitedParams.ArgumentList = $ArgumentList
        }
        if ($PSBoundParameters.ContainsKey('WindowStyle')) {
            $limitedParams.WindowStyle = $WindowStyle
        }
        return Start-LimitedUserProcess @limitedParams
    }

    Push-Location -LiteralPath $playniteRoot
    try {
        $params = @{
            FilePath = $PlayniteExe
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $params.ArgumentList = $ArgumentList
        }
        if ($PassThru) {
            $params.PassThru = $true
        }
        if ($Wait) {
            $params.Wait = $true
        }
        if ($PSBoundParameters.ContainsKey('WindowStyle')) {
            $params.WindowStyle = $WindowStyle
        }
        return Start-Process @params
    }
    finally {
        Pop-Location
    }
}

function Get-PlayniteDesktopExeFromConfig {
    param(
        [string]$RepoRoot,
        [string]$OverrideDir = ""
    )

    $installDir = Resolve-PlayniteInstallPathFromConfig -RepoRoot $RepoRoot -OverrideDir $OverrideDir
    if (-not $installDir) {
        $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
        throw "Playnite install path is not configured. Run Setup-PlayniteSteam.bat -PickInstallFolder or create: $pathFile"
    }

    return Get-PlayniteDesktopExe -InstallDir $installDir
}

function Get-PlayniteDataDirectory {
    param([string]$InstallDir)
    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        throw "InstallDir is required."
    }
    return $InstallDir.TrimEnd('\')
}

Export-ModuleMember -Function *
