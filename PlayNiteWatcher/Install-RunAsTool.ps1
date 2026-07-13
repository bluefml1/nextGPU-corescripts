#Requires -Version 5.1
<#
.SYNOPSIS
    Download (if needed), install, and optionally launch portable RunAsTool v1.5.
.DESCRIPTION
    Always installs Sordum RunAsTool v1.5 (required for silent /I= .rnt import).
    Downloads a pinned Internet Archive snapshot; does not follow live sordum.org (v1.6).
.EXAMPLE
    .\Install-RunAsTool.ps1
    .\Install-RunAsTool.ps1 -Launch
    .\Install-RunAsTool.ps1 -SkipDownload
#>
[CmdletBinding()]
param(
    [string]$InstallDir = "",
    [string]$RepoRoot = "",
    [switch]$SkipDownload,
    [switch]$Download,
    [switch]$Launch,
    [scriptblock]$LogAction
)

$ErrorActionPreference = "Stop"

function Write-RunAsToolInstallLog {
    param([string]$Message, [string]$Level = "INFO")
    if ($LogAction) {
        & $LogAction $Message $Level
    }
    else {
        $color = switch ($Level) {
            "WARN" { "Yellow" }
            "ERROR" { "Red" }
            default { "Gray" }
        }
        Write-Host "[RunAsTool] $Message" -ForegroundColor $color
    }
}

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot "Playnite-Common.ps1")
if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
}

function Get-DefaultRunAsToolProgramDataDir {
    return Join-Path $env:ProgramData "NextGPU\RunAsTool"
}

function Get-RunAsToolToolDirCandidates {
    param([string]$WatcherRoot)
    $dirs = New-Object System.Collections.Generic.List[string]
    foreach ($root in @($scriptRoot, $WatcherRoot, (Join-Path $WatcherRoot 'PlayNiteWatcher'))) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $toolDir = Join-Path $root.TrimEnd('\') 'tools\runastool'
        if (-not ($dirs -contains $toolDir)) {
            [void]$dirs.Add($toolDir)
        }
    }
    return @($dirs)
}

function Resolve-RunAsToolBundledToolDir {
    param([string]$WatcherRoot)
    $candidates = @(Get-RunAsToolToolDirCandidates -WatcherRoot $WatcherRoot)
    foreach ($toolDir in $candidates) {
        if (Get-RunAsToolVendoredZipPath -ToolDir $toolDir) {
            return $toolDir
        }
    }
    foreach ($toolDir in $candidates) {
        if (Test-Path -LiteralPath $toolDir) {
            return $toolDir
        }
    }
    $fallback = Join-Path $scriptRoot 'tools\runastool'
    if (-not (Test-Path -LiteralPath $fallback)) {
        New-Item -ItemType Directory -Path $fallback -Force | Out-Null
    }
    return $fallback
}

function Get-RunAsToolBundledCandidates {
    param([string]$WatcherRoot)
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($toolDir in (Get-RunAsToolToolDirCandidates -WatcherRoot $WatcherRoot)) {
        foreach ($rel in @(
                'RunAsTool_x64.exe',
                'RunAsTool.exe',
                'RunAsTool\RunAsTool_x64.exe',
                'RunAsTool\RunAsTool.exe'
            )) {
            [void]$list.Add((Join-Path $toolDir $rel))
        }
    }
    return @($list)
}

function Find-RunAsToolSourceExe {
    param([string]$WatcherRoot)
    foreach ($candidate in (Get-RunAsToolBundledCandidates -WatcherRoot $WatcherRoot)) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    foreach ($toolDir in (Get-RunAsToolToolDirCandidates -WatcherRoot $WatcherRoot)) {
        if (-not (Test-Path -LiteralPath $toolDir)) { continue }
        $nested = Get-ChildItem -LiteralPath $toolDir -Recurse -Filter "RunAsTool*.exe" -File -ErrorAction SilentlyContinue |
            Sort-Object { if ($_.Name -ieq "RunAsTool_x64.exe") { 0 } else { 1 } } |
            Select-Object -First 1
        if ($nested) {
            return $nested.FullName
        }
    }

    return $null
}

# Pin to Sordum RunAsTool v1.5 (CLI .rnt import). Live sordum.org now serves v1.6.
$script:RunAsToolPinnedVersion = '1.5'
$script:RunAsToolPinnedZipSha256 = @(
    # Wayback 20240616002123 (Scoop/Shovel hash for RunAsTool 1.5)
    'bfe64c76792dc3dd40206895ed49c0ca462f6f618485060c96fa2d57dddc1e60',
    # Wayback 20251202063630 (still FileVersion 1.5.0.0)
    '3b31dbfca6670cf92080059cc5e165570a05e8674a4f154a67330d658906a823'
)

