# One-click: removes existing VDD/VAD devices and installs fresh drivers silently.
# Staging folder (kept after install): <script dir>\VDD-VAD-Install\
# Usage: double-click InstallVDD-VAD.bat  OR  run this script as Administrator.
[CmdletBinding()]
param(
    [string]$ReleaseTag = "25.7.23",
    [string]$NefConURL = "https://github.com/nefarius/nefcon/releases/download/v1.14.0/nefcon_v1.14.0.zip",
    [string]$VdcURL = "",
    [string]$LogPath = "",
    [string]$InstallDir = "",
    [switch]$RequireVad,
    [switch]$SkipIfInstalled
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$scriptRoot = if ($env:NEXTGPU_REPO_ROOT) {
    $env:NEXTGPU_REPO_ROOT
} else {
    (Resolve-Path (Join-Path $scriptDir '..\..')).Path
}
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path (Join-Path $scriptRoot "logs") "VDD-VAD.log"
}

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR", "SKIP", "OK")][string]$Level = "INFO")
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
    $color = switch ($Level) {
        "OK" { "Green" }
        "WARN" { "Yellow" }
        "ERROR" { "Red" }
        "SKIP" { "DarkGray" }
        default { "Cyan" }
    }
    Write-Host $line -ForegroundColor $color
    $dir = Split-Path $LogPath -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Add-Content -Path $LogPath -Value $line -Encoding UTF8
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-FileDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    $curl = Join-Path $env:SystemRoot "System32\curl.exe"
    if (Test-Path $curl) {
        Write-Log "Download (curl): $Url"
        & $curl -L -s -S --retry 3 --retry-delay 2 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
            return
        }
        Write-Log "curl failed (exit $LASTEXITCODE); trying PowerShell." -Level WARN
    }
    Write-Log "Download (PowerShell): $Url"
    $ProgressPreference = "SilentlyContinue"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    if (-not (Test-Path $OutFile) -or ((Get-Item $OutFile).Length -eq 0)) {
        throw "Download failed or empty file: $OutFile"
    }
}

function Invoke-Phase {
    param([Parameter(Mandatory)][string]$Name)
    Write-Log "========== Phase: $Name =========="
}

function Resolve-RepoPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $scriptRoot $Path))
}

