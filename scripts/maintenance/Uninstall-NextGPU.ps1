#Requires -Version 5.1
<#
.SYNOPSIS
    Removes nextGPU provisioning artifacts from a Windows host.

.DESCRIPTION
    Stops and removes Windows services, removes Sunshine/Moonlight/NSSM/cloudflared
    files, uninstalls VDD/VAD and ViGEmBus drivers, unregisters scheduled tasks
    (including nextGPU-*), removes Playnite portable install, RunAsTool, Game
    Shortcuts bypass config, wallpaper/shutdown policy and Default-user hive
    keys, releases stale NTUSER mounts, removes CLOUDFLARE_TUNNEL_TOKEN, optional
    nextGPU local user, and generated setup/runtime logs.

    Run with -WhatIf first to preview actions:
        powershell -ExecutionPolicy Bypass -File .\scripts\maintenance\Uninstall-NextGPU.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Force,
    [switch]$SkipDrivers,
    [switch]$SkipGeneratedFiles,
    [switch]$SkipPlaynite,
    [switch]$KeepLocalUsers,
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $ScriptRoot = $RepoRoot.TrimEnd('\')
    $env:NEXTGPU_REPO_ROOT = $ScriptRoot
} elseif ($env:NEXTGPU_REPO_ROOT) {
    $ScriptRoot = $env:NEXTGPU_REPO_ROOT.TrimEnd('\')
} else {
    $ScriptRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
}

function Resolve-NextGpuRepoPath {
    param([string[]]$RelativeParts)
    $rel = $RelativeParts -join '\'
    $fromRoot = Join-Path $ScriptRoot $rel
    if (Test-Path -LiteralPath $fromRoot) {
        return (Resolve-Path -LiteralPath $fromRoot).Path
    }
    if ($RelativeParts.Count -ge 3 -and $RelativeParts[0] -eq 'scripts' -and $RelativeParts[1] -eq 'desktop') {
        $fromMaintenance = Join-Path $ScriptDir (Join-Path '..' $RelativeParts[2])
        if (Test-Path -LiteralPath $fromMaintenance) {
            return (Resolve-Path -LiteralPath $fromMaintenance).Path
        }
    }
    return $fromRoot
}

$LogDir = Join-Path $ScriptRoot 'logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogPath = Join-Path $LogDir 'uninstall-nextgpu.log'

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'SKIP')][string]$Level = 'INFO'
    )
    $line = '[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Host $line
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

$defaultUserHiveScript = Resolve-NextGpuRepoPath @('scripts', 'desktop', 'DefaultUserHive.ps1')
if (Test-Path -LiteralPath $defaultUserHiveScript) {
    . $defaultUserHiveScript
    Write-Log "Loaded DefaultUserHive.ps1 from $defaultUserHiveScript" -Level OK
} else {
    Write-Log "DefaultUserHive.ps1 not found at $defaultUserHiveScript (Default-user hive cleanup will use reg.exe fallback)." -Level WARN
}

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$Description = $FilePath
    )
    if (-not $PSCmdlet.ShouldProcess($Description, "Run $FilePath $($Arguments -join ' ')")) {
        return 0
    }
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        Write-Log "$Description exited with code $($proc.ExitCode)"
        return [int]$proc.ExitCode
    } catch {
        Write-Log "$Description failed: $($_.Exception.Message)" -Level WARN
        return 1
    }
}

function Remove-PathSafe {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Path not present: $Path" -Level SKIP
        return
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Remove')) {
        try {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Removed: $Path" -Level OK
        } catch {
            Write-Log "Failed to remove $Path : $($_.Exception.Message)" -Level WARN
        }
    }
}

function Stop-ProcessSafe {
    param([Parameter(Mandatory)][string[]]$Names)
    foreach ($name in $Names) {
        $processes = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        if ($processes.Count -eq 0) {
            Write-Log "Process not running: $name" -Level SKIP
            continue
        }
        foreach ($process in $processes) {
            if ($PSCmdlet.ShouldProcess("$name (PID $($process.Id))", 'Stop process')) {
                try {
                    Stop-Process -Id $process.Id -Force -ErrorAction Stop
                    Write-Log "Stopped process: $name (PID $($process.Id))" -Level OK
                } catch {
                    Write-Log "Failed to stop process $name (PID $($process.Id)): $($_.Exception.Message)" -Level WARN
                }
            }
        }
    }
}

function Remove-ServiceSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$NssmExe = '',
        [string]$CloudflaredExe = ''
    )

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Log "Service not present: $Name" -Level SKIP
        return
    }

    if ($svc.Status -ne 'Stopped') {
        if ($PSCmdlet.ShouldProcess($Name, 'Stop service')) {
            try {
                Stop-Service -Name $Name -Force -ErrorAction Stop
                $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
                Write-Log "Stopped service: $Name" -Level OK
            } catch {
                Write-Log "Failed to stop service $Name cleanly: $($_.Exception.Message)" -Level WARN
            }
        }
    }

    if ($Name -eq 'cloudflared' -and $CloudflaredExe -and (Test-Path -LiteralPath $CloudflaredExe)) {
        Invoke-External -FilePath $CloudflaredExe -Arguments @('service', 'uninstall') -Description 'cloudflared service uninstall' | Out-Null
    }

    if ($NssmExe -and (Test-Path -LiteralPath $NssmExe)) {
        Invoke-External -FilePath $NssmExe -Arguments @('remove', $Name, 'confirm') -Description "NSSM remove $Name" | Out-Null
    }

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($svc) {
        if ($PSCmdlet.ShouldProcess($Name, 'Delete service with sc.exe')) {
            $null = & sc.exe delete $Name 2>&1
            Write-Log "Requested service deletion via sc.exe: $Name"
        }
    }
}

