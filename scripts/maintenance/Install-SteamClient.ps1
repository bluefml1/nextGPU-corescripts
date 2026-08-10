#Requires -Version 5.1
# Dot-sourced by GamesApps-Manifest.ps1 after shared helpers are defined.

$script:SteamBundleArchiveName = 'Steam.7z'
$script:SteamBundleFolderNames = @('Steam')
$script:SteamSetupDownloadUrls = @(
    'https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe',
    'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe',
    'https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe',
    'https://media.steampowered.com/client/installer/SteamSetup.exe'
)
$script:SteamClientInstallTimeoutSeconds = 600
$script:SteamClientPollIntervalSeconds = 5

function Get-SteamBundleArchiveName {
    return $script:SteamBundleArchiveName
}

function Test-SteamBundleManifestLeaf {
    param([string]$LeafName)
    if ([string]::IsNullOrWhiteSpace($LeafName)) { return $false }
    foreach ($name in $script:SteamBundleFolderNames) {
        if ($LeafName -ieq $name) { return $true }
    }
    return $false
}

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

function Test-SteamRegistryInstallPath {
    param([Parameter(Mandatory)][string]$TargetPath)
    $targetKey = $TargetPath.Trim().TrimEnd('\').ToUpperInvariant()
    foreach ($keyPath in @(Get-ValveSteamRegistryKeyPaths)) {
        try {
            $installPath = (Get-ItemProperty -LiteralPath $keyPath -Name InstallPath -ErrorAction Stop).InstallPath
            if ($installPath -and ($installPath.Trim().TrimEnd('\').ToUpperInvariant() -eq $targetKey)) {
                return $true
            }
        }
        catch { }
    }
    return $false
}

function Resolve-SteamExeDirectory {
    param([Parameter(Mandatory)][string]$TargetPath)
    $targetPath = [System.IO.Path]::GetFullPath($TargetPath.Trim().TrimEnd('\'))
    $steamExe = Join-Path $targetPath 'steam.exe'
    if (Test-Path -LiteralPath $steamExe -PathType Leaf) {
        return $targetPath
    }
    if (Get-Command Find-SteamClientPathUnderDirectory -ErrorAction SilentlyContinue) {
        $nested = Find-SteamClientPathUnderDirectory -Root $targetPath
        if ($nested) { return $nested }
    }
    return $null
}

function Start-SteamClientBootstrap {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [int]$WaitSeconds = 120
    )
    $clientDir = Resolve-SteamExeDirectory -TargetPath $TargetPath
    if (-not $clientDir) { return $false }

    $steamExe = Join-Path $clientDir 'steam.exe'
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $steamExe
        $psi.Arguments = '-silent'
        $psi.WorkingDirectory = $clientDir
        $psi.UseShellExecute = $false
        $null = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        return $false
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-IsSteamClientPath -Path $clientDir) {
            return $true
        }
        if (Test-SteamRegistryInstallPath -TargetPath $clientDir) {
            return $true
        }
        Start-Sleep -Seconds 3
    }
    return ((Test-IsSteamClientPath -Path $clientDir) -or (Test-SteamRegistryInstallPath -TargetPath $clientDir))
}

function Initialize-SteamClientFromExtract {
    <#
        First-run a Steam client folder (e.g. from R2 sync): launch steam.exe so Valve
        writes registry keys, then ensure InstallPath is set for Playnite/arrange tools.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$LogPath = ''
    )

    $clientDir = Resolve-SteamExeDirectory -TargetPath $TargetPath
    if (-not $clientDir) {
        throw "steam.exe not found under: $TargetPath"
    }

    if (Test-SteamRegistryInstallPath -TargetPath $clientDir) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Steam already registered at $clientDir; skipping steam.exe launch."
        try {
            Register-SteamInstallPath -SteamPath $clientDir | Out-Null
        }
        catch { }
        return $clientDir
    }

    Write-SteamInstallLog -LogPath $LogPath -Message "Launching steam.exe -silent to register Steam client at $clientDir"
    if (-not (Start-SteamClientBootstrap -TargetPath $clientDir)) {
        Write-SteamInstallLog -LogPath $LogPath -Message 'steam.exe bootstrap timed out; applying registry InstallPath manually.' 'WARN'
    }

    try {
        $registered = Register-SteamInstallPath -SteamPath $clientDir
        if ($registered) {
            Write-SteamInstallLog -LogPath $LogPath -Message "Registered Steam InstallPath: $clientDir"
        }
    }
    catch {
        Write-SteamInstallLog -LogPath $LogPath -Message "Could not register Steam InstallPath: $($_.Exception.Message)" 'WARN'
    }

    return $clientDir
}