function Test-RunAsToolZipFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    if ((Get-Item -LiteralPath $Path).Length -lt 1000) {
        return $false
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return ($bytes.Length -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B)
}

function Get-RunAsToolFileVersionText {
    param([string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) {
        return $null
    }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($ExePath)
        if (-not [string]::IsNullOrWhiteSpace($vi.FileVersion)) {
            return $vi.FileVersion.Trim()
        }
        if (-not [string]::IsNullOrWhiteSpace($vi.ProductVersion)) {
            return $vi.ProductVersion.Trim()
        }
    }
    catch { }
    return $null
}

function Test-RunAsToolIsPinnedVersion {
    param([string]$ExePath)
    $ver = Get-RunAsToolFileVersionText -ExePath $ExePath
    if ([string]::IsNullOrWhiteSpace($ver)) {
        return $false
    }
    return ($ver -match ('^' + [regex]::Escape($script:RunAsToolPinnedVersion) + '(\.|$)'))
}

function Get-RunAsToolDownloadUrls {
    # Fallback only: Internet Archive snapshots of the v1.5 zip.
    # Primary source is the in-repo RunAsTool-1.5.zip (Wayback often returns 429).
    return @(
        'https://web.archive.org/web/20240616002123id_/https://www.sordum.org/files/download/runastool/RunAsTool.zip',
        'https://web.archive.org/web/20240108180013id_/https://www.sordum.org/files/download/runastool/RunAsTool.zip',
        'https://web.archive.org/web/20251202063630id_/https://www.sordum.org/files/download/runastool/RunAsTool.zip'
    )
}

function Test-RunAsToolPinnedZipHash {
    param([string]$Path)
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return ($script:RunAsToolPinnedZipSha256 -contains $hash)
}

function Get-RunAsToolVendoredZipPath {
    param([string]$ToolDir)
    $candidates = @(
        (Join-Path $ToolDir 'RunAsTool-1.5.zip'),
        (Join-Path $ToolDir 'RunAsTool.zip')
    )
    foreach ($path in $candidates) {
        if ((Test-Path -LiteralPath $path) -and (Test-RunAsToolZipFile -Path $path) -and (Test-RunAsToolPinnedZipHash -Path $path)) {
            return $path
        }
    }
    return $null
}

function Expand-RunAsToolPinnedZip {
    param(
        [Parameter(Mandatory)]
        [string]$ZipPath,
        [Parameter(Mandatory)]
        [string]$DestinationDir
    )

    if (-not (Test-RunAsToolZipFile -Path $ZipPath)) {
        throw "RunAsTool archive is not a valid zip: $ZipPath"
    }
    if (-not (Test-RunAsToolPinnedZipHash -Path $ZipPath)) {
        $got = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        throw "RunAsTool archive SHA256 $got is not a known v$($script:RunAsToolPinnedVersion) hash: $ZipPath"
    }

    $extractRoot = Join-Path $DestinationDir "_extract"
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-Item -LiteralPath $extractRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractRoot -Force

    $found = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -Filter "RunAsTool*.exe" -File |
        Sort-Object { if ($_.Name -ieq "RunAsTool_x64.exe") { 0 } else { 1 } })

    if (-not $found -or $found.Count -eq 0) {
        throw "RunAsTool archive did not contain RunAsTool.exe: $ZipPath"
    }

    $bad = @($found | Where-Object { -not (Test-RunAsToolIsPinnedVersion -ExePath $_.FullName) })
    if ($bad.Count -gt 0) {
        $details = ($bad | ForEach-Object {
            "{0}={1}" -f $_.Name, (Get-RunAsToolFileVersionText -ExePath $_.FullName)
        }) -join ', '
        throw "RunAsTool archive is not v$($script:RunAsToolPinnedVersion) ($details). Refusing to install."
    }

    foreach ($exe in $found) {
        $dest = Join-Path $DestinationDir $exe.Name
        Copy-Item -LiteralPath $exe.FullName -Destination $dest -Force
        Write-RunAsToolInstallLog "Extracted $($exe.Name) (v$(Get-RunAsToolFileVersionText -ExePath $exe.FullName)) -> $dest"
    }

    $nestedDir = Join-Path $DestinationDir "RunAsTool"
    if (-not (Test-Path -LiteralPath $nestedDir)) {
        New-Item -ItemType Directory -Path $nestedDir -Force | Out-Null
    }
    foreach ($exe in $found) {
        Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $nestedDir $exe.Name) -Force
    }

    Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-RunAsToolR2RemotePath {
    return 'next-gpu-storage-app/RunAsTool-1.5.zip'
}

