#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Register gxxapphelper.exe as a NextGPUService launch companion of Garena.exe.
.DESCRIPTION
    Upserts the Garena.exe entry in %ProgramData%\nextGPU\launch-companions.json via
    scripts\runtime\Update-LaunchCompanions.ps1 (admin-only ACL; other apps' rows are kept).
    When NextGPUService elevates Garena.exe as NextGPU-Admin, it first starts
    gxxapphelper.exe as NextGPU-Admin in the same session.

    Also retires the legacy helper tasks (SYSTEM boot task / logon task) and stops
    any SYSTEM-owned gxxapphelper so it does not conflict with the NextGPU-Admin one.

    The GarenaPlatform Windows service (gxxsvc.exe) is only reported by default.
    Pass -SetGarenaServiceManual to stop it and set StartMode=Manual.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ClientDir,
    [int]$DelayMs = 2000,
    [switch]$SetGarenaServiceManual
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'GarenaAppHelper-Common.ps1')

$script:LegacyTaskNames = @('nextGPU-GarenaPlatformService', 'nextGPU-GarenaAppHelper')
$script:MainExeName = 'Garena.exe'

function Write-GarenaCompanionLog {
    param([string]$Message)
    Write-Host $Message
    try {
        $logDir = Join-Path $env:ProgramData 'nextGPU\logs'
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
        Add-Content -LiteralPath (Join-Path $logDir 'garena-launch-companion.log') -Value $line -Encoding UTF8
    }
    catch { }
}

function Invoke-UpdateLaunchCompanions {
    <# Runs Update-LaunchCompanions.ps1 in a child PowerShell (it is not StrictMode-clean); returns stdout lines. #>
    param([string[]]$Arguments)

    $updateScript = Join-Path $PSScriptRoot '..\runtime\Update-LaunchCompanions.ps1'
    if (-not (Test-Path -LiteralPath $updateScript)) {
        throw "Update-LaunchCompanions.ps1 not found: $updateScript"
    }
    $lines = & {
        $ErrorActionPreference = 'Continue'
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $updateScript @Arguments 2>&1 |
            ForEach-Object { "$_" }
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($lines) }
}

function Save-GarenaLaunchCompanionEntry {
    <# Upserts Garena.exe -> gxxapphelper.exe and keeps every other app's companions. #>
    param(
        [Parameter(Mandatory)][string]$HelperExe,
        [Parameter(Mandatory)][string]$SearchDir,
        [int]$Delay
    )

    $marker = '@@LAUNCH_COMPANIONS_STATUS@@'
    $helperName = Split-Path -Leaf $HelperExe
    $merged = New-Object System.Collections.Generic.List[object]

    $status = Invoke-UpdateLaunchCompanions -Arguments @('-StatusOnly')
    $statusLine = @($status.Lines | Where-Object { $_.StartsWith($marker) }) | Select-Object -Last 1
    if ($status.ExitCode -ne 0 -or -not $statusLine) {
        Write-GarenaCompanionLog "[WARN] Could not read existing launch companions (exit $($status.ExitCode)); saving the Garena row only."
    }
    else {
        $parsed = $statusLine.Substring($marker.Length) | ConvertFrom-Json
        foreach ($row in @($parsed)) {
            if ($null -eq $row) { continue }
            if ($row.mainExe -ieq $script:MainExeName -and $row.exeName -ieq $helperName) { continue }
            [void]$merged.Add([ordered]@{
                    mainExe   = $row.mainExe
                    exeName   = $row.exeName
                    exe       = $row.exe
                    searchDir = $row.searchDir
                    delayMs   = $row.delayMs
                })
        }
    }
    [void]$merged.Add([ordered]@{
            mainExe   = $script:MainExeName
            exeName   = $helperName
            exe       = $HelperExe
            searchDir = $SearchDir
            delayMs   = $Delay
        })

    $tempJson = Join-Path $env:TEMP ("nextgpu-launch-companions-{0}.json" -f [guid]::NewGuid().ToString('N'))
    try {
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($tempJson, (ConvertTo-Json -InputObject @($merged.ToArray()) -Depth 4), $utf8NoBom)
        $save = Invoke-UpdateLaunchCompanions -Arguments @('-SaveJson', $tempJson)
        if ($save.ExitCode -ne 0) {
            throw "Update-LaunchCompanions.ps1 -SaveJson failed (exit $($save.ExitCode)): $(($save.Lines | Select-Object -Last 5) -join ' | ')"
        }
    }
    finally {
        Remove-Item -LiteralPath $tempJson -Force -ErrorAction SilentlyContinue
    }
    Write-GarenaCompanionLog "[OK] $script:MainExeName companion -> $HelperExe (searchDir $SearchDir) in $env:ProgramData\nextGPU\launch-companions.json"
}

