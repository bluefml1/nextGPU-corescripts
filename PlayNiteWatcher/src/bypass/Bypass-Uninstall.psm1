#Requires -Version 5.1
<#
    Uninstall and cleanup for bypass/RunAsTool/Playnite environment.
    Dot-sourced from Playnite-Common.ps1.
#>

$script:_moduleRoot = $PSScriptRoot

function Invoke-RunAsToolRntImport {
    param(
        [Parameter(Mandatory)]
        [string]$RntPath,
        [string]$RunAsToolExe = '',
        [string]$AdminUser = $script:DefaultBypassAdminUser,
        [securestring]$AdminPassword,
        [switch]$ResetList,
        [string]$RepoRoot = '',
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $RntPath)) {
        throw "RNT file not found: $RntPath"
    }

    if (-not $AdminPassword) {
        $cred = Get-Credential -UserName $AdminUser -Message "RunAsTool import requires the admin password for $AdminUser"
        if (-not $cred) {
            throw 'Admin password is required for RunAsTool import.'
        }
        $AdminPassword = $cred.Password
    }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($AdminPassword)
    try {
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $script:PlayNiteWatcherScriptRoot
    }

    if ([string]::IsNullOrWhiteSpace($RunAsToolExe)) {
        $RunAsToolExe = Resolve-RunAsToolExe -RepoRoot $RepoRoot -InstallIfMissing
    }
    if (-not $RunAsToolExe -or -not (Test-Path -LiteralPath $RunAsToolExe)) {
        throw 'RunAsTool.exe not found.'
    }

    $argList = New-Object System.Collections.Generic.List[string]
    if ($ResetList.IsPresent) {
        [void]$argList.Add('/R')
    }
    [void]$argList.Add("/U=$AdminUser")
    [void]$argList.Add("/P=$plain")
    [void]$argList.Add("/I=$RntPath")

    $plain = $null
    if ($LogAction) { & $LogAction "RunAsTool RNT import starting: $RntPath (resetList=$($ResetList.IsPresent))" }

    $proc = Start-Process -FilePath $RunAsToolExe -ArgumentList $argList.ToArray() -Wait -PassThru -Verb RunAs
    if ($proc.ExitCode -ne 0) {
        throw "RunAsTool import failed with exit code $($proc.ExitCode). Check the NextGPU-Authority password and retry."
    }

    if ($LogAction) { & $LogAction "RunAsTool RNT import completed: $RntPath" }
}

function Stop-RunAsToolApplicationProcesses {
    Get-Process -Name "RunAsTool*" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force -ErrorAction Stop
        }
        catch { }
    }
}

function Remove-RunAsToolInstallation {
    param(
        [string]$RepoRoot,
        [scriptblock]$LogAction
    )

    Stop-RunAsToolApplicationProcesses

    if (Test-Path -LiteralPath $script:DefaultRunAsToolProgramDataDir) {
        Remove-Item -LiteralPath $script:DefaultRunAsToolProgramDataDir -Recurse -Force -ErrorAction SilentlyContinue
        if ($LogAction) { & $LogAction "Removed RunAsTool install: $($script:DefaultRunAsToolProgramDataDir)" }
    }

    $nextGpuRoot = Join-Path $env:ProgramData "NextGPU"
    if (Test-Path -LiteralPath $nextGpuRoot) {
        $remaining = @(Get-ChildItem -LiteralPath $nextGpuRoot -Force -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $nextGpuRoot -Recurse -Force -ErrorAction SilentlyContinue
            if ($LogAction) { & $LogAction "Removed empty folder: $nextGpuRoot" }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $toolDir = Join-Path $RepoRoot "tools\runastool"
        if (Test-Path -LiteralPath $toolDir) {
            Get-ChildItem -LiteralPath $toolDir -Recurse -Filter "RunAsTool*.exe" -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                    if ($LogAction) { & $LogAction "Removed bundled RunAsTool: $($_.FullName)" }
                }
            Get-ChildItem -LiteralPath $toolDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ieq 'RunAsTool' } |
                ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                    if ($LogAction) { & $LogAction "Removed bundled RunAsTool folder: $($_.FullName)" }
                }
        }
    }
}