function Invoke-DownloadRunAsToolZipFromR2 {
    param(
        [Parameter(Mandatory)][string]$DestinationZip,
        [string]$RemoteName = 'r2games'
    )

    $rclone = Get-Command rclone -ErrorAction SilentlyContinue
    if (-not $rclone) { return $false }

    $config = Join-Path $env:USERPROFILE '.config\rclone\rclone.conf'
    if (-not (Test-Path -LiteralPath $config)) { return $false }

    $remoteSpec = "${RemoteName}:$((Get-RunAsToolR2RemotePath).Trim().TrimStart('/'))"
    $temp = "$DestinationZip.download"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }

    Write-RunAsToolInstallLog "Downloading RunAsTool v$($script:RunAsToolPinnedVersion) from R2: $remoteSpec"
    & $rclone.Source copyto $remoteSpec $temp --config $config | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temp) -or (Get-Item -LiteralPath $temp).Length -lt 1000) {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        Write-RunAsToolInstallLog 'R2 download failed or object missing; trying other sources.' 'WARN'
        return $false
    }

    try {
        if (-not (Test-RunAsToolZipFile -Path $temp) -or -not (Test-RunAsToolPinnedZipHash -Path $temp)) {
            $got = if (Test-Path -LiteralPath $temp) { (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash.ToLowerInvariant() } else { 'missing' }
            Write-RunAsToolInstallLog "R2 object is not a verified v$($script:RunAsToolPinnedVersion) zip (SHA256 $got)." 'WARN'
            return $false
        }
        $destParent = Split-Path -Parent $DestinationZip
        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
        Move-Item -LiteralPath $temp -Destination $DestinationZip -Force
        Write-RunAsToolInstallLog "Cached vendored zip from R2: $DestinationZip"
        return $true
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-DownloadRunAsToolZip {
    param([string]$DestinationDir)

    if (-not (Test-Path -LiteralPath $DestinationDir)) {
        New-Item -ItemType Directory -Path $DestinationDir -Force | Out-Null
    }

    $vendored = Get-RunAsToolVendoredZipPath -ToolDir $DestinationDir
    if ($vendored) {
        Write-RunAsToolInstallLog "Using vendored RunAsTool v$($script:RunAsToolPinnedVersion) zip: $vendored"
        Expand-RunAsToolPinnedZip -ZipPath $vendored -DestinationDir $DestinationDir
        return
    }

    $canonicalVendored = Join-Path $DestinationDir 'RunAsTool-1.5.zip'
    if (Invoke-DownloadRunAsToolZipFromR2 -DestinationZip $canonicalVendored) {
        Expand-RunAsToolPinnedZip -ZipPath $canonicalVendored -DestinationDir $DestinationDir
        return
    }

    $zipPath = Join-Path $DestinationDir "runastool.zip"
    $urls = @(Get-RunAsToolDownloadUrls)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $downloaded = $false
    foreach ($url in $urls) {
        $attempt = 0
        $maxAttempts = 3
        while ($attempt -lt $maxAttempts -and -not $downloaded) {
            $attempt++
            try {
                Write-RunAsToolInstallLog "Downloading RunAsTool v$($script:RunAsToolPinnedVersion) from $url (attempt $attempt/$maxAttempts) ..."
                if (Test-Path -LiteralPath $zipPath) {
                    Remove-Item -LiteralPath $zipPath -Force
                }
                Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
                if (-not (Test-RunAsToolZipFile -Path $zipPath)) {
                    Write-RunAsToolInstallLog "Download from $url was not a valid zip; trying next URL." "WARN"
                    break
                }
                if (-not (Test-RunAsToolPinnedZipHash -Path $zipPath)) {
                    $got = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
                    Write-RunAsToolInstallLog "Zip SHA256 $got is not a known RunAsTool v$($script:RunAsToolPinnedVersion) archive; trying next URL." "WARN"
                    break
                }
                $downloaded = $true
            }
            catch {
                $msg = $_.Exception.Message
                Write-RunAsToolInstallLog "Download failed ($url): $msg" "WARN"
                $is429 = ($msg -match '429') -or ($msg -match 'Too Many Requests')
                if ($is429 -and $attempt -lt $maxAttempts) {
                    $delay = [Math]::Min(60, 5 * [Math]::Pow(2, $attempt - 1))
                    Write-RunAsToolInstallLog "Rate limited (429); waiting ${delay}s before retry..." "WARN"
                    Start-Sleep -Seconds $delay
                    continue
                }
                break
            }
        }
        if ($downloaded) { break }
    }

    if (-not $downloaded) {
        throw @(
            "Could not download RunAsTool v$($script:RunAsToolPinnedVersion) (Internet Archive may be rate-limiting).",
            "Option A: place verified zip at PlayNiteWatcher\tools\runastool\RunAsTool-1.5.zip",
            "  .\PlayNiteWatcher\Fetch-RunAsToolVendoredZip.ps1 -SourceZip <path>",
            "  or upload once: .\PlayNiteWatcher\Push-RunAsToolVendoredZipToR2.ps1 -SourceZip <path>",
            "  then: .\PlayNiteWatcher\Fetch-RunAsToolVendoredZip.ps1"
        ) -join ' '
    }

    try {
        Expand-RunAsToolPinnedZip -ZipPath $zipPath -DestinationDir $DestinationDir
    }
    finally {
        Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    }
}

if ([string]::IsNullOrWhiteSpace($InstallDir)) {
    $InstallDir = Get-DefaultRunAsToolProgramDataDir
}

$installDir = $InstallDir.TrimEnd('\')
if (-not (Test-Path -LiteralPath $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}

$destExe = Join-Path $installDir "RunAsTool.exe"
$destX64 = Join-Path $installDir "RunAsTool_x64.exe"
$installedPath = $null
$alreadyInstalled = $false

if (Test-Path -LiteralPath $destX64) {
    $installedPath = $destX64
    $alreadyInstalled = $true
}
elseif (Test-Path -LiteralPath $destExe) {
    $installedPath = $destExe
    $alreadyInstalled = $true
}

if ($alreadyInstalled -and -not (Test-RunAsToolIsPinnedVersion -ExePath $installedPath)) {
    $foundVer = Get-RunAsToolFileVersionText -ExePath $installedPath
    Write-RunAsToolInstallLog "Installed RunAsTool is v$foundVer (need v$($script:RunAsToolPinnedVersion)); will replace." "WARN"
    foreach ($stale in @($destX64, $destExe)) {
        if (Test-Path -LiteralPath $stale) {
            Remove-Item -LiteralPath $stale -Force -ErrorAction SilentlyContinue
        }
    }
    $alreadyInstalled = $false
    $installedPath = $null
}
elseif ($alreadyInstalled) {
    Write-RunAsToolInstallLog "RunAsTool v$($script:RunAsToolPinnedVersion) already installed: $installedPath"
}

$shouldDownload = (-not $SkipDownload.IsPresent) -and ($Download.IsPresent -or -not $alreadyInstalled)
$bundledDir = Resolve-RunAsToolBundledToolDir -WatcherRoot $RepoRoot
if (-not (Test-Path -LiteralPath $bundledDir)) {
    New-Item -ItemType Directory -Path $bundledDir -Force | Out-Null
}

if (-not $alreadyInstalled) {
    $source = Find-RunAsToolSourceExe -WatcherRoot $RepoRoot
    if ($source -and -not (Test-RunAsToolIsPinnedVersion -ExePath $source)) {
        $foundVer = Get-RunAsToolFileVersionText -ExePath $source
        Write-RunAsToolInstallLog "Bundled RunAsTool is v$foundVer (need v$($script:RunAsToolPinnedVersion)); ignoring and downloading pinned build." "WARN"
        $source = $null
    }

    if (-not $source -and $shouldDownload) {
        Invoke-DownloadRunAsToolZip -DestinationDir $bundledDir
        $source = Find-RunAsToolSourceExe -WatcherRoot $RepoRoot
    }

    if (-not $source) {
        throw @(
            "RunAsTool v$($script:RunAsToolPinnedVersion) not found.",
            "Ensure vendored zip exists at: $(Join-Path $scriptRoot 'tools\runastool\RunAsTool-1.5.zip')",
            "Or place RunAsTool.exe (FileVersion $($script:RunAsToolPinnedVersion).x) in: $bundledDir"
        ) -join "`n"
    }

    if (-not (Test-RunAsToolIsPinnedVersion -ExePath $source)) {
        throw "Resolved RunAsTool is not v$($script:RunAsToolPinnedVersion): $source"
    }

    $leaf = [System.IO.Path]::GetFileName($source)
    $target = Join-Path $installDir $leaf
    Copy-Item -LiteralPath $source -Destination $target -Force
    Write-RunAsToolInstallLog "Installed RunAsTool v$(Get-RunAsToolFileVersionText -ExePath $target): $target"
    $installedPath = $target
}

$result = [PSCustomObject]@{
    Path      = $installedPath
    Installed = (-not $alreadyInstalled)
    Launched  = $false
    Process   = $null
}

if ($Launch.IsPresent -and $installedPath) {
    $proc = Start-RunAsToolApplication -ExePath $installedPath
    $result.Launched = $true
    $result.Process = $proc
}

return $result
