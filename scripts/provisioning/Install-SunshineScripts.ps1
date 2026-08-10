#Requires -Version 5.1
<#
.SYNOPSIS
    Deploys repo sunshine.conf and support scripts after Sunshine install or reinstall.
.DESCRIPTION
    Copies sunshine\sunshine.conf to C:\Program Files\Sunshine\config\, applies dd_* display
    settings, then copies helper scripts to C:\Program Files\Sunshine\scripts\.
    VDD output_name is set separately by Set-SunshineVddOutput.ps1. Does not modify apps.json.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = "",
    [switch]$Quiet,
    [switch]$SkipVddBinding
)

$ErrorActionPreference = "Stop"

function Write-SetupMessage {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    if ($Quiet -and $Level -eq "INFO") {
        return
    }

    switch ($Level) {
        "WARN" { Write-Host $Message -ForegroundColor Yellow }
        "ERROR" { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message }
    }
}

function Resolve-RepoRoot {
    param([string]$Override)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.TrimEnd('\')
    }

    if ($env:NEXTGPU_REPO_ROOT) {
        return $env:NEXTGPU_REPO_ROOT.TrimEnd('\')
    }

    return (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

function Set-SunshineConfLine {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Value
    )

    if ($Content -match ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=')) {
        return ($Content -replace ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=.*'), ($Name + ' = ' + $Value))
    }

    return ($Content.TrimEnd() + "`r`n" + $Name + ' = ' + $Value + "`r`n")
}

function Install-SunshineConfigFromRepo {
    param(
        [string]$SourceFolder,
        [switch]$SkipVddBinding
    )

    $sunshineConfigDir = 'C:\Program Files\Sunshine\config'
    $confDest = Join-Path $sunshineConfigDir 'sunshine.conf'
    $confSources = @(
        (Join-Path $SourceFolder 'config\sunshine.conf'),
        (Join-Path $SourceFolder 'sunshine.conf')
    )

    Write-SetupMessage '=== Installing Sunshine configuration ==='

    $confSource = $null
    foreach ($candidate in $confSources) {
        if (Test-Path -LiteralPath $candidate) {
            $confSource = $candidate
            break
        }
    }

    if (-not $confSource) {
        Write-SetupMessage "  WARN sunshine.conf not found under $SourceFolder" 'WARN'
        return $false
    }

    if (-not (Test-Path -LiteralPath $sunshineConfigDir)) {
        New-Item -ItemType Directory -Path $sunshineConfigDir -Force | Out-Null
    }

    Copy-Item -LiteralPath $confSource -Destination $confDest -Force
    Write-SetupMessage "  OK sunshine.conf copied to config from $confSource"

    if (-not $SkipVddBinding.IsPresent) {
        $content = Get-Content -Raw -LiteralPath $confDest
        $content = Set-SunshineConfLine -Content $content -Name 'dd_configuration_option' -Value 'ensure_only_display'
        $content = Set-SunshineConfLine -Content $content -Name 'dd_config_revert_on_disconnect' -Value 'enabled'

        [System.IO.File]::WriteAllText($confDest, $content, [Text.UTF8Encoding]::new($false))
        Write-SetupMessage '  OK applied dd_configuration_option and dd_config_revert_on_disconnect'
    }
    else {
        Write-SetupMessage '  SKIP dd_* VDD display settings (VDD binding disabled)'
    }
    return $true
}

function Install-SunshineSupportScripts {
    param(
        [string]$SourceFolder
    )

    $sunshineScripts = 'C:\Program Files\Sunshine\scripts'
    $scriptFiles = @(
        'steam_logout.bat',
        'epic_logout.bat',
        'eventLogs.ps1',
        'endSession.ps1',
        'launchGame.ps1',
        'nextGpuSessionCommon.ps1',
        'startSession.ps1',
        'cancelSession.ps1'
    )

    Write-SetupMessage '=== Installing Sunshine support scripts ==='

    if (-not (Test-Path -LiteralPath $sunshineScripts)) {
        New-Item -ItemType Directory -Path $sunshineScripts -Force | Out-Null
        Write-SetupMessage "Created: $sunshineScripts"
    }

    $copiedCount = 0
    foreach ($file in $scriptFiles) {
        $sourcePath = Join-Path $SourceFolder $file
        $destPath = Join-Path $sunshineScripts $file

        if (-not (Test-Path -LiteralPath $sourcePath)) {
            Write-SetupMessage "  WARN $file not found in $SourceFolder" 'WARN'
            continue
        }

        Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
        Write-SetupMessage "  OK $file copied to scripts"
        $copiedCount++
    }

    if ($copiedCount -eq 0) {
        Write-SetupMessage "No Sunshine support scripts were copied from $SourceFolder" 'ERROR'
        exit 1
    }

    Write-SetupMessage "Installed $copiedCount Sunshine support script(s)."
}

$repoRoot = Resolve-RepoRoot -Override $RepoRoot
$sourceFolder = Join-Path $repoRoot 'sunshine'

if (-not (Test-Path -LiteralPath $sourceFolder)) {
    Write-SetupMessage "Sunshine source folder not found: $sourceFolder" 'WARN'
    exit 0
}

$confOk = Install-SunshineConfigFromRepo -SourceFolder $sourceFolder -SkipVddBinding:$SkipVddBinding.IsPresent
if (-not $confOk) {
    Write-SetupMessage 'Continuing with script deploy only.' 'WARN'
}

Install-SunshineSupportScripts -SourceFolder $sourceFolder