function Remove-ScheduledTaskSafe {
    param([Parameter(Mandatory)][string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-Log "Scheduled task not present: $TaskName" -Level SKIP
        return
    }
    if ($PSCmdlet.ShouldProcess($TaskName, 'Unregister scheduled task')) {
        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Log "Removed scheduled task: $TaskName" -Level OK
        } catch {
            Write-Log "Failed to remove scheduled task $TaskName : $($_.Exception.Message)" -Level WARN
        }
    }
}

function Remove-AllNextGpuScheduledTasks {
    $known = @(
        'EndSession', 'auto game launch',
            'nextGPU-Heartbeat', 'nextGPU-AutoRepair', 'nextGPU-AutoUpdate', 'nextGPU-NvidiaLogon',
            'nextGPU-ShutdownPolicyLogon', 'nextGPU-SunshineLogon',
        'nextGPU-DesktopCleanupLogon', 'nextGPU-WallpaperFitLogon',
        'nextGPU-UserStorageMount', 'nextGPU-UserStorageUnmount', 'nextGPU-UserStorageEnsureBindings'
    )
    foreach ($name in $known) {
        Remove-ScheduledTaskSafe -TaskName $name
    }
    try {
        $extra = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like 'nextGPU-*' })
        foreach ($task in $extra) {
            if ($known -contains $task.TaskName) { continue }
            Remove-ScheduledTaskSafe -TaskName $task.TaskName
        }
    } catch {
        Write-Log "Could not enumerate scheduled tasks for nextGPU-* cleanup: $($_.Exception.Message)" -Level WARN
    }
}

function Release-StaleDefaultUserHivesSafe {
    if (-not (Get-Command -Name Release-StaleDefaultUserHives -ErrorAction SilentlyContinue)) {
        Write-Log "DefaultUserHive.ps1 not loaded (expected at $(Resolve-NextGpuRepoPath @('scripts','desktop','DefaultUserHive.ps1'))); skipping stale hive release." -Level WARN
        return
    }
    if ($PSCmdlet.ShouldProcess('Default user registry hives', 'Release stale NextGPU hive mounts')) {
        Release-StaleDefaultUserHives
        Write-Log 'Released stale Default-user hive mounts (if any).' -Level OK
    }
}

function Remove-DefaultUserProfilePolicies {
    if (-not (Get-Command -Name Invoke-DefaultUserNtuserScript -ErrorAction SilentlyContinue)) {
        Remove-DefaultUserWallpaperPolicyLegacy
        return
    }

    $null = Invoke-DefaultUserNtuserScript -HiveName 'HKU\NextGPUUninstallDefault' -ApplyKeys {
        param($HiveName)
        $explorer = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        foreach ($name in @('NoClose', 'NoStartMenuSubItems')) {
            Invoke-RegExe -RegArguments @('delete', $explorer, '/v', $name, '/f') | Out-Null
        }
        $system = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Policies\System"
        foreach ($name in @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')) {
            Invoke-RegExe -RegArguments @('delete', $system, '/v', $name, '/f') | Out-Null
        }
    }
    Write-Log 'Cleared Default user profile wallpaper/shutdown policy keys.' -Level OK
}