function Install-VirtualDriverControl {
    param([Parameter(Mandatory)][string]$Url)

    $vdcDir = Join-Path $script:InstallDir "VirtualDriverControl"
    $vdcZip = Join-Path $script:InstallDir "VDD.Control.$ReleaseTag.zip"
    New-Item -ItemType Directory -Path $vdcDir -Force | Out-Null

    if (-not (Test-Path $vdcZip) -or ((Get-Item $vdcZip).Length -eq 0)) {
        Invoke-FileDownload -Url $Url -OutFile $vdcZip
    } else {
        Write-Log "Virtual Driver Control ZIP already present, skipping download." -Level SKIP
    }

    Write-Log "Extracting Virtual Driver Control to $vdcDir"
    Expand-Archive -Path $vdcZip -DestinationPath $vdcDir -Force

    $vdcExe = Get-ChildItem -Path $vdcDir -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match 'VDD|Virtual|Control' } |
        Select-Object -First 1

    if ($vdcExe) {
        Write-Log "Virtual Driver Control ready: $($vdcExe.FullName)" -Level OK
        Set-Content -Path (Join-Path $script:InstallDir 'VirtualDriverControl.path.txt') `
            -Value $vdcExe.FullName -Encoding UTF8
    } else {
        Write-Log "Virtual Driver Control extracted but no matching EXE was found in $vdcDir" -Level WARN
    }
}

function Ensure-VddSettingsLocation {
    $settingsDir = 'C:\VirtualDisplayDriver'
    if (-not (Test-Path -LiteralPath $settingsDir)) {
        New-Item -ItemType Directory -Path $settingsDir -Force | Out-Null
        Write-Log "Created VDD settings directory: $settingsDir"
    } else {
        Write-Log "VDD settings directory exists: $settingsDir" -Level OK
    }
    Write-Log "VDD settings file location: $settingsDir\vdd_settings.xml"
}

function Expand-DriverPackage {
    param(
        [Parameter(Mandatory)][hashtable]$Driver
    )

    $packageDir = Join-Path $script:InstallDir $Driver.Folder
    $zipPath = Join-Path $script:InstallDir $Driver.Zip
    $infFile = Join-Path $packageDir $Driver.Inf
    $catFile = Join-Path $packageDir $Driver.Cat
    $packageComplete = (Test-Path -LiteralPath $infFile) -and (Test-Path -LiteralPath $catFile)

    if ($packageComplete) {
        Write-Log "$($Driver.Name) package already extracted and complete, skipping download." -Level SKIP
        return
    }

    if (Test-Path -LiteralPath $packageDir) {
        Write-Log "$($Driver.Name) package is incomplete; removing stale extracted folder before refresh." -Level WARN
        Remove-Item -LiteralPath $packageDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path -LiteralPath $zipPath) -or ((Get-Item -LiteralPath $zipPath).Length -eq 0)) {
        Invoke-FileDownload -Url $Driver.Url -OutFile $zipPath
    } else {
        Write-Log "$($Driver.Name) ZIP already present, reusing it for extraction." -Level SKIP
    }

    Expand-Archive -Path $zipPath -DestinationPath $script:InstallDir -Force

    if (-not (Test-Path -LiteralPath $infFile)) { throw "$($Driver.Name) INF missing after extract: $infFile" }
    if (-not (Test-Path -LiteralPath $catFile)) { throw "$($Driver.Name) catalog missing after extract: $catFile" }
}

function Ensure-VddSettingsFile {
    param([Parameter(Mandatory)][string]$SourceFile)

    $settingsDir = 'C:\VirtualDisplayDriver'
    $settingsFile = Join-Path $settingsDir 'vdd_settings.xml'
    if (-not (Test-Path -LiteralPath $SourceFile)) {
        Write-Log "Default VDD settings file not found in package: $SourceFile" -Level WARN
        return
    }
    if (Test-Path -LiteralPath $settingsFile) {
        Write-Log "VDD settings file already exists: $settingsFile" -Level SKIP
        return
    }
    Copy-Item -LiteralPath $SourceFile -Destination $settingsFile -Force
    Write-Log "Copied default VDD settings file to $settingsFile" -Level OK
}

function Import-DriverCertificates {
    param([Parameter(Mandatory)][string]$CatFile)
    if (-not (Test-Path $CatFile)) { throw "Catalog file not found: $CatFile" }
    Write-Log "Importing certificates from $CatFile"
    $catBytes = [System.IO.File]::ReadAllBytes($CatFile)
    $certificates = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
    $certificates.Import($catBytes)
    $certsFolder = Join-Path $script:InstallDir "ExportedCerts"
    New-Item -ItemType Directory -Path $certsFolder -Force | Out-Null
    foreach ($cert in $certificates) {
        $certFilePath = Join-Path $certsFolder "$($cert.Thumbprint).cer"
        $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert) |
            Set-Content -Path $certFilePath -Encoding Byte
        Import-Certificate -FilePath $certFilePath -CertStoreLocation "Cert:\LocalMachine\TrustedPublisher" | Out-Null
    }
    Write-Log "Certificates imported ($($certificates.Count))" -Level OK
}

function Test-DriverPresent {
    param([Parameter(Mandatory)][string]$HardwareId)
    $pattern = $HardwareId -replace '\\', '\\'
    $dev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object {
        $_.InstanceId -match "^$pattern" -or
        ($_.HardwareID -and ($_.HardwareID -contains $HardwareId -or $_.HardwareID -like "*$HardwareId*"))
    } | Select-Object -First 1
    if ($dev) { return $true }
    $cim = Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
        $_.DeviceID -like "$HardwareId*" -or $_.DeviceID -like "*\$HardwareId*"
    } | Select-Object -First 1
    return [bool]$cim
}

function Get-PnpDevicesByPattern {
    param(
        [Parameter(Mandatory)][string[]]$InstancePatterns,
        [string]$FriendlyNamePattern = ''
    )
    try {
        @(Get-PnpDevice -ErrorAction Stop | Where-Object {
            $match = $false
            foreach ($pattern in $InstancePatterns) {
                if ($_.InstanceId -like $pattern) { $match = $true; break }
            }
            if (-not $match -and $FriendlyNamePattern -and $_.FriendlyName) {
                $match = $_.FriendlyName -match $FriendlyNamePattern
            }
            $match
        })
    }
    catch {
        Write-Log "Get-PnpDevice failed: $($_.Exception.Message)" -Level WARN
        @()
    }
}

function Remove-PnpDevicesByPattern {
    param(
        [Parameter(Mandatory)][string[]]$InstancePatterns,
        [string]$FriendlyNamePattern = '',
        [Parameter(Mandatory)][string]$Label
    )
    $devices = @(Get-PnpDevicesByPattern -InstancePatterns $InstancePatterns -FriendlyNamePattern $FriendlyNamePattern)
    if ($devices.Count -eq 0) {
        Write-Log "No existing $Label devices found." -Level SKIP
        return
    }

    foreach ($device in $devices) {
        Write-Log "Removing existing $Label device: $($device.InstanceId) [$($device.Status) / $($device.Problem)]"
        $output = & pnputil.exe /remove-device "$($device.InstanceId)" 2>&1 | Out-String
        if ($output.Trim()) { Write-Log $output.Trim() }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "pnputil /remove-device returned $LASTEXITCODE for $($device.InstanceId)" -Level WARN
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
            if ($current.Count -gt 0) { $records.Add([pscustomobject]$current) }
            $current = @{ PublishedName = $Matches[1].Trim() }
            continue
        }
        if ($text -match '^\s*Original Name\s*:\s*(.+)$') { $current.OriginalName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Provider Name\s*:\s*(.+)$') { $current.ProviderName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Class Name\s*:\s*(.+)$') { $current.ClassName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Driver Version\s*:\s*(.+)$') { $current.DriverVersion = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Signer Name\s*:\s*(.+)$') { $current.SignerName = $Matches[1].Trim(); continue }
    }

    if ($current.Count -gt 0) { $records.Add([pscustomobject]$current) }
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
    }
    catch {
        Write-Log "Failed to enumerate driver packages for $Label : $($_.Exception.Message)" -Level WARN
        return
    }

    if ($drivers.Count -eq 0) {
        Write-Log "No existing $Label driver packages found." -Level SKIP
        return
    }

    foreach ($driver in $drivers) {
        Write-Log "Deleting existing $Label driver package: $($driver.PublishedName) ($($driver.OriginalName))"
        $output = & pnputil.exe /delete-driver $driver.PublishedName /uninstall /force 2>&1 | Out-String
        if ($output.Trim()) { Write-Log $output.Trim() }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "pnputil /delete-driver returned $LASTEXITCODE for $($driver.PublishedName)" -Level WARN
        }
    }
}

function Invoke-PnpRescan {
    Write-Log "Scanning for hardware/device changes..."
    $output = & pnputil.exe /scan-devices 2>&1 | Out-String
    if ($output.Trim()) { Write-Log $output.Trim() }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "pnputil /scan-devices returned $LASTEXITCODE" -Level WARN
    }
}

function Reset-VddVadDrivers {
    Write-Log "Removing existing VDD/VAD devices before fresh install..."
    Remove-PnpDevicesByPattern -InstancePatterns @('DISPLAY\MTT1337*', 'ROOT\MttVDD*') `
        -FriendlyNamePattern 'VDD|MttVDD|Virtual Display' -Label 'VDD'
    Remove-PnpDevicesByPattern -InstancePatterns @('ROOT\VirtualAudioDriver*', 'ROOT\MEDIA*') `
        -FriendlyNamePattern 'Virtual Audio Driver' -Label 'VAD'
    Invoke-PnpRescan
    Remove-DriverPackagesByOriginalName -OriginalNames @('MttVDD.inf', 'VirtualAudioDriver.inf') -Label 'VDD/VAD'
}

function Test-PnpDeviceReady {
    param(
        [Parameter(Mandatory)][string[]]$InstancePatterns,
        [string]$FriendlyNamePattern = '',
        [string]$Label = 'device',
        [bool]$Required = $true
    )
    $devices = @(Get-PnpDevicesByPattern -InstancePatterns $InstancePatterns -FriendlyNamePattern $FriendlyNamePattern)
    foreach ($device in $devices) {
        $problem = if ($null -ne $device.Problem) { [string]$device.Problem } else { '' }
        if ($device.Status -eq 'OK' -and ($problem -eq '' -or $problem -eq 'CM_PROB_NONE')) {
            Write-Log "Ready device: $($device.InstanceId) [$($device.Status) / $problem]" -Level OK
            return $true
        }
        Write-Log "Not ready device: $($device.InstanceId) [$($device.Status) / $problem]" -Level WARN
        if ($Label -eq 'VAD' -and $problem -eq 'CM_PROB_UNSIGNED_DRIVER') {
            $level = if ($Required) { 'ERROR' } else { 'WARN' }
            $vdcPathFile = Join-Path $script:InstallDir 'VirtualDriverControl.path.txt'
            $vdcExe = if (Test-Path -LiteralPath $vdcPathFile) {
                (Get-Content -LiteralPath $vdcPathFile -Raw).Trim()
            } else {
                Join-Path $script:InstallDir 'VirtualDriverControl\VDD Control.exe'
            }
            Write-Log "VAD is blocked by Windows driver signature enforcement (Code 52). This is a known upstream VirtualDrivers VAD issue on some Windows 11 24H2 / Server 2025 systems." -Level $level
            Write-Log "Manual action for setup person: open Virtual Driver Control at '$vdcExe', install/enable the Virtual Audio Driver, then rerun this installer." -Level $level
            Write-Log "PowerShell helper: Start-Process -FilePath '$vdcExe'" -Level INFO
            Write-Log "If Windows still reports Code 52 after using Virtual Driver Control, use a signed fallback audio driver such as VB-CABLE." -Level $level
        }
    }
    return $false
}

function Test-VddDisplayPathReady {
    $displayScript = Join-Path $scriptRoot 'scripts\provisioning\Get-DisplayDeviceId.ps1'
    if (-not (Test-Path -LiteralPath $displayScript)) {
        Write-Log "Display device ID script not found: $displayScript" -Level WARN
        return $false
    }

    try {
        $deviceId = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $displayScript -IncludeInactive 2>$null |
            Where-Object { $_ -match '^\s*\{' } |
            Select-Object -First 1
        if (-not [string]::IsNullOrWhiteSpace($deviceId)) {
            Write-Log "VDD display path resolved by Get-DisplayDeviceId.ps1: $deviceId" -Level OK
            return $true
        }
    }
    catch {
        Write-Log "Get-DisplayDeviceId.ps1 verification failed: $($_.Exception.Message)" -Level WARN
    }

    Write-Log "Get-DisplayDeviceId.ps1 could not resolve a VDD display path." -Level WARN
    return $false
}

function Install-DriverWithNefcon {
    param(
        [string]$NefConExe,
        [string]$InfRelativePath,
        [string]$HardwareId,
        [string]$Label
    )
    Write-Log "Installing $Label : $InfRelativePath ($HardwareId)"
    Push-Location $script:InstallDir
    try {
        $proc = Start-Process -FilePath $NefConExe -ArgumentList @("install", $InfRelativePath, $HardwareId) `
            -Wait -PassThru -WindowStyle Hidden
        $ok = ($proc.ExitCode -eq 0) -or ($proc.ExitCode -eq 3010)
        Write-Log "$Label nefcon exit: $($proc.ExitCode)" -Level $(if ($ok) { "OK" } else { "WARN" })
        return [int]$proc.ExitCode
    }
    finally { Pop-Location }
}

