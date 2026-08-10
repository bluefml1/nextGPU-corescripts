#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Idempotently installs NextGPUService as a Windows Service.
#>
param(
    [string]$BinaryPath = "$env:ProgramFiles\NextGPU\Service\NextGPUService.exe",
    [string]$LauncherPath = "$env:ProgramFiles\NextGPU\Launcher\NextGPU.Launcher.exe",
    [string]$ServiceName = "NextGPUService",
    [string]$DisplayName = "NextGPU Game Launcher Service",
    [string]$Description = "Launches games in the correct user session with optional elevation via nextGPU-Admin credentials.",
    [string]$RepoRoot = "",
    [switch]$KeepLegacyLauncher
)

$ErrorActionPreference = "Stop"

$scriptName = Split-Path -Leaf $PSCommandPath
$logFile = "$env:TEMP\Install-NextGPUService_$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts  $Msg" | Tee-Object -FilePath $logFile -Append
}

Write-Log "=== $scriptName starting ==="
Write-Log "Binary: $BinaryPath"
Write-Log "Launcher: $LauncherPath"
Write-Log "Service: $ServiceName"

if (-not (Test-Path $BinaryPath)) {
    Write-Log "ERROR: Binary not found at $BinaryPath"
    Write-Log "Build with: dotnet publish apps/NextGPU/NextGPU.Service -c Release -o 'C:\Program Files\NextGPU\Service'"
    throw "NextGPUService.exe not found at $BinaryPath"
}

# Desktop broker: service CreateProcessAsUser(Launcher) as NextGPU-Admin; launcher
# starts the real app via CreateProcessW / ShellExecuteEx.
$launcherDir = Split-Path -Parent $LauncherPath
if (-not (Test-Path $LauncherPath)) {
    # Allow copying from a sibling publish folder next to the service binary.
    $candidate = Join-Path (Split-Path -Parent $BinaryPath) "..\Launcher\NextGPU.Launcher.exe"
    $candidate = [IO.Path]::GetFullPath($candidate)
    if (Test-Path $candidate) {
        Write-Log "Copying launcher from $candidate"
        New-Item -ItemType Directory -Path $launcherDir -Force | Out-Null
        Copy-Item $candidate $LauncherPath -Force
    }
}
if (-not (Test-Path $LauncherPath)) {
    Write-Log "ERROR: Launcher not found at $LauncherPath"
    Write-Log "Build with: dotnet publish apps/NextGPU/NextGPU.Launcher -c Release -o 'C:\Program Files\NextGPU\Launcher'"
    throw "NextGPU.Launcher.exe not found at $LauncherPath"
}
Write-Log "Launcher present: $LauncherPath"

# Tighten the ACL on admincred.dat so only SYSTEM can read it. The service runs as
# SYSTEM and decrypts the credential itself; Launcher.exe inherits Admin token and
# does not need admincred.dat. LocalMachine-scope DPAPI requires SYSTEM-equivalent
# access to the master key.
$credPath = "$env:ProgramData\nextGPU\admincred.dat"
if (Test-Path $credPath) {
    Write-Log "Tightening ACL on $credPath (SYSTEM:F only)"
    $credAcl = Get-Acl -Path $credPath
    # Disable inheritance and clear inherited rules
    $credAcl.SetAccessRuleProtection($true, $false)
    $credSystemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        [System.Security.Principal.SecurityIdentifier]"S-1-5-18",
        [System.Security.AccessControl.FileSystemRights]"FullControl",
        [System.Security.AccessControl.InheritanceFlags]"None",
        [System.Security.AccessControl.PropagationFlags]"None",
        [System.Security.AccessControl.AccessControlType]"Allow")
    $credAcl.SetAccessRule($credSystemRule)
    Set-Acl -Path $credPath -AclObject $credAcl
    Write-Log "ACL on admincred.dat set to SYSTEM:F only"
} else {
    Write-Log "NOTE: $credPath not found. Run the credential-setup tool (e.g. Set-AdminCred.ps1) to create it before elevated launches will work."
}

$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Log "Service '$ServiceName' exists. Stopping and deleting..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    sc.exe delete $ServiceName 2>$null | Out-Null
    Start-Sleep -Seconds 2
}

Write-Log "Creating service..."
$create = sc.exe create $ServiceName binPath= $BinaryPath start= auto DisplayName= $DisplayName
if ($LASTEXITCODE -ne 0) {
    Write-Log "ERROR: sc.exe create failed: $create"
    throw "sc.exe create failed"
}
Write-Log "Service created."

Write-Log "Setting recovery actions..."
sc.exe failure $ServiceName reset= 86400 actions= restart/60000/restart/60000/restart/60000 | Out-Null

Write-Log "Writing registry metadata..."
$regPath = "HKLM:\SOFTWARE\NextGPU\Service"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
Set-ItemProperty -Path $regPath -Name PipeName -Value "NextGPUControl"
Set-ItemProperty -Path $regPath -Name InstallPath -Value $BinaryPath
Set-ItemProperty -Path $regPath -Name LogPath -Value ""
Set-ItemProperty -Path $regPath -Name Version -Value "1.0.0"

Write-Log "Starting service..."
Start-Service -Name $ServiceName -ErrorAction Stop
$svc = Get-Service -Name $ServiceName
Write-Log "Service status: $($svc.Status)"

# Register the EventLog source so the service can write to Application log
# (otherwise the first log write crashes the service trying to auto-register)
Write-Log "Registering EventLog source 'NextGPUService'..."
if (-not [System.Diagnostics.EventLog]::SourceExists("NextGPUService")) {
    [System.Diagnostics.EventLog]::CreateEventSource("NextGPUService", "Application")
    Write-Log "EventLog source created."
} else {
    Write-Log "EventLog source already exists."
}

# Open the firewall exception for the named-pipe control channel
Write-Log "Opening firewall exception for NextGPUService (named pipe)..."
$fwRuleName = "NextGPUService - Named Pipe (NextGPUControl)"
$existingRule = Get-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
if (-not $existingRule) {
    New-NetFirewallRule -DisplayName $fwRuleName `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Program "System" `
        -Profile Any | Out-Null
    Write-Log "Firewall rule created."
} else {
    Write-Log "Firewall rule already exists."
}

# Ensure log directory exists (the service writes to %ProgramData%\NextGPU\Logs)
$logDir = "$env:ProgramData\NextGPU\Logs"
if (-not (Test-Path $logDir)) {
    New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    Write-Log "Log directory created: $logDir"
}

if ($svc.Status -eq 'Running') {
    Write-Log "=== $scriptName completed successfully ==="
} else {
    Write-Log "ERROR: Service did not start. Check Windows Event Log and $logDir."
    throw "Service failed to start"
}