function Remove-DefaultUserWallpaperPolicyLegacy {
    $defaultNtuser = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $defaultNtuser)) {
        Write-Log "Default user hive not present: $defaultNtuser" -Level SKIP
        return
    }

    $tempHive = 'HKU\NextGPUWallpaperUninstall'
    $loaded = $false
    if ($PSCmdlet.ShouldProcess($defaultNtuser, 'Load Default user hive and remove wallpaper policy')) {
        try {
            $loadOut = cmd.exe /c "reg.exe load `"$tempHive`" `"$defaultNtuser`" 2>&1"
            if ($LASTEXITCODE -eq 0) {
                $loaded = $true
                Remove-PolicyValues -HiveRoot 'Registry::HKEY_USERS\NextGPUWallpaperUninstall'
            } else {
                Write-Log "Could not load Default user hive: $loadOut" -Level WARN
            }
        } finally {
            if ($loaded) {
                cmd.exe /c "reg.exe unload `"$tempHive`" 2>nul" | Out-Null
            }
        }
    }
}

function Remove-SunshineUserData {
    foreach ($path in @(
        'C:\Program Files\Sunshine',
        (Join-Path $env:ProgramData 'Sunshine'),
        (Join-Path $env:LOCALAPPDATA 'LizardByte\Sunshine'),
        (Join-Path $env:LOCALAPPDATA 'Sunshine')
    )) {
        Remove-PathSafe -Path $path
    }
}

function Remove-CloudflaredArtifacts {
    $cloudflaredExe = Join-Path $ScriptRoot 'cloudflared.exe'
    $nssmExe = Join-Path $ScriptRoot 'nssm\nssm-2.24\win64\nssm.exe'
    Stop-ProcessSafe -Names @('cloudflared')
    Remove-ServiceSafe -Name 'cloudflared' -NssmExe $nssmExe -CloudflaredExe $cloudflaredExe

    $eventLogKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\Cloudflared'
    if (Test-Path -LiteralPath $eventLogKey) {
        if ($PSCmdlet.ShouldProcess($eventLogKey, 'Remove Cloudflared event log registry key')) {
            Remove-Item -LiteralPath $eventLogKey -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log 'Removed Cloudflared Application event log key.' -Level OK
        }
    }
    Remove-PathSafe -Path (Join-Path $ScriptRoot 'cloudflared.exe')
    Remove-PathSafe -Path (Join-Path $env:USERPROFILE '.cloudflared')
    Remove-PathSafe -Path (Join-Path $env:ProgramData 'cloudflared')
}

function Remove-LocalUserNextGpu {
    if ($KeepLocalUsers) {
        Write-Log 'Keeping local user nextGPU (-KeepLocalUsers).' -Level SKIP
        return
    }
    $user = Get-LocalUser -Name 'nextGPU' -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Log 'Local user nextGPU not present.' -Level SKIP
        return
    }
    if ($PSCmdlet.ShouldProcess('nextGPU', 'Remove local user account')) {
        try {
            Remove-LocalUser -Name 'nextGPU' -ErrorAction Stop
            Write-Log 'Removed local user: nextGPU' -Level OK
        } catch {
            Write-Log "Failed to remove local user nextGPU: $($_.Exception.Message)" -Level WARN
        }
    }
}

function Clear-LogsDirectory {
    $logsPath = Join-Path $ScriptRoot 'logs'
    if (-not (Test-Path -LiteralPath $logsPath)) {
        Write-Log "Logs directory not present: $logsPath" -Level SKIP
        return
    }
    Get-ChildItem -LiteralPath $logsPath -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' } |
        ForEach-Object { Remove-PathSafe -Path $_.FullName }
}

function Stop-NextGpuWindowsServices {
    param([string]$NssmExe)
    foreach ($serviceName in @('auto-repair', 'gpu-heartbeat', 'gpu-sunshine', 'moonlight-web', 'cloudflared')) {
        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        if ($svc.Status -ne 'Stopped') {
            if ($PSCmdlet.ShouldProcess($serviceName, 'Stop service before file removal')) {
                try {
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(25))
                    Write-Log "Stopped service: $serviceName" -Level OK
                } catch {
                    Write-Log "Stop-Service $serviceName : $($_.Exception.Message)" -Level WARN
                }
            }
        }
    }
    Start-Sleep -Seconds 2
    Stop-ProcessSafe -Names @('web-server', 'sunshine', 'Sunshine', 'cloudflared', 'nssm')
}

function Remove-MoonlightWebDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Path not present: $Path" -Level SKIP
        return
    }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        Stop-ProcessSafe -Names @('web-server', 'nssm')
        Start-Sleep -Seconds 1
        Remove-PathSafe -Path $Path
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        Write-Log "moonlight-web still present (attempt $attempt/4); retrying after stop..." -Level WARN
        Start-Sleep -Seconds 2
    }
}

function Remove-RepoGeneratedArtifacts {
    $generatedPatterns = @(
        'domain.txt',
        'register_api_log.txt',
        'setup_log_*.txt',
        'wmi-probe.log',
        'VDD-VAD.log',
        'ViGEmBus.log',
        'heartbeat.log',
        'heartbeat-error.log',
        'auto-repair.log',
        'auto-repair-error.log',
        'checking-update.log',
        'moonlight-web.log',
        'moonlight-web-error.log',
        'sunshine.log',
        'sunshine-error.log',
        'network_copy.log',
        'sunshine.zip',
        'moonlight-theme.zip',
        'moonlight.zip',
        'nssm-2.24.zip'
    )
    foreach ($pattern in $generatedPatterns) {
        foreach ($basePath in @($ScriptRoot, (Join-Path $ScriptRoot 'logs'))) {
            if (-not (Test-Path -LiteralPath $basePath)) { continue }
            Get-ChildItem -LiteralPath $basePath -Filter $pattern -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-PathSafe -Path $_.FullName }
        }
    }

    foreach ($dir in @(
        'sunshine',
        'VDD-VAD-Install',
        'moonlight-tmp',
        'moonlight-web.backup',
        'moonlight-web',
        'nssm'
    )) {
        Remove-PathSafe -Path (Join-Path $ScriptRoot $dir)
    }

    Remove-PathSafe -Path (Join-Path $ScriptRoot 'NextGPU.exe')

    $publishExe = Join-Path $ScriptRoot 'apps\NextGPU\publish\NextGPU.exe'
    Remove-PathSafe -Path $publishExe

    Clear-LogsDirectory
}

function Remove-MachineEnvironmentValue {
    param([Parameter(Mandatory)][string]$Name)
    if ($PSCmdlet.ShouldProcess($Name, 'Remove machine environment variable')) {
        try {
            [Environment]::SetEnvironmentVariable($Name, $null, 'Machine')
            Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name $Name -ErrorAction SilentlyContinue
            Write-Log "Removed machine environment variable: $Name" -Level OK
        } catch {
            Write-Log "Failed to remove environment variable $Name : $($_.Exception.Message)" -Level WARN
        }
    }
}

function Remove-PnpDevicesByPattern {
    param(
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Label
    )
    try {
        $devices = @(Get-PnpDevice -ErrorAction Stop | Where-Object { $_.InstanceId -like $Pattern })
    } catch {
        Write-Log "Get-PnpDevice unavailable for $Label : $($_.Exception.Message)" -Level WARN
        return
    }

    if ($devices.Count -eq 0) {
        Write-Log "PnP device not present: $Label ($Pattern)" -Level SKIP
        return
    }

    foreach ($device in $devices) {
        if ($PSCmdlet.ShouldProcess($device.InstanceId, "Remove PnP device $Label")) {
            $null = & pnputil.exe /remove-device "$($device.InstanceId)" 2>&1
            Write-Log "Requested PnP device removal: $Label - $($device.InstanceId)"
        }
    }
}

function Get-PnpDriverRecords {
    $output = & pnputil.exe /enum-drivers 2>&1
    $records = New-Object System.Collections.Generic.List[object]
    $current = @{}

    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match '^\s*$') { continue }
        if ($text -match '^\s*Published Name\s*:\s*(.+)$') {
            if ($current.Count -gt 0) {
                $records.Add([pscustomobject]$current)
            }
            $current = @{ PublishedName = $Matches[1].Trim() }
            continue
        }
        if ($text -match '^\s*Original Name\s*:\s*(.+)$') { $current.OriginalName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Provider Name\s*:\s*(.+)$') { $current.ProviderName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Class Name\s*:\s*(.+)$') { $current.ClassName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Driver Version\s*:\s*(.+)$') { $current.DriverVersion = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Signer Name\s*:\s*(.+)$') { $current.SignerName = $Matches[1].Trim(); continue }
    }

    if ($current.Count -gt 0) {
        $records.Add([pscustomobject]$current)
    }
    return $records.ToArray()
}

function Remove-DriverPackagesByOriginalName {
    param(
        [Parameter(Mandatory)][string[]]$OriginalNames,
        [Parameter(Mandatory)][string]$Label
    )
    try {
        $drivers = @(Get-PnpDriverRecords | Where-Object {
            $original = if ($_.PSObject.Properties.Name -contains 'OriginalName') { $_.OriginalName } else { '' }
            $OriginalNames -contains $original
        })
    } catch {
        Write-Log "Failed to enumerate driver packages for $Label : $($_.Exception.Message)" -Level WARN
        return
    }

    if ($drivers.Count -eq 0) {
        Write-Log "Driver package not present: $Label" -Level SKIP
        return
    }

    foreach ($driver in $drivers) {
        if ($PSCmdlet.ShouldProcess($driver.PublishedName, "Delete driver package $Label")) {
            $null = & pnputil.exe /delete-driver $driver.PublishedName /uninstall /force 2>&1
            Write-Log "Requested driver package deletion: $Label - $($driver.PublishedName) ($($driver.OriginalName))"
        }
    }
}

function Uninstall-ViGEmBus {
    $productCode = '{9C581C76-2D68-40F8-AA6F-94D3C5215C05}'
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
    )
    $installed = $false
    foreach ($key in $uninstallKeys) {
        if (Test-Path -LiteralPath $key) { $installed = $true }
    }

    if ($installed) {
        Invoke-External -FilePath 'msiexec.exe' -Arguments @('/x', $productCode, '/qn', '/norestart') -Description 'ViGEmBus MSI uninstall' | Out-Null
    } else {
        Write-Log 'ViGEmBus MSI product not present in uninstall registry.' -Level SKIP
    }

    Remove-PnpDevicesByPattern -Pattern 'ROOT\ViGEmBus*' -Label 'ViGEmBus'
    Remove-DriverPackagesByOriginalName -OriginalNames @('ViGEmBus.inf') -Label 'ViGEmBus'
}

enum RegType {
    REG_NONE = 0
    REG_SZ = 1
    REG_EXPAND_SZ = 2
    REG_BINARY = 3
    REG_DWORD = 4
    REG_MULTI_SZ = 7
    REG_QWORD = 11
}

class GPRegistryPolicyEntry {
    [string]$KeyName
    [string]$ValueName
    [RegType]$ValueType
    [object]$ValueData

    GPRegistryPolicyEntry([string]$KeyName, [string]$ValueName, [RegType]$ValueType, [object]$ValueData) {
        $this.KeyName = $KeyName
        $this.ValueName = $ValueName
        $this.ValueType = $ValueType
        $this.ValueData = $ValueData
    }
}

function New-RegistryPolEntryBytes {
    param([GPRegistryPolicyEntry]$Entry)
    $bytes = New-Object System.Collections.Generic.List[byte]
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes('['))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes($Entry.KeyName + [char]0))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes($Entry.ValueName + [char]0))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    [void]$bytes.AddRange([System.BitConverter]::GetBytes([int32]$Entry.ValueType))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))

    switch ($Entry.ValueType) {
        { @([RegType]::REG_SZ, [RegType]::REG_EXPAND_SZ, [RegType]::REG_MULTI_SZ) -contains $_ } {
            $dataBytes = [System.Text.Encoding]::Unicode.GetBytes([string]$Entry.ValueData + [char]0)
            $dataSize = $dataBytes.Length
        }
        ([RegType]::REG_DWORD) {
            $dataBytes = [System.BitConverter]::GetBytes([int32]$Entry.ValueData)
            $dataSize = 4
        }
        default {
            $dataBytes = [byte[]]@()
            $dataSize = 0
        }
    }

    [void]$bytes.AddRange([System.BitConverter]::GetBytes($dataSize))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    if ($dataSize -gt 0) { [void]$bytes.AddRange($dataBytes) }
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(']'))
    return $bytes.ToArray()
}

function Read-RegistryPolFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $raw = [System.IO.File]::ReadAllBytes($Path)
    if ($raw.Length -lt 8) { return @() }

    $sig = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
    if ($sig -ne 'PReg') { throw "Invalid registry.pol header in $Path" }

    $entries = New-Object System.Collections.Generic.List[object]
    $index = 8
    while ($index -lt $raw.Length - 2) {
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne '[') { break }
        $index += 2

        $semi = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ';') { $semi = $i; break }
        }
        if ($semi -lt 0) { break }
        $keyName = [System.Text.Encoding]::Unicode.GetString($raw, $index, $semi - $index)
        $index = $semi + 2

        $semi = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ';') { $semi = $i; break }
        }
        if ($semi -lt 0) { break }
        $valueName = [System.Text.Encoding]::Unicode.GetString($raw, $index, $semi - $index)
        $index = $semi + 2

        $valueType = [System.BitConverter]::ToInt32($raw, $index)
        $index += 4
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne ';') { break }
        $index += 2

        $valueLength = [System.BitConverter]::ToInt32($raw, $index)
        $index += 4
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne ';') { break }
        $index += 2

        $valueData = $null
        if ($valueLength -gt 0 -and $valueType -eq [RegType]::REG_SZ) {
            $valueData = [System.Text.Encoding]::Unicode.GetString($raw, $index, $valueLength - 2)
            $index += $valueLength
        } elseif ($valueType -eq [RegType]::REG_DWORD) {
            $valueData = [System.BitConverter]::ToInt32($raw, $index)
            $index += 4
        } else {
            $index += [Math]::Max(0, $valueLength)
        }

        $close = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ']') { $close = $i; break }
        }
        if ($close -lt 0) { break }
        $index = $close + 2

        if ($valueName) {
            $entries.Add([GPRegistryPolicyEntry]::new($keyName, $valueName, [RegType]$valueType, $valueData))
        }
    }
    return $entries.ToArray()
}

function Write-RegistryPolFile {
    param(
        [string]$Path,
        [GPRegistryPolicyEntry[]]$Entries
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]0x67655250)
    $bw.Write([uint32]1)
    foreach ($entry in $Entries) {
        $bw.Write((New-RegistryPolEntryBytes -Entry $entry))
    }
    $bw.Close()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
}

function Remove-WallpaperEntriesFromRegistryPol {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "registry.pol not present: $Path" -Level SKIP
        return
    }

    $policyKey = 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    $wallpaperNames = @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')

    try {
        $existing = @(Read-RegistryPolFile -Path $Path)
        $kept = @($existing | Where-Object {
            -not ($_.KeyName -eq $policyKey -and $wallpaperNames -contains $_.ValueName)
        })
        $removedCount = $existing.Count - $kept.Count
        if ($removedCount -le 0) {
            Write-Log "No nextGPU wallpaper entries in registry.pol: $Path" -Level SKIP
            return
        }
        if ($PSCmdlet.ShouldProcess($Path, "Remove $removedCount wallpaper policy entries")) {
            Write-RegistryPolFile -Path $Path -Entries $kept
            Write-Log "Removed $removedCount wallpaper policy entries from: $Path" -Level OK
        }
    } catch {
        Write-Log "Failed to update registry.pol $Path : $($_.Exception.Message)" -Level WARN
    }
}

function Remove-PolicyValues {
    param([Parameter(Mandatory)][string]$HiveRoot)
    $path = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "Wallpaper policy key not present: $path" -Level SKIP
        return
    }
    foreach ($name in @('Wallpaper', 'WallpaperStyle', 'TileWallpaper')) {
        if (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess("$path\$name", 'Remove wallpaper policy value')) {
                Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue
                Write-Log "Removed wallpaper policy value: $path\$name" -Level OK
            }
        }
    }
}

function Remove-LockScreenSigninWallpaperPolicy {
    $valuesByPath = @{
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' = @('LockScreenImage')
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' = @(
            'LockScreenImagePath',
            'LockScreenImageUrl',
            'LockScreenImageStatus',
            'DesktopImagePath',
            'DesktopImageUrl',
            'DesktopImageStatus'
        )
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' = @('DisableLogonBackgroundImage')
    }

    foreach ($path in $valuesByPath.Keys) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log "Lock/sign-in wallpaper policy key not present: $path" -Level SKIP
            continue
        }
        foreach ($name in $valuesByPath[$path]) {
            if (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue) {
                if ($PSCmdlet.ShouldProcess("$path\$name", 'Remove lock/sign-in wallpaper value')) {
                    Remove-ItemProperty -LiteralPath $path -Name $name -ErrorAction SilentlyContinue
                    Write-Log "Removed lock/sign-in wallpaper value: $path\$name" -Level OK
                }
            }
        }
    }
}

function Remove-ShutdownEntriesFromRegistryPol {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "registry.pol not present: $Path" -Level SKIP
        return
    }

    $policyKey = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    $shutdownNames = @('NoClose', 'NoStartMenuSubItems')

    try {
        $existing = @(Read-RegistryPolFile -Path $Path)
        $kept = @($existing | Where-Object {
            -not ($_.KeyName -eq $policyKey -and $shutdownNames -contains $_.ValueName)
        })
        $removedCount = $existing.Count - $kept.Count
        if ($removedCount -le 0) {
            Write-Log "No nextGPU shutdown entries in registry.pol: $Path" -Level SKIP
            return
        }
        if ($PSCmdlet.ShouldProcess($Path, "Remove $removedCount shutdown policy entries")) {
            Write-RegistryPolFile -Path $Path -Entries $kept
            Write-Log "Removed $removedCount shutdown policy entries from: $Path" -Level OK
        }
    } catch {
        Write-Log "Failed to update registry.pol $Path : $($_.Exception.Message)" -Level WARN
    }
}

function Restore-DefaultShutdownPrivileges {
    $cfgPath = Join-Path $env:TEMP ("nextgpu_secrestore_{0}.inf" -f [guid]::NewGuid().ToString('n'))
    $dbPath = Join-Path $env:TEMP ("nextgpu_secdb_{0}.sdb" -f [guid]::NewGuid().ToString('n'))
    $defaultPriv = '*S-1-5-32-544,*S-1-5-32-545,*S-1-5-32-551'

    try {
        $export = Start-Process -FilePath 'secedit.exe' -ArgumentList @('/export', '/cfg', $cfgPath, '/quiet') -Wait -PassThru -WindowStyle Hidden
        if ($export.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $cfgPath)) {
            Write-Log 'secedit export failed during shutdown policy restore.' -Level WARN
            return
        }

        $lines = Get-Content -LiteralPath $cfgPath -Encoding Unicode
        $output = New-Object System.Collections.Generic.List[string]
        $inPrivilege = $false
        foreach ($line in $lines) {
            if ($line -match '^\s*\[Privilege Rights\]') {
                $inPrivilege = $true
                [void]$output.Add($line)
                continue
            }
            if ($inPrivilege -and $line -match '^\s*\[') { $inPrivilege = $false }
            if ($inPrivilege -and $line -match '^\s*SeShutdownPrivilege\s*=') {
                [void]$output.Add("SeShutdownPrivilege = $defaultPriv")
                continue
            }
            if ($inPrivilege -and $line -match '^\s*SeRemoteShutdownPrivilege\s*=') {
                [void]$output.Add("SeRemoteShutdownPrivilege = $defaultPriv")
                continue
            }
            [void]$output.Add($line)
        }
        Set-Content -LiteralPath $cfgPath -Value $output -Encoding Unicode
        if (Test-Path -LiteralPath $dbPath) { Remove-Item -LiteralPath $dbPath -Force }
        $configure = Start-Process -FilePath 'secedit.exe' -ArgumentList @(
            '/configure', '/db', $dbPath, '/cfg', $cfgPath, '/areas', 'USER_RIGHTS'
        ) -Wait -PassThru -WindowStyle Hidden
        if ($configure.ExitCode -eq 0) {
            Write-Log 'Restored default shutdown user rights (Users group).' -Level OK
        } else {
            Write-Log "secedit restore exit code: $($configure.ExitCode)" -Level WARN
        }
    } catch {
        Write-Log "Shutdown privilege restore failed: $($_.Exception.Message)" -Level WARN
    } finally {
        Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $dbPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-ShutdownPolicy {
    Remove-ShutdownEntriesFromRegistryPol -Path (Join-Path $env:SystemRoot 'System32\GroupPolicy\User\registry.pol')

    $explorer = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    foreach ($name in @('NoClose', 'NoStartMenuSubItems')) {
        if (Get-ItemProperty -LiteralPath $explorer -Name $name -ErrorAction SilentlyContinue) {
            Remove-ItemProperty -LiteralPath $explorer -Name $name -ErrorAction SilentlyContinue
            Write-Log "Removed HKCU $name" -Level OK
        }
    }

    Restore-DefaultShutdownPrivileges

    if ($PSCmdlet.ShouldProcess('Local Group Policy', 'Run gpupdate /force /target:user')) {
        $null = & gpupdate.exe /force /target:user 2>&1
        Write-Log "gpupdate /target:user exit code: $LASTEXITCODE"
    }
}

function Remove-WallpaperPolicy {
    Remove-WallpaperEntriesFromRegistryPol -Path (Join-Path $env:SystemRoot 'System32\GroupPolicy\User\registry.pol')
    Remove-WallpaperEntriesFromRegistryPol -Path (Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\registry.pol')
    Remove-PolicyValues -HiveRoot 'HKCU:'
    Remove-PolicyValues -HiveRoot 'HKLM:'
    Remove-DefaultUserProfilePolicies
    Remove-LockScreenSigninWallpaperPolicy
    Remove-PathSafe -Path 'C:\Users\Public\Wallpaper\nextgputobu.jpeg'

    if ($PSCmdlet.ShouldProcess('Local Group Policy', 'Run gpupdate /force /target:user')) {
        $null = & gpupdate.exe /force /target:user 2>&1
        Write-Log "gpupdate /target:user exit code: $LASTEXITCODE"
    }
}

function Remove-PlayniteAndBypassStack {
    param([string]$RepoRoot)

    $uninstallScript = Join-Path $RepoRoot 'PlayNiteWatcher\Uninstall-PlayniteBypass.ps1'
    if (-not (Test-Path -LiteralPath $uninstallScript)) {
        Write-Log "Uninstall-PlayniteBypass.ps1 not found at $uninstallScript" -Level SKIP
        return
    }

    if ($PSCmdlet.ShouldProcess('Playnite, RunAsTool, and Game Shortcuts', 'Run bypass/Playnite uninstall')) {
        Stop-ProcessSafe -Names @('Playnite.DesktopApp', 'Playnite.FullscreenApp', 'RunAsTool', 'RunAsTool_x64')
        try {
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', $uninstallScript,
                '-Force', '-RemovePlayniteInstall'
            ) -Wait -PassThru -WindowStyle Hidden
            if ($proc.ExitCode -eq 0) {
                Write-Log 'Removed Playnite portable install, RunAsTool, and Game Shortcuts bypass config.' -Level OK
            }
            else {
                Write-Log "Uninstall-PlayniteBypass.ps1 exit code: $($proc.ExitCode)" -Level WARN
            }
        }
        catch {
            Write-Log "Playnite/RunAsTool uninstall failed: $($_.Exception.Message)" -Level WARN
        }
    }
}

function Remove-Sunshine {
    Stop-ProcessSafe -Names @('sunshine', 'Sunshine')
    $sunshineInstall = 'C:\Program Files\Sunshine'
    $uninstaller = Join-Path $sunshineInstall 'uninstall.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        Invoke-External -FilePath $uninstaller -Arguments @('/S') -Description 'Sunshine silent uninstall' | Out-Null
        Start-Sleep -Seconds 3
    } else {
        Write-Log "Sunshine uninstaller not present: $uninstaller" -Level SKIP
    }
    Remove-SunshineUserData
}

function Remove-Drivers {
    $vddVadCommon = Join-Path $ScriptRoot 'scripts\drivers\VddVadCommon.ps1'
    if (-not (Test-Path -LiteralPath $vddVadCommon)) {
        Write-Log "VddVadCommon.ps1 not found at $vddVadCommon" -Level WARN
        return
    }
    . $vddVadCommon

    $logAction = {
        param([string]$Message, [string]$Level)
        Write-Log -Message $Message -Level $Level
    }

    if ($PSCmdlet.ShouldProcess('VDD/VAD/VB-CABLE stack', 'Remove drivers and PnP devices')) {
        Write-Log 'Removing VDD, VAD, and VB-CABLE drivers...'
        Remove-VddVadStack -IncludeVbCable -RemoveVddSettings -LogAction $logAction
        $absent = Test-VddVadAbsent -IncludeVbCable
        if (-not $absent.AllClear) {
            Write-Log 'Remnant VDD/VAD/VB-CABLE devices found; running second removal pass...' -Level WARN
            Remove-VddVadStack -IncludeVbCable -LogAction $logAction
            $absent = Test-VddVadAbsent -IncludeVbCable
        }
        if (-not $absent.AllClear) {
            Write-Log "VDD/VAD/VB-CABLE still visible in PnP: $($absent.Summary). Reboot recommended." -Level WARN
            foreach ($dev in $absent.Remaining) {
                Write-Log "  Remaining: $($dev.InstanceId) [$($dev.FriendlyName)]" -Level WARN
            }
        }
        else {
            Write-Log 'VDD/VAD/VB-CABLE removed from PnP (AllClear).' -Level OK
        }
    }

    Uninstall-ViGEmBus
}

if (-not (Test-Admin)) {
    Write-Log 'Administrator privileges required; requesting elevation...'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    if ($Force) { $args += '-Force' }
    if ($SkipDrivers) { $args += '-SkipDrivers' }
    if ($SkipGeneratedFiles) { $args += '-SkipGeneratedFiles' }
    if ($SkipPlaynite) { $args += '-SkipPlaynite' }
    if ($KeepLocalUsers) { $args += '-KeepLocalUsers' }
    if ($RepoRoot) { $args += '-RepoRoot'; $args += "`"$RepoRoot`"" }
    if ($WhatIfPreference) { $args += '-WhatIf' }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
}

Write-Log '========== nextGPU uninstall started =========='
Write-Log "ScriptRoot=$ScriptRoot"
Write-Log "LogPath=$LogPath"

if (-not $Force -and -not $WhatIfPreference) {
    Write-Warning 'This will remove nextGPU services, installed components, drivers, scheduled tasks, Playnite/RunAsTool/Game Shortcuts, policy settings, environment variables, and generated logs.'
    $answer = Read-Host 'Type UNINSTALL to continue'
    if ($answer -ne 'UNINSTALL') {
        Write-Log 'Uninstall cancelled by user.' -Level WARN
        exit 2
    }
}

$nssmExe = Join-Path $ScriptRoot 'nssm\nssm-2.24\win64\nssm.exe'
$cloudflaredExe = Join-Path $ScriptRoot 'cloudflared.exe'

Write-Log "Repo root: $ScriptRoot"
Write-Log 'Stopping nextGPU Windows services (releases log locks)...'
Stop-NextGpuWindowsServices -NssmExe $nssmExe

Write-Log 'Releasing stale Default-user registry hives...'
Release-StaleDefaultUserHivesSafe

Write-Log 'Removing Windows services...'
foreach ($serviceName in @('auto-repair', 'gpu-heartbeat', 'gpu-sunshine', 'moonlight-web')) {
    Remove-ServiceSafe -Name $serviceName -NssmExe $nssmExe -CloudflaredExe ''
}
    Stop-ProcessSafe -Names @('sunshine', 'Sunshine', 'web-server', 'cloudflared', 'curl', 'nssm', 'Playnite.DesktopApp', 'Playnite.FullscreenApp', 'RunAsTool', 'RunAsTool_x64')
Start-Sleep -Seconds 2

Write-Log 'Unmounting per-user S3 storage (if mounted)...'
$unmountScript = Resolve-NextGpuRepoPath @('scripts', 'runtime', 'Unmount-UserStorage.ps1')
if (Test-Path -LiteralPath $unmountScript) {
    try {
        $null = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $unmountScript -Quiet 2>&1
        Write-Log "Ran Unmount-UserStorage.ps1 from $unmountScript" -Level OK
    } catch {
        Write-Log "Unmount-UserStorage.ps1 failed: $($_.Exception.Message)" -Level WARN
    }
} else {
    Write-Log "Unmount-UserStorage.ps1 not found at $unmountScript" -Level SKIP
}

Write-Log 'Removing scheduled tasks...'
Remove-AllNextGpuScheduledTasks

if ($SkipPlaynite) {
    Write-Log 'Playnite / RunAsTool / Game Shortcuts removal skipped by -SkipPlaynite.' -Level SKIP
}
else {
    Write-Log 'Removing Playnite, RunAsTool, and Game Shortcuts bypass stack...'
    Remove-PlayniteAndBypassStack -RepoRoot $ScriptRoot
}

Write-Log 'Removing Sunshine...'
Remove-Sunshine

Write-Log 'Removing Moonlight Web and NSSM files...'
Remove-MoonlightWebDirectory -Path (Join-Path $ScriptRoot 'moonlight-web')

Write-Log 'Removing Cloudflared...'
Remove-CloudflaredArtifacts

if ($SkipDrivers) {
    Write-Log 'Driver removal skipped by -SkipDrivers.' -Level SKIP
} else {
    Write-Log 'Removing VDD/VAD and ViGEmBus drivers...'
    Remove-Drivers
}

Write-Log 'Removing shutdown lock policy...'
Remove-ShutdownPolicy

Write-Log 'Removing wallpaper Group Policy changes...'
Remove-WallpaperPolicy

Write-Log 'Removing CLOUDFLARE_TUNNEL_TOKEN...'
Remove-MachineEnvironmentValue -Name 'CLOUDFLARE_TUNNEL_TOKEN'

Write-Log 'Removing per-user S3 storage config and secrets...'
Remove-MachineEnvironmentValue -Name 'NEXTGPU_USER_S3_ACCESS_KEY'
Remove-MachineEnvironmentValue -Name 'NEXTGPU_USER_S3_SECRET_KEY'
foreach ($pdPath in @(
        (Join-Path $env:ProgramData 'nextGPU\rclone'),
        (Join-Path $env:ProgramData 'nextGPU\secrets\user-s3.env'),
        (Join-Path $env:ProgramData 'nextGPU\user-storage.json')
    )) {
    Remove-PathSafe -Path $pdPath
}

if ($SkipGeneratedFiles) {
    Write-Log 'Generated file removal skipped by -SkipGeneratedFiles.' -Level SKIP
} else {
    Write-Log 'Removing generated files, downloads, and logs...'
    Remove-RepoGeneratedArtifacts
}

Write-Log 'Removing local user nextGPU (if present)...'
Remove-LocalUserNextGpu

Write-Log 'Final release of Default-user registry hives...'
Release-StaleDefaultUserHivesSafe

Write-Log '========== nextGPU uninstall finished ==========' -Level OK
Write-Log 'Reboot is recommended after driver and service removal.'
exit 0

