#Requires -Version 5.1
# Dot-sourced by GamesApps-Manifest.ps1 after shared helpers are defined.

$script:SteamSetupDownloadUrl = 'https://cdn.cloudflare.steamstatic.com/client/installer/steamsetup.exe'
$script:SteamClientInstallTimeoutSeconds = 600
$script:SteamClientPollIntervalSeconds = 5

function Write-SteamInstallLog {
    param(
        [string]$LogPath,
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'FAIL')]
        [string]$Level = 'INFO'
    )
    $line = ('[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    if ($LogPath) {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    switch ($Level) {
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line -ForegroundColor Cyan }
    }
}

function Wait-SteamClientReady {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$TimeoutSeconds = $script:SteamClientInstallTimeoutSeconds,
        [int]$PollIntervalSeconds = $script:SteamClientPollIntervalSeconds
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-IsSteamClientPath -Path $TargetPath) {
            return $true
        }
        Start-Sleep -Seconds $PollIntervalSeconds
    }
    return (Test-IsSteamClientPath -Path $TargetPath)
}

function Start-SteamClientBootstrap {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$WaitSeconds = 120
    )
    $steamExe = Join-Path $TargetPath 'steam.exe'
    if (-not (Test-Path -LiteralPath $steamExe -PathType Leaf)) {
        return $false
    }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $steamExe
        $psi.Arguments = '-silent'
        $psi.WorkingDirectory = $TargetPath
        $psi.UseShellExecute = $false
        $null = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        return $false
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-IsSteamClientPath -Path $TargetPath) {
            return $true
        }
        Start-Sleep -Seconds 3
    }
    return (Test-IsSteamClientPath -Path $TargetPath)
}

function Install-SteamClientSilent {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$LogPath = '',
        [string]$ManifestPath = ''
    )

    $targetPath = [System.IO.Path]::GetFullPath($TargetPath.Trim().TrimEnd('\'))
    Write-SteamInstallLog -LogPath $LogPath -Message "Steam install target: $targetPath"

    if (-not (Test-Path -LiteralPath $targetPath)) {
        New-Item -ItemType Directory -Path $targetPath -Force | Out-Null
    }

    $steamApps = Join-Path $targetPath 'steamapps'
    if (-not (Test-Path -LiteralPath $steamApps)) {
        New-Item -ItemType Directory -Path $steamApps -Force | Out-Null
    }
    $commonRoot = Join-Path $steamApps 'common'
    if (-not (Test-Path -LiteralPath $commonRoot)) {
        New-Item -ItemType Directory -Path $commonRoot -Force | Out-Null
    }

    if (Test-IsSteamClientPath -Path $targetPath) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Steam client already present at target; skipping installer."
        Register-SteamInstallPath -SteamPath $targetPath | Out-Null
        return $targetPath
    }

    $setupPath = Join-Path $env:TEMP 'nextgpu-steamsetup.exe'
    Write-SteamInstallLog -LogPath $LogPath -Message "Downloading SteamSetup.exe from $($script:SteamSetupDownloadUrl)"
    try {
        Invoke-WebRequest -Uri $script:SteamSetupDownloadUrl -OutFile $setupPath -UseBasicParsing
    }
    catch {
        throw "Failed to download SteamSetup.exe: $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        throw "SteamSetup.exe was not saved to: $setupPath"
    }

    Write-SteamInstallLog -LogPath $LogPath -Message "Running silent install: $setupPath /S /D=$targetPath"
    $proc = Start-Process -FilePath $setupPath -ArgumentList '/S', "/D=$targetPath" -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "SteamSetup.exe exited with code $($proc.ExitCode)."
    }

    if (-not (Wait-SteamClientReady -TargetPath $targetPath)) {
        Write-SteamInstallLog -LogPath $LogPath -Message 'Steam client not ready after installer; running steam.exe -silent bootstrap.' 'WARN'
        if (-not (Start-SteamClientBootstrap -TargetPath $targetPath)) {
            throw "Steam client did not become ready at $targetPath within $($script:SteamClientInstallTimeoutSeconds)s."
        }
    }

    if (-not (Test-IsSteamClientPath -Path $targetPath)) {
        throw "Steam install finished but client validation failed at: $targetPath"
    }

    $registered = Register-SteamInstallPath -SteamPath $targetPath
    Write-SteamInstallLog -LogPath $LogPath -Message $(if ($registered) { "Registered Steam InstallPath: $targetPath" } else { "Steam InstallPath already set: $targetPath" })

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Get-ResolvedDownloadManifestPath
    }
    $manifestDir = Split-Path -Parent $ManifestPath
    if ($manifestDir -and -not (Test-Path -LiteralPath $manifestDir)) {
        New-Item -ItemType Directory -Path $manifestDir -Force | Out-Null
    }

    $entry = [pscustomobject]@{
        Name        = 'SteamSetup (auto)'
        ExtractPath = $targetPath
        SizeBytes   = [int64]0
        IsSteamGame = $false
        Type        = 'Steam app'
    }
    $written = Update-DownloadManifest -ManifestPath $ManifestPath -Entries @($entry) -Status 'Complete'
    if ($written) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Manifest updated with Steam app entry: $written"
    }

    try {
        Remove-Item -LiteralPath $setupPath -Force -ErrorAction SilentlyContinue
    }
    catch { }

    Write-SteamInstallLog -LogPath $LogPath -Message "Steam client ready: $targetPath"
    return $targetPath
}
