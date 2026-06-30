#Requires -Version 5.1
<#
.SYNOPSIS
    Local test harness for RunAsTool add-program automation (Genshin).
.EXAMPLE
    .\Test-RunAsToolAddGenshin.ps1
#>
[CmdletBinding()]
param(
    [string]$ExePath = "Z:\GenshinImpact\Genshin Impact game\GenshinImpact.exe",
    [string]$RunAsToolExe = "C:\ProgramData\NextGPU\RunAsTool\RunAsTool_x64.exe",
    [string]$DestLnk = "Z:\Game Shortcuts\Genshin Impact.lnk",
    [string]$AdminUser = "NextGPU-Authority",
    [securestring]$AdminPassword
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Playnite-Common.ps1")
. (Join-Path $PSScriptRoot "Invoke-RunAsToolGuiAutomation.ps1")

if (-not $AdminPassword) {
    $cred = Get-Credential -UserName $AdminUser -Message "RunAsTool test password for $AdminUser"
    if (-not $cred) { throw "Password required." }
    $AdminPassword = $cred.Password
}

function Write-TestLog {
    param([string]$Message, [string]$Level = "INFO")
    Write-Host "[TEST][$Level] $Message"
}

if (-not (Test-BypassPathLiteral -Path $ExePath)) {
    throw "Exe not found: $ExePath"
}

$result = Invoke-RunAsToolBypassShortcutAutomation `
    -RunAsToolExe $RunAsToolExe `
    -ExePath $ExePath `
    -DestLnk $DestLnk `
    -AdminUser $AdminUser `
    -AdminPassword $AdminPassword `
    -TileDisplayName "Genshin Impact" `
    -TimeoutSec 120 `
    -LogAction { param($m, $l = 'INFO') Write-TestLog $m $l }

$result | Format-List *