function Resolve-SteamClientPathAfterR2Sync {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$ManifestPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Get-ResolvedDownloadManifestPath
    }

    $entries = @(Read-DownloadManifestEntries -ManifestPath $ManifestPath)
    if (Get-Command Find-ExistingSteamClientPath -ErrorAction SilentlyContinue) {
        $fromManifest = Find-ExistingSteamClientPath -Entries $entries
        if ($fromManifest) { return $fromManifest }
    }

    $targetPath = [System.IO.Path]::GetFullPath($TargetPath.Trim().TrimEnd('\'))
    if (Test-IsSteamClientPath -Path $targetPath) { return $targetPath }

    $driveRoot = [System.IO.Path]::GetPathRoot($targetPath).TrimEnd('\')
    $defaultExtract = Join-Path $driveRoot 'Steam'
    if (Test-IsSteamClientPath -Path $defaultExtract) { return $defaultExtract }

    $nested = Find-SteamClientPathUnderDirectory -Root $defaultExtract -MaxDepth 4
    if ($nested) { return $nested }

    return $null
}

function Install-SteamClientFromR2Archive {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$LogPath = '',
        [string]$ManifestPath = ''
    )

    $syncScript = Join-Path $PSScriptRoot 'Sync-GamesApps-Official.ps1'
    if (-not (Test-Path -LiteralPath $syncScript)) {
        Write-SteamInstallLog -LogPath $LogPath -Message "R2 sync script not found: $syncScript" 'WARN'
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        $ManifestPath = Get-ResolvedDownloadManifestPath
    }

    $targetPath = [System.IO.Path]::GetFullPath($TargetPath.Trim().TrimEnd('\'))
    $syncTarget = [System.IO.Path]::GetPathRoot($targetPath).TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($syncTarget)) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Could not resolve sync drive for Steam R2 install: $targetPath" 'WARN'
        return $null
    }

    if (-not (Test-Path -LiteralPath $syncTarget)) {
        New-Item -ItemType Directory -Path $syncTarget -Force | Out-Null
    }

    Write-SteamInstallLog -LogPath $LogPath -Message "Downloading $($script:SteamBundleArchiveName) to $syncTarget via R2 sync ..."
    $syncArgs = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', $syncScript,
        '-InstallArchive', $script:SteamBundleArchiveName,
        '-Quiet', '-NoGui'
    )
    $env:NEXTGPU_SYNC_TARGET = $syncTarget

    & powershell.exe @syncArgs | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Steam R2 download/extract failed (exit $LASTEXITCODE). See sync-games-apps log under ProgramData\nextGPU\logs." 'WARN'
        return $null
    }

    $clientPath = Resolve-SteamClientPathAfterR2Sync -TargetPath $targetPath -ManifestPath $ManifestPath
    if (-not $clientPath) {
        Write-SteamInstallLog -LogPath $LogPath -Message 'Steam.7z sync finished but no Steam client folder was found on disk.' 'WARN'
        return $null
    }

    Write-SteamInstallLog -LogPath $LogPath -Message "Steam synced from R2 at: $clientPath"
    return (Initialize-SteamClientFromExtract -TargetPath $clientPath -LogPath $LogPath)
}

function Install-SteamClientFromValveSetup {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$LogPath = '',
        [string]$ManifestPath = ''
    )

    $targetPath = [System.IO.Path]::GetFullPath($TargetPath.Trim().TrimEnd('\'))
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

    $setupPath = Join-Path $env:TEMP 'nextgpu-steamsetup.exe'
    $downloaded = $false
    $lastError = ''
    foreach ($url in $script:SteamSetupDownloadUrls) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Downloading SteamSetup.exe from $url"
        try {
            Invoke-WebRequest -Uri $url -OutFile $setupPath -UseBasicParsing
            if (Test-Path -LiteralPath $setupPath -PathType Leaf) {
                $downloaded = $true
                break
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-SteamInstallLog -LogPath $LogPath -Message "SteamSetup download failed from $url : $lastError" 'WARN'
        }
    }

    if (-not $downloaded) {
        throw "Failed to download SteamSetup.exe from all mirrors. Last error: $lastError"
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

    return $targetPath
}

function Install-SteamClientSilent {
    param(
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$LogPath = '',
        [string]$ManifestPath = ''
    )

    $targetPath = [System.IO.Path]::GetFullPath($TargetPath.Trim().TrimEnd('\'))
    Write-SteamInstallLog -LogPath $LogPath -Message "Steam install target: $targetPath"

    if (Test-IsSteamClientPath -Path $targetPath) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Steam client already present at target; skipping installer."
        Register-SteamInstallPath -SteamPath $targetPath | Out-Null
        return $targetPath
    }

    $fromR2 = Install-SteamClientFromR2Archive -TargetPath $targetPath -LogPath $LogPath -ManifestPath $ManifestPath
    if ($fromR2) {
        Write-SteamInstallLog -LogPath $LogPath -Message "Steam client ready (R2): $fromR2"
        return $fromR2
    }

    Write-SteamInstallLog -LogPath $LogPath -Message 'R2 Steam.7z not available; falling back to Valve SteamSetup.exe.' 'WARN'
    $fromSetup = Install-SteamClientFromValveSetup -TargetPath $targetPath -LogPath $LogPath -ManifestPath $ManifestPath
    Write-SteamInstallLog -LogPath $LogPath -Message "Steam client ready (installer): $fromSetup"
    return $fromSetup
}
