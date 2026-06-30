#Requires -Version 5.1
<#
.SYNOPSIS
    Register an app in RunAsTool and create a bypass shortcut in the Game Shortcuts folder.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ExePath,
    [Parameter(Mandatory)]
    [string]$ShortcutName,
    [Parameter(Mandatory)]
    [string]$BypassesPath,
    [string]$RunAsToolExe = "",
    [string]$AdminUser = "NextGPU-Authority",
    [securestring]$AdminPassword,
    [string]$TileDisplayName = "",
    [string]$RepoRoot = "",
    [switch]$SkipUiAutomation,
    [switch]$ManualFallback,
    [int]$WaitSeconds = 600,
    [scriptblock]$LogAction
)

$ErrorActionPreference = "Stop"

function Write-BypassLog {
    param([string]$Message, [string]$Level = "INFO")
    if ($LogAction) { & $LogAction $Message $Level }
    else { Write-Host "[RunAsToolBypass] $Message" }
}

$scriptRoot = $PSScriptRoot
$boundExePath = $ExePath
$boundBypassesPath = $BypassesPath
$boundRunAsToolExe = $RunAsToolExe
$boundRepoRoot = $RepoRoot

. (Join-Path $scriptRoot "Playnite-Common.ps1")
$guiAutomationScript = Join-Path $scriptRoot "Invoke-RunAsToolGuiAutomation.ps1"
if (-not (Test-BypassPathLiteral -Path $guiAutomationScript)) {
    throw "RunAsTool UI automation script not found. Deploy PlayNiteWatcher\Invoke-RunAsToolGuiAutomation.ps1 on this machine: $guiAutomationScript"
}
. $guiAutomationScript
if (-not (Get-Command -Name Invoke-RunAsToolBypassShortcutAutomation -ErrorAction SilentlyContinue)) {
    throw "Invoke-RunAsToolBypassShortcutAutomation is not available. Ensure Invoke-RunAsToolGuiAutomation.ps1 is deployed and not truncated."
}

$ExePath = $boundExePath
$BypassesPath = $boundBypassesPath
$RunAsToolExe = $boundRunAsToolExe
$RepoRoot = $boundRepoRoot

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $scriptRoot
}

$ExePath = Resolve-BypassExecutablePath -ExePath $ExePath

$shortcutName = Sanitize-BypassShortcutFileName -Name $ShortcutName
if ([string]::IsNullOrWhiteSpace($shortcutName)) {
    throw "Shortcut name is invalid."
}

if ([string]::IsNullOrWhiteSpace($RunAsToolExe)) {
    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $configRef = [ref]$wrapper.Config
    $RunAsToolExe = Ensure-RunAsToolExeResolved -RepoRoot $RepoRoot -ConfigRef $configRef
    Save-BypassShortcutsConfig -RepoRoot $RepoRoot -Config $configRef.Value
}

$launchPath = Join-Path $BypassesPath "$shortcutName.lnk"
Assert-BypassShortcutPaths -ExePath $ExePath -BypassesPath $BypassesPath -RunAsToolExe $RunAsToolExe -LaunchPath $launchPath

if (-not (Test-BypassPathLiteral -Path $ExePath)) {
    throw "Executable not found: $ExePath"
}

if (-not (Test-BypassPathLiteral -Path $BypassesPath)) {
    New-Item -ItemType Directory -Path $BypassesPath -Force | Out-Null
}