function Get-GameShortcutsFolderCandidatesFromConfig {
    param([object]$Config)

    $paths = New-Object System.Collections.Generic.List[string]
    if ($Config -and $Config.bypassesPath) {
        [void]$paths.Add([string]$Config.bypassesPath)
    }
    if ($Config -and $Config.parentPath) {
        $resolved = Resolve-GameShortcutsPathFromParent -ParentPath $Config.parentPath
        if ($resolved) {
            [void]$paths.Add($resolved)
        }
        foreach ($name in @($script:DefaultGameShortcutsFolderName, $script:LegacyGameShortcutsFolderName)) {
            [void]$paths.Add((Join-Path $Config.parentPath $name))
        }
    }

    return @($paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}

function Remove-GameShortcutsFoldersFromConfig {
    param(
        [object]$Config,
        [scriptblock]$LogAction
    )

    foreach ($folder in (Get-GameShortcutsFolderCandidatesFromConfig -Config $Config)) {
        if (-not (Test-Path -LiteralPath $folder)) {
            continue
        }
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
        if ($LogAction) { & $LogAction "Removed Game Shortcuts folder: $folder" }
    }
}

function Remove-AllowlistEntriesForBypassBindings {
    param(
        [string]$RepoRoot,
        [object[]]$Bindings,
        [scriptblock]$LogAction
    )

    $nameIds = @($Bindings | ForEach-Object { $_.nameId } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if ($nameIds.Count -eq 0) {
        return 0
    }

    $allowPath = Get-DesktopAppAllowlistPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $allowPath)) {
        return 0
    }

    $raw = Get-Content -LiteralPath $allowPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $raw.apps) {
        return 0
    }

    $idSet = @($nameIds | ForEach-Object { $_.ToString() })
    $remaining = @($raw.apps | Where-Object { $idSet -notcontains $_.nameId })
    $removed = @($raw.apps).Count - $remaining.Count
    if ($removed -le 0) {
        return 0
    }

    $raw.apps = @($remaining)
    ($raw | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $allowPath -Encoding UTF8
    if ($LogAction) { & $LogAction "Removed $removed allowlist entries linked to bypass bindings." }
    return $removed
}

function Restore-PlayniteGameAfterBypassRemoval {
    param(
        $Doc,
        $Collection,
        [object]$Binding,
        [scriptblock]$LogAction
    )

    $title = Get-BsonValueAsString -Value $Doc['Name']
    $game = New-PlayniteGameRecordFromBsonDocument -Doc $Doc
    $syncType = if ($Binding -and $Binding.syncType) { [string]$Binding.syncType } else { "" }

    if ((Test-PlayniteGameIsStoreLibrary -Game $game) -or $syncType -eq 'OutsideAllowlist') {
        Set-LiteDbBsonField -Document $Doc -Name 'IncludeLibraryPluginAction' -Value $true
        if ($Doc.ContainsKey('GameActions')) {
            [void]$Doc.Remove('GameActions')
        }
        [void]$Collection.Update($Doc)
        if ($LogAction) { & $LogAction "Playnite store game reverted to library plugin: $title" }
        return 'StoreReverted'
    }

    [void]$Collection.Delete($Doc['_id'])
    if ($LogAction) { & $LogAction "Removed manual bypass game from Playnite library: $title (run Import Desktop Apps to restore)" }
    return 'ManualRemoved'
}

