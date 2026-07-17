#Requires -Version 5.1
<#
.SYNOPSIS
    Automated bypass setup: pick parent folder, copy seed shortcuts, import RunAsTool .rnt.
.EXAMPLE
    .\Setup-PlayniteBypassAutomated.ps1
    .\Setup-PlayniteBypassAutomated.ps1 -ParentPath Z:\
#>
[CmdletBinding()]
param(
    [string]$ParentPath = "",
    [string]$RepoRoot = "",
    [string]$SeedRoot = "",
    [string]$RntPath = "",
    [string]$ShortcutsSeedPath = "",
    [switch]$ResetRunAsToolList,
    [switch]$NoPrompt,
    [string]$AdminUser = ""
)

$ErrorActionPreference = "Stop"
$script:WatcherRoot = $PSScriptRoot
. (Join-Path $script:WatcherRoot "Playnite-Common.ps1")

$script:ModuleRoot = if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    Resolve-PlayNiteWatcherRepoRoot -Candidate $script:WatcherRoot
} else {
    $RepoRoot.TrimEnd('\')
}

$PlayniteBypassSyncLogPath = Join-Path $script:WatcherRoot "Sync-PlayniteBypassShortcuts.log"
$script:LogFile = $PlayniteBypassSyncLogPath

function Write-BypassSetupLog {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($PlayniteBypassSyncLogPath)) {
        Add-Content -LiteralPath $PlayniteBypassSyncLogPath -Value $line -Encoding utf8
    }
}

if ([string]::IsNullOrWhiteSpace($SeedRoot)) {
    $SeedRoot = Get-DefaultBypassSeedRoot
}
if ([string]::IsNullOrWhiteSpace($RntPath)) {
    $RntPath = Join-Path $SeedRoot "RunAsTool.rnt"
}
if ([string]::IsNullOrWhiteSpace($ShortcutsSeedPath)) {
    $ShortcutsSeedPath = Join-Path $SeedRoot "Game Shortcuts"
}
if ([string]::IsNullOrWhiteSpace($AdminUser)) {
    $AdminUser = $script:DefaultBypassAdminUser
}
$resetList = $true
if ($PSBoundParameters.ContainsKey('ResetRunAsToolList')) {
    $resetList = $ResetRunAsToolList.IsPresent
}

Write-BypassSetupLog "=== Setup-PlayniteBypassAutomated started ==="
Write-BypassSetupLog "Seed root: $SeedRoot"

$parentPath = $ParentPath
if ([string]::IsNullOrWhiteSpace($parentPath)) {
    $picked = Show-PlayniteFolderBrowserDialog -Description "Select parent folder for Game Shortcuts subfolder"
    if (-not $picked) {
        throw "Folder selection cancelled."
    }
    $parentPath = $picked
}

$folder = Initialize-BypassShortcutsFolder -ParentPath $parentPath -NoPrompt:$NoPrompt
if (-not $folder) {
    throw "Game Shortcuts folder setup cancelled."
}

Write-BypassSetupLog "Game Shortcuts folder: $($folder.BypassesPath)"

$syncList = Get-BypassSyncList -RepoRoot $script:ModuleRoot
if ($syncList.Count -eq 0) {
    throw "Bypass sync list is empty. Add entries on the Bypass Sync tab before running Setup Bypass."
}

$copyStats = Copy-BypassGameShortcutsForSyncList `
    -ShortcutsSeedPath $ShortcutsSeedPath `
    -BypassesPath $folder.BypassesPath `
    -RepoRoot $script:ModuleRoot `
    -NoPrompt:$NoPrompt `
    -LogAction { param($m, $l = 'INFO') Write-BypassSetupLog $m $l }

Write-BypassSetupLog ("Seed shortcuts: copied={0} skipped={1}" -f $copyStats.Copied, $copyStats.Skipped)

$selectedBases = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($lnkName in @($copyStats.CopiedNames)) {
    if (-not $lnkName) { continue }
    $base = [System.IO.Path]::GetFileNameWithoutExtension($lnkName.ToString())
    if ($base) { [void]$selectedBases.Add($base) }
}

$wrapper = Get-BypassShortcutsConfig -RepoRoot $script:ModuleRoot
$config = $wrapper.Config
$config.parentPath = $folder.ParentPath
$config.bypassesPath = $folder.BypassesPath
$config.adminUser = $AdminUser

$configRef = [ref]$config
$runAs = Ensure-RunAsToolExeResolved `
    -RepoRoot $script:ModuleRoot `
    -ConfigRef $configRef `
    -LogAction { param($m, $l = 'INFO') Write-BypassSetupLog $m $l }
$config = $configRef.Value
Write-BypassSetupLog "RunAsTool ready: $runAs"

if (-not (Test-Path -LiteralPath $RntPath)) {
    throw "RunAsTool seed file not found: $RntPath"
}

$filteredRnt = New-FilteredRunAsToolRnt -RntPath $RntPath -SyncListEntries $syncList -SeedBaseNames $selectedBases
Write-BypassSetupLog ("RunAsTool RNT filtered: included={0} of {1} -> {2}" -f $filteredRnt.IncludedCount, $filteredRnt.TotalCount, $filteredRnt.Path)

$cred = Get-Credential -UserName $AdminUser -Message "RunAsTool import requires the admin password for $AdminUser (one prompt for this setup)"
if (-not $cred) {
    throw "Admin password is required for RunAsTool import. Folder and shortcuts may already be in place at $($folder.BypassesPath); retry this setup to complete import."
}

try {
    Invoke-RunAsToolRntImport `
        -RntPath $filteredRnt.Path `
        -RunAsToolExe $runAs `
        -AdminUser $AdminUser `
        -AdminPassword $cred.Password `
        -ResetList:$resetList `
        -RepoRoot $script:ModuleRoot `
        -LogAction { param($m, $l = 'INFO') Write-BypassSetupLog $m $l }
}
catch {
    Write-BypassSetupLog $_.Exception.Message "ERROR"
    throw
}
finally {
    if ($filteredRnt.Path -and (Test-Path -LiteralPath $filteredRnt.Path)) {
        Remove-Item -LiteralPath $filteredRnt.Path -Force -ErrorAction SilentlyContinue
    }
}

$null = Save-BypassShortcutsConfig -RepoRoot $script:ModuleRoot -Config $config
Write-BypassSetupLog "Saved bypass-shortcuts.json"

Write-BypassSetupLog "=== Setup-PlayniteBypassAutomated complete ==="
Write-Host ""
Write-Host "Automated bypass setup complete." -ForegroundColor Green
Write-Host "  Game Shortcuts: $($folder.BypassesPath)"
Write-Host "  RunAsTool list imported (filtered by sync list): $RntPath"
Write-Host ""
Write-Host "Next step: run '3. Review and Sync' on the Bypass tab to update Playnite launch paths." -ForegroundColor Cyan
