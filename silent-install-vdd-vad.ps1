# One-click: downloads NefCon + VDD + VAD from GitHub and installs silently.
# Staging folder (kept after install): <script dir>\VDD-VAD-Install\
# Usage: double-click InstallVDD-VAD.bat  OR  run this script as Administrator.
[CmdletBinding()]
param(
    [string]$ReleaseTag = "25.7.23",
    [string]$NefConURL = "https://github.com/nefarius/nefcon/releases/download/v1.14.0/nefcon_v1.14.0.zip",
    [string]$LogPath = "",
    [string]$InstallDir = "",
    [switch]$SkipIfInstalled
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $scriptRoot "VDD-VAD.log"
}

function Write-Log {
    param([string]$Message, [ValidateSet("INFO", "WARN", "ERROR", "SKIP", "OK")][string]$Level = "INFO")
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] [{1}] {2}" -f (Get-Date), $Level, $Message
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
        "-LogPath", "`"$LogPath`""
    )
    if ($SkipIfInstalled) { $args += "-SkipIfInstalled" }
    if (-not [string]::IsNullOrWhiteSpace($InstallDir)) { $args += "-InstallDir", "`"$InstallDir`"" }
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $args -Wait
    exit 0
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Join-Path $scriptRoot "VDD-VAD-Install"
}
$script:InstallDir = $InstallDir
$exitCode = 0

try {
    Write-Log "========== VDD + VAD one-click install =========="
    Write-Log "Host=$env:COMPUTERNAME User=$env:USERNAME Release=$ReleaseTag"
    Write-Log "InstallDir=$script:InstallDir"

    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null

    $vddHwId = "Root\MttVDD"
    $vadHwId = "Root\VirtualAudioDriver"
    $vddInstalled = Test-DriverPresent $vddHwId
    $vadInstalled = Test-DriverPresent $vadHwId
    Write-Log "Pre-check VDD=$vddInstalled VAD=$vadInstalled"

    # SkipIfInstalled is on by default; pass -SkipIfInstalled:$false to force reinstall
    $shouldSkip = -not $PSBoundParameters.ContainsKey('SkipIfInstalled') -or $SkipIfInstalled.IsPresent
    if ($shouldSkip -and $vddInstalled -and $vadInstalled) {
        Write-Log "Both drivers already installed. Done." -Level SKIP
        exit 0
    }

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
            HwId = $vddHwId; Skip = $shouldSkip -and $vddInstalled
        },
        @{
            Name = "VAD"; Url = (Get-ReleaseAssetUrl "VirtualAudioDriver-x86.Driver.Only.zip")
            Zip = "vad.zip"; Folder = "VirtualAudioDriver"; Cat = "VirtualAudioDriver.cat"; Inf = "VirtualAudioDriver.inf"
            HwId = $vadHwId; Skip = $shouldSkip -and $vadInstalled
        }
    )

    foreach ($drv in $drivers) {
        if ($drv.Skip) {
            Write-Log "SKIP $($drv.Name) (already installed)" -Level SKIP
            continue
        }

        $infFile = Join-Path $script:InstallDir "$($drv.Folder)\$($drv.Inf)"
        if (-not (Test-Path $infFile)) {
            $zipPath = Join-Path $script:InstallDir $drv.Zip
            Invoke-FileDownload -Url $drv.Url -OutFile $zipPath
            Expand-Archive -Path $zipPath -DestinationPath $script:InstallDir -Force
        } else {
            Write-Log "$($drv.Name) package already extracted, skipping download." -Level SKIP
        }

        $catFile = Join-Path $script:InstallDir "$($drv.Folder)\$($drv.Cat)"
        $infFile = Join-Path $script:InstallDir "$($drv.Folder)\$($drv.Inf)"
        if (-not (Test-Path $infFile)) { throw "$($drv.Name) INF missing: $infFile" }

        Import-DriverCertificates -CatFile $catFile
        $relInf = ".\$($drv.Folder)\$($drv.Inf)"
        $code = Install-DriverWithNefcon -NefConExe $nefConExe -InfRelativePath $relInf -HardwareId $drv.HwId -Label $drv.Name
        if (-not (Test-NefconSuccess $code)) { $exitCode = $code }

        Start-Sleep -Seconds 8
        if (Test-DriverPresent $drv.HwId) {
            Write-Log "$($drv.Name) verified in Device Manager" -Level OK
        } else {
            Write-Log "$($drv.Name) not found after install" -Level WARN
            if ($exitCode -eq 0) { $exitCode = 2 }
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