function Clear-PlayniteBypassBindingsFromLibrary {
    param(
        [string]$InstallDir,
        [object[]]$Bindings,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir) -or @($Bindings).Count -eq 0) {
        return @{ StoreReverted = 0; ManualRemoved = 0; Missing = 0 }
    }

    $stats = @{ StoreReverted = 0; ManualRemoved = 0; Missing = 0 }
    $bindingById = @{}
    foreach ($b in @($Bindings)) {
        if ($b -and $b.playniteId) {
            $bindingById[$b.playniteId.ToString()] = $b
        }
    }

    Invoke-PlayniteLibraryDatabaseSession -InstallDir $InstallDir -LogAction $LogAction -EditAction {
        param($db)
        $collection = $db.GetCollection("Game")
        foreach ($playniteId in @($bindingById.Keys)) {
            $binding = $bindingById[$playniteId]
            $guid = [guid]::Empty
            if (-not [guid]::TryParse($playniteId, [ref]$guid)) {
                $stats.Missing++
                continue
            }

            $doc = $collection.FindById($guid)
            if (-not $doc) {
                $stats.Missing++
                if ($LogAction) { & $LogAction "Playnite game not found for bypass removal: $playniteId" "WARN" }
                continue
            }

            $result = Restore-PlayniteGameAfterBypassRemoval -Doc $doc -Collection $collection -Binding $binding -LogAction $LogAction
            if ($result -eq 'StoreReverted') { $stats.StoreReverted++ }
            elseif ($result -eq 'ManualRemoved') { $stats.ManualRemoved++ }
        }
    }

    return $stats
}

function Clear-PlayniteBypassPublishedData {
    param(
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        return
    }

    $nextGpuData = Join-Path $InstallDir 'ExtensionsData\NextGPU'
    if (Test-Path -LiteralPath $nextGpuData) {
        Remove-Item -LiteralPath $nextGpuData -Recurse -Force -ErrorAction SilentlyContinue
        if ($LogAction) { & $LogAction "Removed Playnite bypass extension data: $nextGpuData" }
    }
}

function Reset-BypassShortcutsConfigFile {
    param(
        [string]$RepoRoot,
        [string]$InstallDir = "",
        [scriptblock]$LogAction
    )

    $template = Join-Path $RepoRoot "config\playnite\$($script:BypassShortcutsTemplateFileName)"
    $target = Get-BypassShortcutsConfigPath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Bypass shortcuts template not found: $template"
    }

    Copy-Item -LiteralPath $template -Destination $target -Force
    if ($LogAction) { & $LogAction "Reset bypass-shortcuts.json to empty template." }

    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $empty = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
        Publish-NextGpuBypassBindingsToPlaynite -InstallDir $InstallDir -Config $empty.Config
        if ($LogAction) { & $LogAction "Cleared Playnite bypass-bindings.json." }
    }
}

function Uninstall-PlayniteWatcherHooks {
    param(
        [string]$RepoRoot,
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        return
    }

    $script = Join-Path $RepoRoot 'Install-PlayniteWatcher.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        if ($LogAction) { & $LogAction "Install-PlayniteWatcher.ps1 not found; skipping watcher uninstall." "WARN" }
        return
    }

    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', $script,
            '-Uninstall', '-NoElevate',
            '-PlayniteInstallDir', $InstallDir
        ) -Wait -PassThru -WindowStyle Hidden
        if ($LogAction) {
            & $LogAction "PlayNiteWatcher uninstall exit code: $($proc.ExitCode)"
        }
    }
    catch {
        if ($LogAction) { & $LogAction "PlayNiteWatcher uninstall failed: $($_.Exception.Message)" "WARN" }
    }
}

