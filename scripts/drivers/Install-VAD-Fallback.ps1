#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "[OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }

. (Join-Path $PSScriptRoot 'VddVadCommon.ps1')

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-VbCableFileDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$OutFile
    )
    $dir = Split-Path -Parent $OutFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl) {
        & $curl -L -s -S --retry 3 --retry-delay 2 -o $OutFile $Url
        if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutFile)) { return }
        Write-Warn "curl failed (exit $LASTEXITCODE); trying PowerShell download."
    }
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Install-VbCableFromVendor {
    $installRoot = Join-Path $env:ProgramData 'nextGPU\VBCABLE-Install'
    if (-not (Test-Path -LiteralPath $installRoot)) {
        New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
    }

    $zipPath = Join-Path $installRoot 'VBCABLE_Driver_Pack.zip'
    $urls = @(
        'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip',
        'https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack43.zip'
    )

    $downloaded = $false
    foreach ($url in $urls) {
        Write-Step "Downloading VB-CABLE from vb-audio.com ..."
        Write-Host "  $url" -ForegroundColor DarkGray
        try {
            if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
            Invoke-VbCableFileDownload -Url $url -OutFile $zipPath
            if ((Get-Item -LiteralPath $zipPath).Length -lt 100KB) {
                throw "Download too small ($zipPath)"
            }
            $downloaded = $true
            break
        }
        catch {
            Write-Warn $_.Exception.Message
        }
    }

    if (-not $downloaded) {
        Write-Warn 'Could not download VB-CABLE driver pack from vb-audio.com.'
        return $false
    }

    $extractDir = Join-Path $installRoot 'extracted'
    if (Test-Path -LiteralPath $extractDir) {
        Remove-Item -LiteralPath $extractDir -Recurse -Force
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $setup = Get-ChildItem -LiteralPath $extractDir -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ieq 'VBCABLE_Setup_x64.exe' -or $_.Name -ieq 'VBCABLE_Setup.exe' } |
        Sort-Object { if ($_.Name -ieq 'VBCABLE_Setup_x64.exe') { 0 } else { 1 } } |
        Select-Object -First 1

    if (-not $setup) {
        Write-Warn "VB-CABLE setup exe not found under $extractDir"
        return $false
    }

    Write-Step ("Running {0} (signed VB-CABLE driver)..." -f $setup.Name)
    Write-Host '  Windows may show one "Windows Security" driver install prompt - click Install.' -ForegroundColor Yellow
    $proc = Start-Process -FilePath $setup.FullName -ArgumentList @('-i', '-h') -Wait -PassThru -WindowStyle Normal
    if ($proc.ExitCode -ne 0) {
        Write-Warn ("VB-CABLE setup exit code: $($proc.ExitCode). Trying without -h ...")
        $proc2 = Start-Process -FilePath $setup.FullName -ArgumentList @('-i') -Wait -PassThru -WindowStyle Normal
        if ($proc2.ExitCode -ne 0) {
            Write-Warn ("VB-CABLE setup exit code: $($proc2.ExitCode)")
        }
    }

    Write-Step 'Scanning for new audio devices...'
    $null = & pnputil.exe /scan-devices 2>&1
    Start-Sleep -Seconds 5
    return $true
}

function Try-InstallVbCableWinget {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }

    $candidateIds = @(
        'VBurel.VB-CABLE',
        'VB-Audio.VB-CABLE',
        'VBAudio.VBCABLE'
    )
    foreach ($id in $candidateIds) {
        Write-Step ("Trying winget package: {0}" -f $id)
        & winget install --id $id --exact --silent --accept-package-agreements --accept-source-agreements --source winget 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Write-Ok ("Installed via winget: {0}" -f $id)
            return $true
        }
    }
    Write-Warn 'VB-CABLE is not published on winget on most systems; using vb-audio.com download instead.'
    return $false
}

if (-not (Test-Admin)) {
    Write-Step "Requesting administrator permission..."
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`""
    )
    if ($Force.IsPresent) { $argList += '-Force' }
    $proc = Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList -Wait -PassThru
    exit $proc.ExitCode
}

Write-Host "======================================="
Write-Host " NextGPU VAD Fallback Installer"
Write-Host "======================================="

$health = Get-VadHealth
Write-Host ("VAD check: {0}" -f $health.Summary) -ForegroundColor $(if ($health.Ready) { 'Green' } else { 'Yellow' })
if ($health.Detail) {
    Write-Host ("  {0}" -f $health.Detail) -ForegroundColor DarkGray
}
if ($health.Primary.Count -gt 0) {
    $health.Primary | ForEach-Object {
        Write-Host ("  [primary] {0} | {1} | {2}" -f $_.FriendlyName, $_.Status, $_.Problem) -ForegroundColor DarkGray
    }
}

if ($health.Ready -and -not $Force.IsPresent) {
    Write-Ok "Usable VAD already present. No fallback needed."
    Write-Host "  Run Get-VddVadStatus.ps1 for full report. Use -Force to install VB-CABLE anyway." -ForegroundColor DarkGray
    exit 0
}

if ($health.NeedsFallback -or $Force.IsPresent) {
    if ($Force.IsPresent -and $health.Ready) {
        Write-Warn "-Force: installing signed fallback even though a device looks ready."
    }
    else {
        Write-Warn "Primary Virtual Audio Driver is not usable (often Code 52). Installing signed VB-CABLE."
    }
}
else {
    Write-Warn "VAD state unclear; attempting VB-CABLE install."
}

$null = Try-InstallVbCableWinget
$vendorOk = Install-VbCableFromVendor

Start-Sleep -Seconds 2
$after = Get-VadHealth
if ($after.Ready) {
    Write-Ok ("VAD fallback is now ready: {0}" -f $after.Summary)
    if ($after.Detail) { Write-Host ("  {0}" -f $after.Detail) -ForegroundColor DarkGray }
    Write-Host '  Reboot if streaming apps still do not see the cable device.' -ForegroundColor DarkGray
    exit 0
}

Write-Warn "VB-CABLE install did not show a ready device yet."
if (-not $vendorOk) {
    Write-Warn 'Download or setup failed. Check outbound HTTPS to download.vb-audio.com'
}
Write-Host ""
Write-Host "Next steps:"
Write-Host "1) Reboot, then run scripts\drivers\Get-VddVadStatus.ps1"
Write-Host "2) In Device Manager, disable the broken 'Virtual Audio Driver by MTT' (Code 52) if VB-CABLE is OK"
Write-Host "3) In Sunshine, select CABLE Input / VB-Audio Virtual Cable as audio device"
Write-Host "4) Manual download: https://vb-audio.com/Cable/ -> VBCABLE_Driver_Pack45.zip -> run VBCABLE_Setup_x64.exe as Admin"
exit 3
