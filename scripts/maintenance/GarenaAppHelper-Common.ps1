#Requires -Version 5.1
# Shared Garena gxxapphelper path helpers (no param block — safe to dot-source).

$script:GarenaAppHelperMaintenanceDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:GarenaAppHelperPathFileName = 'GarenaAppHelper.path'
$script:GarenaAppHelperExeName = 'gxxapphelper.exe'

function Get-GarenaProgramDataConfigDir {
    $dir = Join-Path $env:ProgramData 'nextGPU\garena'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Get-GarenaAppHelperPathFile {
    return Join-Path (Get-GarenaProgramDataConfigDir) $script:GarenaAppHelperPathFileName
}

function Get-GarenaAppHelperRepoPathFile {
    return Join-Path $script:GarenaAppHelperMaintenanceDir $script:GarenaAppHelperPathFileName
}

function Resolve-GarenaPathSafe {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $trimmed = $Path.Trim().Trim('"').Trim([char]0xFEFF)
    if ([string]::IsNullOrWhiteSpace($trimmed)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($trimmed)
    }
    catch {
        return $null
    }
}

function Write-GarenaPathFileLines {
    param(
        [Parameter(Mandatory)][string[]]$Lines,
        [Parameter(Mandatory)][string]$Path
    )
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

function Save-GarenaAppHelperPath {
    param(
        [Parameter(Mandatory)][string]$HelperExePath,
        [string]$ClientDir = ''
    )
    $helperFull = Resolve-GarenaPathSafe -Path $HelperExePath
    if (-not $helperFull) {
        throw "Invalid helper path: $HelperExePath"
    }
    $lines = @($helperFull)
    $clientFull = Resolve-GarenaPathSafe -Path $ClientDir
    if ($clientFull) {
        $lines += "ClientDir=$clientFull"
    }
    Write-GarenaPathFileLines -Lines $lines -Path (Get-GarenaAppHelperPathFile)
    try {
        Write-GarenaPathFileLines -Lines $lines -Path (Get-GarenaAppHelperRepoPathFile)
    }
    catch { }
}

function Read-SavedGarenaAppHelperExePath {
    foreach ($pathFile in @((Get-GarenaAppHelperPathFile), (Get-GarenaAppHelperRepoPathFile))) {
        if (-not (Test-Path -LiteralPath $pathFile)) { continue }
        foreach ($line in @(Get-Content -LiteralPath $pathFile -ErrorAction SilentlyContinue)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $raw = $line.Trim().Trim([char]0xFEFF)
            if ($raw.StartsWith('ClientDir=', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
            $candidate = Resolve-GarenaPathSafe -Path $raw
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                return $candidate
            }
        }
    }
    return $null
}

function Get-GarenaShortcutTargetPath {
    param([Parameter(Mandatory)][string]$LinkPath)
    if (-not (Test-Path -LiteralPath $LinkPath -PathType Leaf)) { return $null }
    try {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut((Resolve-GarenaPathSafe -Path $LinkPath))
        $target = Resolve-GarenaPathSafe -Path $shortcut.TargetPath
        if ($target -and (Test-Path -LiteralPath $target)) {
            return $target
        }
    }
    catch { }
    return $null
}

function Find-GarenaAppHelperUnderRoot {
    param([Parameter(Mandatory)][string]$RootDir)

    $root = Resolve-GarenaPathSafe -Path $RootDir
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) {
        return $null
    }

    $direct = Join-Path $root $script:GarenaAppHelperExeName
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        return $direct
    }

    $hit = Get-ChildItem -LiteralPath $root -Recurse -Filter $script:GarenaAppHelperExeName -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($hit) {
        return $hit.FullName
    }

    return $null
}

function Get-GarenaAppHelperExePath {
    param(
        [string]$SearchClientDir,
        [string]$PreferredHelperPath,
        [switch]$PreferClientSearch
    )

    $preferred = Resolve-GarenaPathSafe -Path $PreferredHelperPath
    if ($preferred -and (Test-Path -LiteralPath $preferred -PathType Leaf)) {
        return $preferred
    }

    $clientDir = Resolve-GarenaPathSafe -Path $SearchClientDir
    if ($clientDir -and (Test-Path -LiteralPath $clientDir -PathType Container)) {
        $fromClient = Find-GarenaAppHelperUnderRoot -RootDir $clientDir
        if ($fromClient) { return $fromClient }

        $serviceLink = Join-Path $clientDir 'Garena platform service.lnk'
        $linkTarget = Get-GarenaShortcutTargetPath -LinkPath $serviceLink
        if ($linkTarget) {
            if ((Test-Path -LiteralPath $linkTarget -PathType Leaf) -and
                ($linkTarget.EndsWith($script:GarenaAppHelperExeName, [System.StringComparison]::OrdinalIgnoreCase))) {
                return $linkTarget
            }
            $linkDir = if (Test-Path -LiteralPath $linkTarget -PathType Container) {
                $linkTarget
            }
            else {
                Split-Path -Parent $linkTarget
            }
            $fromLink = Find-GarenaAppHelperUnderRoot -RootDir $linkDir
            if ($fromLink) { return $fromLink }
        }
    }

    if (-not $PreferClientSearch) {
        $saved = Read-SavedGarenaAppHelperExePath
        if ($saved) { return $saved }
    }

    $searchRoots = New-Object System.Collections.Generic.List[string]
    if ($clientDir) { [void]$searchRoots.Add($clientDir) }

    $manifestPath = Join-Path $script:GarenaAppHelperMaintenanceDir 'GamesApps-Manifest.ps1'
    if (Test-Path -LiteralPath $manifestPath) {
        . $manifestPath
        $garenaExe = Get-ResolvedGarenaClientExePath
        if ($garenaExe) {
            $clientFromExe = Resolve-GarenaPathSafe -Path (Split-Path -Parent $garenaExe)
            if ($clientFromExe -and -not $searchRoots.Contains($clientFromExe)) {
                [void]$searchRoots.Add($clientFromExe)
            }
        }
    }

    foreach ($root in $searchRoots) {
        $found = Find-GarenaAppHelperUnderRoot -RootDir $root
        if ($found) { return $found }
    }

    if ($PreferClientSearch) {
        $saved = Read-SavedGarenaAppHelperExePath
        if ($saved) { return $saved }
    }

    return $null
}