function Test-PlayniteLiteDbLoadedInSession {
    param([string]$InstallDir = "")

    if ([string]::IsNullOrWhiteSpace($script:LiteDbAssemblyLoadedFrom)) {
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        return $true
    }

    $normalizedInstall = $InstallDir.TrimEnd('\')
    return $script:LiteDbAssemblyLoadedFrom.Equals($normalizedInstall, [StringComparison]::OrdinalIgnoreCase)
}

function New-PlayniteFolderRemovalEncodedCommand {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [int]$WaitForProcessId = 0,
        [int]$MaxAttempts = 6,
        [string]$LogFile = "",
        [string]$PathFile = ""
    )

    $pathLiteral = $LiteralPath.Replace("'", "''")
    $installPrefix = $LiteralPath.TrimEnd('\').Replace("'", "''") + '\'
    $logFileLiteral = if ([string]::IsNullOrWhiteSpace($LogFile)) { "" } else { $LogFile.Replace("'", "''") }
    $pathFileLiteral = if ([string]::IsNullOrWhiteSpace($PathFile)) { "" } else { $PathFile.Replace("'", "''") }
    $waitForPid = [Math]::Max(0, $WaitForProcessId)

    $innerScript = @"
function Write-RemovalLog {
    param([string]`$Message, [string]`$Level = 'INFO')
    `$line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Level, `$Message
    if ('$logFileLiteral') {
        Add-Content -LiteralPath '$logFileLiteral' -Value `$line -Encoding utf8
    }
}

if ($waitForPid -gt 0) {
    try { Wait-Process -Id $waitForPid -Timeout 180 -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Seconds 2
}

`$target = '$pathLiteral'
`$installPrefix = '$installPrefix'
`$selfPid = `$PID
function Stop-PlayniteInstallLockingProcesses {
    Get-Process -Name 'Playnite.DesktopApp', 'Playnite.FullscreenApp', 'RunAsTool*', 'powershell', 'pwsh' -ErrorAction SilentlyContinue |
        ForEach-Object {
            if (`$_.Id -eq `$selfPid) { return }
            `$shouldStop = `$false
            try {
                if (`$_.Path -and `$_.Path.StartsWith(`$installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    `$shouldStop = `$true
                }
                elseif (`$_.Modules) {
                    foreach (`$module in `$_.Modules) {
                        if (`$module.FileName -and `$module.FileName.StartsWith(`$installPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                            `$shouldStop = `$true
                            break
                        }
                    }
                }
            }
            catch { }
            if (`$shouldStop) {
                Stop-Process -Id `$_.Id -Force -ErrorAction SilentlyContinue
            }
        }
    try {
        Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
            Where-Object {
                (`$_.ExecutablePath -and `$_.ExecutablePath.StartsWith(`$installPrefix, [StringComparison]::OrdinalIgnoreCase)) -or
                (`$_.CommandLine -and `$_.CommandLine -like "*$pathLiteral*")
            } |
            Where-Object { `$_.ProcessId -ne `$selfPid } |
            ForEach-Object { Stop-Process -Id `$_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    catch { }
}
`$removed = `$false
for (`$attempt = 1; `$attempt -le $MaxAttempts; `$attempt++) {
    Stop-PlayniteInstallLockingProcesses
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath `$target)) {
        `$removed = `$true
        break
    }
    try {
        Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction Stop
        `$removed = `$true
        break
    }
    catch {
        `$err = `$_.Exception.Message
        Write-RemovalLog "Playnite folder removal attempt `$attempt/$MaxAttempts failed: `$err" 'WARN'
        try {
            `$empty = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path `$empty -Force | Out-Null
            & robocopy `$empty `$target /mir /r:1 /w:1 /nfl /ndl /njh /njs /nc /ns /np 2>&1 | Out-Null
            Remove-Item -LiteralPath `$empty -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath `$target) {
                Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction Stop
            }
            `$removed = `$true
            break
        }
        catch {
            Start-Sleep -Seconds 3
        }
    }
}
if (-not `$removed -and (Test-Path -LiteralPath `$target)) {
    exit 1
}
if (`$removed -and '$logFileLiteral') {
    Write-RemovalLog "Removed Playnite portable install: `$target"
}
if ('$pathFileLiteral' -and (Test-Path -LiteralPath '$pathFileLiteral')) {
    Remove-Item -LiteralPath '$pathFileLiteral' -Force -ErrorAction SilentlyContinue
    Write-RemovalLog 'Removed PlayniteInstall.path'
}
exit 0
"@

    return [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerScript))
}