if ((Test-BypassPathLiteral -Path $launchPath) -and -not $ManualFallback.IsPresent) {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $overwrite = [System.Windows.Forms.MessageBox]::Show(
        "Shortcut already exists:`n$launchPath`n`nOverwrite?",
        "Bypass shortcut",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($overwrite -eq [System.Windows.Forms.DialogResult]::Cancel) {
        throw "Bypass shortcut creation cancelled."
    }
    if ($overwrite -eq [System.Windows.Forms.DialogResult]::No) {
        throw "Bypass shortcut already exists: $launchPath"
    }
    Remove-Item -LiteralPath $launchPath -Force -ErrorAction SilentlyContinue
}

$displayName = if ([string]::IsNullOrWhiteSpace($TileDisplayName)) { $shortcutName } else { $TileDisplayName }

function Show-RunAsToolManualInstructions {
    param(
        [string]$TargetExe,
        [string]$DestLnk,
        [string]$Label
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $msg = @"
RunAsTool automation failed. Create the shortcut manually in RunAsTool (Edit mode):

1. File -> Add File -> select:
   $TargetExe

2. Select the app tile -> enable "Run as administrator".

3. Right-click the tile -> Create shortcut -> save as:
   $DestLnk

Display name suggestion: $Label

Click OK when the shortcut exists, or Cancel to abort.
"@
    $result = [System.Windows.Forms.MessageBox]::Show(
        $msg,
        "Create RunAsTool shortcut (manual)",
        [System.Windows.Forms.MessageBoxButtons]::OKCancel,
        [System.Windows.Forms.MessageBoxIcon]::Information)

    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

$method = "UiAutomation"
$automationResult = $null

if (-not $SkipUiAutomation.IsPresent) {
    Write-BypassLog "RunAsTool automation starting: exe=$ExePath runAsTool=$RunAsToolExe -> $launchPath"
    try {
        $automationResult = Invoke-RunAsToolBypassShortcutAutomation `
            -RunAsToolExe $RunAsToolExe `
            -ExePath $ExePath `
            -DestLnk $launchPath `
            -AdminUser $AdminUser `
            -AdminPassword $AdminPassword `
            -TileDisplayName $displayName `
            -TimeoutSec ([Math]::Min($WaitSeconds, 120)) `
            -LogAction $LogAction
    }
    catch {
        Write-BypassLog "RunAsTool automation failed: $($_.Exception.Message)" "WARN"
        if (-not $ManualFallback.IsPresent) {
            throw
        }
        $method = "Manual"
    }
}
else {
    $method = "Manual"
    Write-BypassLog "Launching RunAsTool (automation skipped): $RunAsToolExe"
    Start-RunAsToolApplication -ExePath $RunAsToolExe | Out-Null
}

if ($automationResult) {
    return $automationResult
}

if ($method -eq "Manual") {
    if (-not $SkipUiAutomation.IsPresent) {
        Start-RunAsToolApplication -ExePath $RunAsToolExe | Out-Null
        Start-Sleep -Seconds 1
    }
    $ok = Show-RunAsToolManualInstructions -TargetExe $ExePath -DestLnk $launchPath -Label $displayName
    if (-not $ok) {
        throw "RunAsTool shortcut creation cancelled by user."
    }
}

$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-BypassPathLiteral -Path $launchPath) {
        $info = Get-ShortcutLaunchInfo -LnkPath $launchPath
        if ($info) {
            Write-BypassLog "Bypass shortcut ready: $launchPath (target=$($info.TargetPath))"
            return [PSCustomObject]@{
                Success      = $true
                LaunchPath   = $launchPath
                ExePath      = $ExePath
                Method       = $method
                ShortcutInfo = $info
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($BypassesPath)) {
        $anyNew = Get-ChildItem -LiteralPath $BypassesPath -Filter "*.lnk" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($anyNew -and $anyNew.LastWriteTime -gt (Get-Date).AddSeconds(-$WaitSeconds)) {
            if (-not (Test-BypassPathLiteral -Path $launchPath)) {
                try {
                    Move-Item -LiteralPath $anyNew.FullName -Destination $launchPath -Force
                    Write-BypassLog "Renamed newest shortcut -> $launchPath"
                }
                catch {
                    Copy-Item -LiteralPath $anyNew.FullName -Destination $launchPath -Force
                    Write-BypassLog "Copied newest shortcut -> $launchPath"
                }
            }
        }
    }

    Start-Sleep -Seconds 2
}

throw "Timed out waiting for bypass shortcut: $launchPath"
