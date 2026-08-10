#Requires -Version 5.1
<#
.SYNOPSIS
    Install or repair the NextGPU SteamLibrary_NextGPU extension from repo build output.
.EXAMPLE
    .\Install-SteamExtensions.ps1
    .\Install-SteamExtensions.ps1 -PlayniteInstallDir Z:\Playnite
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "Playnite-Common.ps1")

$installDir = Resolve-PlayniteInstallPathFromConfig -RepoRoot $PSScriptRoot -OverrideDir $PlayniteInstallDir
$installDir = Resolve-PlayniteInstallDir -PreferredDir $installDir
if (-not $installDir) {
    throw "Playnite install folder is not set. Run Setup-PlayniteSteam.bat or pass -PlayniteInstallDir."
}

$logAction = {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
}

Install-NextGpuSteamExtensions -InstallDir $installDir -RepoRoot $PSScriptRoot -LogAction $logAction
Write-Host "Install-SteamExtensions: done ($installDir)"