function Get-ReleaseAssetUrl {
    param([string]$AssetFileName)
    "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/$ReleaseTag/$AssetFileName"
}

function Test-NefconSuccess {
    param([int]$Code)
    return ($Code -eq 0) -or ($Code -eq 3010)
}

# --- Auto elevation (hidden) ---
if (-not (Test-Admin)) {
    Write-Log "Not admin; elevating and re-running hidden."
    $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
        "-File", "`"$PSCommandPath`"",
        "-ReleaseTag", $ReleaseTag,
        "-NefConURL", "`"$NefConURL`"",
        "-VdcURL", "`"$VdcURL`"",
        "-LogPath", "`"$LogPath`""
    )
    if ($SkipIfInstalled) { $args += "-SkipIfInstalled" }
    if ($RequireVad) { $args += "-RequireVad" }
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) { $args += "-InstallDir", "`"$InstallDir`"" }
    $proc = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -WorkingDirectory $scriptRoot `
        -ArgumentList $args -Wait -PassThru
    exit $proc.ExitCode
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $scriptRoot "VDD-VAD-Install"
}
$InstallDir = Resolve-RepoPath $InstallDir
if (-not [System.IO.Path]::IsPathRooted($LogPath)) {
    $LogPath = Resolve-RepoPath $LogPath
}
if ([string]::IsNullOrWhiteSpace($VdcURL)) {
    $VdcURL = Get-ReleaseAssetUrl "VDD.Control.$ReleaseTag.zip"
}
$script:InstallDir = $InstallDir
$exitCode = 0

