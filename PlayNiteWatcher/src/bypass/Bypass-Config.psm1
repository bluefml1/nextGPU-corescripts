#Requires -Version 5.1
<#
    Bypass shortcut helpers for Playnite + RunAsTool integration.
    Dot-sourced from Playnite-Common.ps1.
#>

$script:_moduleRoot = $PSScriptRoot

$script:BypassShortcutsConfigFileName = "bypass-shortcuts.json"
$script:BypassShortcutsTemplateFileName = "bypass-shortcuts.json.template"
$script:DefaultRunAsToolProgramDataDir = Join-Path $env:ProgramData "NextGPU\RunAsTool"
$script:DefaultBypassAdminUser = "NextGPU-Authority"
$script:DefaultGameShortcutsFolderName = 'Game Shortcuts'
$script:LegacyGameShortcutsFolderName = 'Bypasses'
$script:PlayNiteWatcherScriptRoot = $PSScriptRoot

function Get-DefaultGameShortcutsFolderName {
    return $script:DefaultGameShortcutsFolderName
}

function Resolve-GameShortcutsPathFromParent {
    param([string]$ParentPath)

    $parent = Get-NormalizedDirectoryPath -Path $ParentPath
    if ([string]::IsNullOrWhiteSpace($parent)) {
        return $null
    }

    $preferred = Join-Path $parent $script:DefaultGameShortcutsFolderName
    $legacy = Join-Path $parent $script:LegacyGameShortcutsFolderName

    if (Test-Path -LiteralPath $preferred) {
        return $preferred
    }
    if (Test-Path -LiteralPath $legacy) {
        return $legacy
    }

    return $preferred
}

function Get-PlayNiteWatcherScriptRoot {
    return $script:PlayNiteWatcherScriptRoot
}

function Get-DefaultRunAsToolInstallDir {
    return $script:DefaultRunAsToolProgramDataDir
}

function Get-BypassShortcutsConfigPath {
    param([string]$RepoRoot)
    return Join-Path $RepoRoot "config\playnite\$($script:BypassShortcutsConfigFileName)"
}

function Initialize-BypassShortcutsConfigFromTemplate {
    param([string]$RepoRoot)

    $target = Get-BypassShortcutsConfigPath -RepoRoot $RepoRoot
    if (Test-Path -LiteralPath $target) {
        return $target
    }

    $template = Join-Path $RepoRoot "config\playnite\$($script:BypassShortcutsTemplateFileName)"
    if (-not (Test-Path -LiteralPath $template)) {
        throw "Bypass shortcuts template not found: $template"
    }

    $dir = Split-Path -Path $target -Parent
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    Copy-Item -LiteralPath $template -Destination $target -Force
    return $target
}

function Get-BypassShortcutsConfig {
    param([string]$RepoRoot)

    $path = Initialize-BypassShortcutsConfigFromTemplate -RepoRoot $RepoRoot
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        $parsed = [PSCustomObject]@{}
    }
    if ($null -eq $parsed.bindings) {
        $parsed | Add-Member -NotePropertyName bindings -NotePropertyValue @() -Force
    }
    return [PSCustomObject]@{
        Path    = $path
        Config  = $parsed
    }
}

function Save-BypassShortcutsConfig {
    param(
        [string]$RepoRoot,
        [object]$Config
    )

    $path = Get-BypassShortcutsConfigPath -RepoRoot $RepoRoot
    if ($null -eq $Config.bindings) {
        $Config | Add-Member -NotePropertyName bindings -NotePropertyValue @() -Force
    }
    $Config.updatedAt = (Get-Date).ToString("o")
    ($Config | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-BypassBindingsFromConfig {
    param([object]$Config)
    if ($null -eq $Config -or $null -eq $Config.bindings) {
        return @()
    }
    return @($Config.bindings)
}

function Test-BypassPathLiteral {
    param([string]$Path)
    if ($null -eq $Path) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return Test-Path -LiteralPath $Path
}

function Resolve-BypassExecutablePath {
    param(
        [string]$ExePath,
        [string]$FallbackFullPath = ""
    )

    $candidate = if ($null -ne $ExePath) { $ExePath.Trim() } else { "" }
    if ([string]::IsNullOrWhiteSpace($candidate) -and -not [string]::IsNullOrWhiteSpace($FallbackFullPath)) {
        $candidate = $FallbackFullPath.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($candidate)) {
        throw "Application executable path is required. Browse for the .exe in the bypass wizard."
    }

    $isRooted = ($candidate -match '^[A-Za-z]:[\\/]') -or ($candidate -match '^\\\\')
    if (-not $isRooted) {
        $fallback = if ($null -ne $FallbackFullPath) { $FallbackFullPath.Trim() } else { "" }
        if (-not [string]::IsNullOrWhiteSpace($fallback) -and ($fallback -match '^[A-Za-z]:[\\/]' -or $fallback -match '^\\\\')) {
            $candidate = Join-Path (Split-Path -Path $fallback -Parent) ([System.IO.Path]::GetFileName($candidate))
        }
        else {
            throw "Executable must be a full path to an existing .exe (got '$candidate'). Use Browse to select the file again."
        }
    }

    if (-not (Test-BypassPathLiteral -Path $candidate)) {
        throw "Executable not found: $candidate"
    }

    return ([System.IO.Path]::GetFullPath($candidate))
}

Export-ModuleMember -Function *