function Remove-DirectoryInFreshProcess {
    <#
        Deletes a folder from a new PowerShell process so assemblies loaded from that
        folder in the caller (e.g. Playnite LiteDB.dll via Add-Type) do not lock files.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [int]$MaxAttempts = 6,
        [string]$LogFile = "",
        [string]$PathFile = ""
    )

    if (-not (Test-Path -LiteralPath $LiteralPath)) {
        return $true
    }

    $encoded = New-PlayniteFolderRemovalEncodedCommand `
        -LiteralPath $LiteralPath `
        -MaxAttempts $MaxAttempts `
        -LogFile $LogFile `
        -PathFile $PathFile
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encoded
    ) -Wait -PassThru -WindowStyle Hidden
    return ($proc.ExitCode -eq 0)
}

function Start-PlayniteFolderRemovalAfterProcessExit {
    param(
        [Parameter(Mandatory)]
        [string]$LiteralPath,
        [Parameter(Mandatory)]
        [int]$WaitForProcessId,
        [string]$LogFile = "",
        [string]$PathFile = "",
        [int]$MaxAttempts = 6
    )

    $encoded = New-PlayniteFolderRemovalEncodedCommand `
        -LiteralPath $LiteralPath `
        -WaitForProcessId $WaitForProcessId `
        -MaxAttempts $MaxAttempts `
        -LogFile $LogFile `
        -PathFile $PathFile
    $null = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-EncodedCommand', $encoded
    ) -WindowStyle Hidden
}

function Remove-PlaynitePortableInstall {
    param(
        [string]$RepoRoot,
        [string]$InstallDir = "",
        [scriptblock]$LogAction,
        [string]$LogFile = "",
        [int]$CallerProcessId = 0
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $preferred = Resolve-PlayniteInstallPathFromConfig -RepoRoot $RepoRoot -OverrideDir ""
        $InstallDir = Resolve-PlayniteInstallDir -PreferredDir $preferred
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        if ($LogAction) { & $LogAction "Playnite install path not configured; skipping portable folder removal." "WARN" }
        return @{ Removed = $false; Deferred = $false }
    }

    $playniteExe = Join-Path $InstallDir 'Playnite.DesktopApp.exe'
    if (Test-Path -LiteralPath $playniteExe) {
        Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 45 -Force
    }
    Stop-Process -Name 'Playnite.DesktopApp', 'Playnite.FullscreenApp' -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    $pathFile = Get-PlayniteInstallPathFile -RepoRoot $RepoRoot
    $deferForLiteDbLock = Test-PlayniteLiteDbLoadedInSession -InstallDir $InstallDir
    $waitForPid = if ($CallerProcessId -gt 0) { $CallerProcessId } else { 0 }
    $useDeferredRemoval = $waitForPid -gt 0

    if (Test-Path -LiteralPath $InstallDir) {
        if ($useDeferredRemoval) {
            if ($LogAction) {
                if ($deferForLiteDbLock) {
                    & $LogAction "Scheduling Playnite folder removal after this script exits (LiteDB.dll is loaded in this session)..."
                }
                else {
                    & $LogAction "Scheduling Playnite folder removal after this script exits..."
                }
            }
            Start-PlayniteFolderRemovalAfterProcessExit `
                -LiteralPath $InstallDir `
                -WaitForProcessId $waitForPid `
                -LogFile $LogFile `
                -PathFile $pathFile
            return @{ Removed = $false; Deferred = $true }
        }

        if ($LogAction) { & $LogAction "Removing Playnite portable install in a separate process..." }
        $removed = Remove-DirectoryInFreshProcess -LiteralPath $InstallDir -LogFile $LogFile -PathFile $pathFile
        if ($removed) {
            if ($LogAction) { & $LogAction "Removed Playnite portable install: $InstallDir" }
            return @{ Removed = $true; Deferred = $false }
        }

        if ($LogAction) {
            & $LogAction "Could not remove Playnite folder (files may still be locked by Playnite or another app). Bypass/RunAsTool cleanup completed; close Playnite and delete $InstallDir manually or reboot and retry." "WARN"
        }
        return @{ Removed = $false; Deferred = $false }
    }

    if (Test-Path -LiteralPath $pathFile) {
        Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
        if ($LogAction) { & $LogAction "Removed PlayniteInstall.path" }
    }

    return @{ Removed = $true; Deferred = $false }
}

function Uninstall-PlayniteBypassEnvironment {
    param(
        [string]$RepoRoot,
        [string]$InstallDir = "",
        [switch]$SkipPlaynite,
        [switch]$SkipRunAsTool,
        [switch]$SkipFolders,
        [switch]$SkipAllowlist,
        [switch]$RemovePlayniteInstall,
        [scriptblock]$LogAction,
        [string]$LogFile = "",
        [int]$CallerProcessId = 0
    )

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $config = $wrapper.Config
    $bindings = @($config.bindings)
    $stats = @{
        StoreReverted           = 0
        ManualRemoved           = 0
        Missing                 = 0
        AllowlistRemoved        = 0
        FoldersRemoved          = 0
        PlayniteRemoved         = $false
        PlayniteRemovalDeferred = $false
    }

    if ($RemovePlayniteInstall.IsPresent) {
        Uninstall-PlayniteWatcherHooks -RepoRoot $RepoRoot -InstallDir $InstallDir -LogAction $LogAction
    }

    if (-not $SkipPlaynite.IsPresent -and -not [string]::IsNullOrWhiteSpace($InstallDir)) {
        $playStats = Clear-PlayniteBypassBindingsFromLibrary -InstallDir $InstallDir -Bindings $bindings -LogAction $LogAction
        $stats.StoreReverted = $playStats.StoreReverted
        $stats.ManualRemoved = $playStats.ManualRemoved
        $stats.Missing = $playStats.Missing
        Clear-PlayniteBypassPublishedData -InstallDir $InstallDir -LogAction $LogAction
    }

    if (-not $SkipAllowlist.IsPresent) {
        $stats.AllowlistRemoved = Remove-AllowlistEntriesForBypassBindings -RepoRoot $RepoRoot -Bindings $bindings -LogAction $LogAction
    }

    if (-not $SkipFolders.IsPresent) {
        $folderCandidates = Get-GameShortcutsFolderCandidatesFromConfig -Config $config
        foreach ($folder in $folderCandidates) {
            if (Test-Path -LiteralPath $folder) {
                Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction Stop
                $stats.FoldersRemoved++
                if ($LogAction) { & $LogAction "Removed Game Shortcuts folder: $folder" }
            }
        }
    }

    if (-not $SkipRunAsTool.IsPresent) {
        Remove-RunAsToolInstallation -RepoRoot $RepoRoot -LogAction $LogAction
    }

    Reset-BypassShortcutsConfigFile -RepoRoot $RepoRoot -InstallDir $InstallDir -LogAction $LogAction

    if ($RemovePlayniteInstall.IsPresent) {
        $removalResult = Remove-PlaynitePortableInstall -RepoRoot $RepoRoot -InstallDir $InstallDir -LogAction $LogAction -LogFile $LogFile -CallerProcessId $CallerProcessId
        if ($removalResult -is [hashtable]) {
            $stats.PlayniteRemoved = [bool]$removalResult.Removed
            $stats.PlayniteRemovalDeferred = [bool]$removalResult.Deferred
            if ($removalResult.Deferred -and $LogAction) {
                & $LogAction "Playnite folder will be deleted after this script exits; check Uninstall-PlayniteBypass.log for confirmation."
            }
        }
        else {
            $stats.PlayniteRemoved = [bool]$removalResult
        }
    }

    return [PSCustomObject]$stats
}

Export-ModuleMember -Function *