try {
    Write-Log "========== VDD + VAD + Virtual Driver Control install =========="
    Write-Log "Host=$env:COMPUTERNAME User=$env:USERNAME Release=$ReleaseTag"
    Write-Log "InstallDir=$script:InstallDir"
    Write-Log "Virtual Driver Control URL=$VdcURL"
    Write-Log "RequireVad=$($RequireVad.IsPresent)"

    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null

    $vddHwId = "Root\MttVDD"
    $vadHwId = "Root\VirtualAudioDriver"
    Invoke-Phase "Pre-check"
    $vddInstalled = Test-DriverPresent $vddHwId
    $vadInstalled = Test-DriverPresent $vadHwId
    Write-Log "Pre-check VDD=$vddInstalled VAD=$vadInstalled"

    if ($SkipIfInstalled) {
        Write-Log "-SkipIfInstalled is ignored. This installer always refreshes VDD/VAD to avoid stale or phantom devices." -Level WARN
    }

    Invoke-Phase "Cleanup existing VDD/VAD"
    Reset-VddVadDrivers

    Invoke-Phase "Install Virtual Driver Control"
    Install-VirtualDriverControl -Url $VdcURL
    Ensure-VddSettingsLocation

    Invoke-Phase "Prepare NefCon"
    $nefConExe = Join-Path $script:InstallDir "x64\nefconw.exe"
    if (-not (Test-Path $nefConExe)) {
        $nefConZip = Join-Path $script:InstallDir "nefcon.zip"
        Invoke-FileDownload -Url $NefConURL -OutFile $nefConZip
        Expand-Archive -Path $nefConZip -DestinationPath $script:InstallDir -Force
    } else {
        Write-Log "NefCon already present, skipping download." -Level SKIP
    }
    if (-not (Test-Path $nefConExe)) { throw "nefconw.exe not found" }
    Write-Log "NefCon ready" -Level OK

    $archSuffix = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "ARM64" } else { "x86" }

    $drivers = @(
        @{
            Name = "VDD"; Url = (Get-ReleaseAssetUrl "VirtualDisplayDriver-$archSuffix.Driver.Only.zip")
            Zip = "vdd.zip"; Folder = "VirtualDisplayDriver"; Cat = "mttvdd.cat"; Inf = "MttVDD.inf"
            HwId = $vddHwId
        },
        @{
            Name = "VAD"; Url = (Get-ReleaseAssetUrl "VirtualAudioDriver-x86.Driver.Only.zip")
            Zip = "vad.zip"; Folder = "VirtualAudioDriver"; Cat = "virtualaudiodriver.cat"; Inf = "VirtualAudioDriver.inf"
            HwId = $vadHwId
        }
    )

    foreach ($drv in $drivers) {
        Invoke-Phase "Install $($drv.Name)"
        $driverRequired = ($drv.Name -eq "VDD") -or ($drv.Name -eq "VAD" -and $RequireVad.IsPresent)
        Expand-DriverPackage -Driver $drv
        $catFile = Join-Path $script:InstallDir "$($drv.Folder)\$($drv.Cat)"
        $infFile = Join-Path $script:InstallDir "$($drv.Folder)\$($drv.Inf)"
        if ($drv.Name -eq "VDD") {
            Ensure-VddSettingsFile -SourceFile (Join-Path $script:InstallDir "$($drv.Folder)\vdd_settings.xml")
        }

        Import-DriverCertificates -CatFile $catFile
        $relInf = ".\$($drv.Folder)\$($drv.Inf)"
        $code = Install-DriverWithNefcon -NefConExe $nefConExe -InfRelativePath $relInf -HardwareId $drv.HwId -Label $drv.Name
        if (-not (Test-NefconSuccess $code)) {
            if ($driverRequired) {
                $exitCode = $code
            } else {
                Write-Log "$($drv.Name) install returned $code but is not required for headless VDD setup." -Level WARN
            }
        }

        Start-Sleep -Seconds 8
        if (Test-DriverPresent $drv.HwId) {
            Write-Log "$($drv.Name) verified in Device Manager" -Level OK
        } else {
            Write-Log "$($drv.Name) not found after install" -Level WARN
            if ($driverRequired -and $exitCode -eq 0) { $exitCode = 2 }
        }
    }

    Invoke-Phase "Verify VDD/VAD readiness"
    Invoke-PnpRescan
    Start-Sleep -Seconds 5

    $vddPnpReady = Test-PnpDeviceReady -InstancePatterns @('DISPLAY\MTT1337*') -Label 'VDD'
    $vddDisplayPathReady = Test-VddDisplayPathReady
    $vddReady = $vddPnpReady -or $vddDisplayPathReady
    $vadReady = Test-PnpDeviceReady -InstancePatterns @('ROOT\VirtualAudioDriver*', 'ROOT\MEDIA*') `
        -FriendlyNamePattern 'Virtual Audio Driver' -Label 'VAD' -Required:$RequireVad.IsPresent

    if (-not $vddReady) {
        Write-Log "VDD is not ready after reinstall. Expected a non-phantom OK DISPLAY\MTT1337 device or a VDD display path from Get-DisplayDeviceId.ps1. Reboot may be required, then rerun this installer if still missing." -Level ERROR
        if ($exitCode -eq 0) { $exitCode = 3 }
    }
    if (-not $vadReady) {
        if ($RequireVad) {
            Write-Log "VAD is not ready after reinstall. Expected an OK ROOT\VirtualAudioDriver device." -Level ERROR
            Write-Log "Recommended fallback: run scripts\drivers\Install-VAD-Fallback.ps1, then check scripts\drivers\Get-VddVadStatus.ps1." -Level ERROR
            if ($exitCode -eq 0) { $exitCode = 4 }
        } else {
            Write-Log "VAD is not ready, but continuing because VDD is ready and -RequireVad was not specified." -Level WARN
            Write-Log "Recommendation: run scripts\drivers\Install-VAD-Fallback.ps1 if stream audio is required." -Level WARN
        }
    }

    if ($exitCode -eq 0) { Write-Log "SUCCESS: all steps completed." -Level OK }
    else { Write-Log "Finished with errors (exit $exitCode)." -Level ERROR }
}
catch {
    Write-Log "FATAL: $($_.Exception.Message)" -Level ERROR
    $exitCode = 1
}
finally {
    Write-Log "Driver files kept at: $script:InstallDir"
    Write-Log "========== End (exit $exitCode) =========="
}

exit $exitCode