function Remove-GarenaLegacyHelperTasks {
    foreach ($taskName in $script:LegacyTaskNames) {
        $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        if ($existing) {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            Write-GarenaCompanionLog "[*] Removed legacy task: $taskName"
        }
    }
}

function Stop-SystemOwnedGarenaHelper {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='gxxapphelper.exe'" -ErrorAction SilentlyContinue)
    foreach ($proc in $procs) {
        $owner = $null
        try {
            $owner = Invoke-CimMethod -InputObject $proc -MethodName GetOwner -ErrorAction Stop
        }
        catch { }
        $isSystem = ($proc.SessionId -eq 0) -or ($owner -and $owner.User -ieq 'SYSTEM')
        if (-not $isSystem) { continue }
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-GarenaCompanionLog "[*] Stopped SYSTEM gxxapphelper PID $($proc.ProcessId)"
        }
        catch {
            Write-GarenaCompanionLog "[WARN] Could not stop gxxapphelper PID $($proc.ProcessId): $($_.Exception.Message)"
        }
    }
}

function Update-GarenaPlatformWindowsService {
    param([switch]$SetManual)

    $services = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
        Where-Object { $_.PathName -match '(?i)gxx|garena' -or $_.Name -match '(?i)garena' })
    if ($services.Count -eq 0) {
        Write-GarenaCompanionLog '[*] No Garena Windows service found.'
        return
    }

    foreach ($svc in $services) {
        Write-GarenaCompanionLog "[*] Garena service: $($svc.Name) StartMode=$($svc.StartMode) State=$($svc.State) Path=$($svc.PathName)"
        if (-not $SetManual) { continue }
        try {
            if ($svc.State -eq 'Running') {
                Stop-Service -Name $svc.Name -Force -ErrorAction Stop
            }
            Set-Service -Name $svc.Name -StartupType Manual -ErrorAction Stop
            Write-GarenaCompanionLog "[OK] $($svc.Name) stopped and set to Manual."
        }
        catch {
            Write-GarenaCompanionLog "[WARN] Could not change $($svc.Name): $($_.Exception.Message)"
        }
    }
}

$clientFull = Resolve-GarenaPathSafe -Path $ClientDir
if (-not $clientFull -or -not (Test-Path -LiteralPath $clientFull -PathType Container)) {
    throw "Garena client directory not found: $ClientDir"
}

$helperExe = Get-GarenaAppHelperExePath -SearchClientDir $clientFull -PreferClientSearch
$helperExe = Resolve-GarenaPathSafe -Path $helperExe
if (-not $helperExe -or -not (Test-Path -LiteralPath $helperExe -PathType Leaf)) {
    throw "gxxapphelper.exe not found under: $clientFull (check version subfolder or 'Garena platform service.lnk')."
}

Save-GarenaAppHelperPath -HelperExePath $helperExe -ClientDir $clientFull
Save-GarenaLaunchCompanionEntry -HelperExe $helperExe -SearchDir $clientFull -Delay ([Math]::Max(0, [Math]::Min($DelayMs, 2000)))
Remove-GarenaLegacyHelperTasks
Stop-SystemOwnedGarenaHelper
Update-GarenaPlatformWindowsService -SetManual:$SetGarenaServiceManual

Write-Host ''
Write-Host '[OK] Garena launch companion registered.' -ForegroundColor Green
Write-Host "  Helper: $helperExe" -ForegroundColor DarkGray
Write-Host '  NextGPUService starts gxxapphelper as NextGPU-Admin before each elevated Garena.exe launch.' -ForegroundColor DarkGray
