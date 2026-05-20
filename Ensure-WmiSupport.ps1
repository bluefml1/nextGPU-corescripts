#Requires -Version 5.1
# Probes WMIC/CIM, optionally installs WMIC only when the OS image supports it.
# Exit 0 = inventory possible (WMIC and/or CIM). Exit 1 = neither works.
[CmdletBinding()]
param(
    [string]$LogPath = ""
)

$ErrorActionPreference = 'Continue'

function Write-ProbeLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    if ($LogPath) { Add-Content -Path $LogPath -Value $line -Encoding UTF8 }
    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'OK' { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Test-WmicExecutable {
    $exe = Join-Path $env:SystemRoot 'System32\wbem\wmic.exe'
    if (-not (Test-Path -LiteralPath $exe)) { return $false }
    $null = & $exe os get caption 2>&1
    return ($LASTEXITCODE -eq 0)
}

function Test-CimInventory {
    try {
        $null = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Get-WmicCapabilityInfo {
    $result = [ordered]@{
        Listed       = $false
        State        = 'Unknown'
        InstallBytes = -1
        CanInstall   = $false
    }
    try {
        $cap = Get-WindowsCapability -Online -Name 'WMIC~~~~' -ErrorAction Stop
        $result.Listed = $true
        $result.State = [string]$cap.State
    } catch {
        return $result
    }

  $dismOut = & dism.exe /Online /Get-CapabilityInfo /CapabilityName:WMIC 2>&1 | Out-String
    if ($dismOut -match 'Install Size\s*:\s*(\d+)\s*bytes') {
        $result.InstallBytes = [int]$Matches[1]
    }
    if ($dismOut -match 'State\s*:\s*(.+)') {
        $dismState = $Matches[1].Trim()
        if ($result.State -eq 'Unknown') { $result.State = $dismState }
    }

    # Install only when payload exists and feature is not already OK
    $hasPayload = ($result.InstallBytes -gt 0)
    $state = $result.State
    $notInstallable = @('Installed', 'InstallPending', 'NotPresent', 'Not Present')
    $result.CanInstall = $hasPayload -and ($notInstallable -notcontains $state)
    return $result
}

function Repair-WmiRepository {
    Write-ProbeLog 'Repairing WMI repository (winmgmt)...'
    $null = & net.exe stop winmgmt /y 2>&1
    Start-Sleep -Seconds 2
    $wbem = Join-Path $env:SystemRoot 'System32\wbem'
    Push-Location $wbem
    try {
        Get-ChildItem -Filter '*.dll' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = & regsvr32.exe /s $_.FullName 2>&1
        }
        Get-ChildItem -Filter '*.mof' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = & mofcomp.exe $_.FullName 2>&1
        }
        Get-ChildItem -Filter '*.mfl' -ErrorAction SilentlyContinue | ForEach-Object {
            $null = & mofcomp.exe $_.FullName 2>&1
        }
    } finally {
        Pop-Location
    }
    $null = & net.exe start winmgmt 2>&1
    Start-Sleep -Seconds 3
}

function Try-InstallWmicCapability {
    param([hashtable]$CapInfo)
    if (-not $CapInfo.CanInstall) {
        Write-ProbeLog "WMIC optional feature not installable (State=$($CapInfo.State), InstallBytes=$($CapInfo.InstallBytes))." -Level WARN
        return $false
    }
    Write-ProbeLog 'Installing WMIC optional feature (WMIC~~~~)...'
    try {
        $add = Add-WindowsCapability -Online -Name 'WMIC~~~~' -ErrorAction Stop
        Write-ProbeLog "Add-WindowsCapability returned: $($add.State)" -Level OK
    } catch {
        Write-ProbeLog "Add-WindowsCapability failed: $($_.Exception.Message)" -Level WARN
        $null = & dism.exe /Online /Add-Capability /CapabilityName:WMIC /NoRestart 2>&1
    }
    if ((Get-WmicCapabilityInfo).State -eq 'InstallPending') {
        Write-ProbeLog 'WMIC install is pending — reboot may be required before wmic.exe works.' -Level WARN
    }
    return $true
}

Write-ProbeLog '========== WMI / WMIC probe =========='
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
    Write-ProbeLog "OS: $($os.Caption) (build $($os.BuildNumber))"
}

if (Test-WmicExecutable) {
    Write-ProbeLog 'WMIC CLI is working.' -Level OK
    exit 0
}

Write-ProbeLog 'WMIC CLI not working; analyzing optional feature...'
$cap = Get-WmicCapabilityInfo
Write-ProbeLog "WMIC capability: Listed=$($cap.Listed) State=$($cap.State) InstallBytes=$($cap.InstallBytes) CanInstall=$($cap.CanInstall)"

if ($cap.State -eq 'InstallPending') {
    Write-ProbeLog 'WMIC already InstallPending — skip install attempt (reboot may complete it).' -Level WARN
} elseif ($cap.CanInstall) {
    Try-InstallWmicCapability -CapInfo $cap | Out-Null
} else {
    Write-ProbeLog 'Skipping WMIC install (image has no WMIC payload or Not Present).' -Level WARN
}

$wmicExe = Join-Path $env:SystemRoot 'System32\wbem\wmic.exe'
if ((Test-Path -LiteralPath $wmicExe) -and -not (Test-WmicExecutable)) {
    Repair-WmiRepository
}

if (Test-WmicExecutable) {
    Write-ProbeLog 'WMIC CLI is working after repair/install.' -Level OK
    exit 0
}

if (Test-CimInventory) {
    Write-ProbeLog 'WMIC unavailable; using PowerShell CIM for system inventory (OK).' -Level OK
    exit 0
}

Write-ProbeLog 'Neither WMIC nor CIM inventory works — WMI stack may be broken.' -Level ERROR
exit 1
