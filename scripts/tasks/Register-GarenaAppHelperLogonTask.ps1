#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Deprecated wrapper — installs Garena platform service (admin) instead of nextGPU logon task.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ClientDir
)

$installScript = Join-Path (Split-Path $PSScriptRoot -Parent) 'maintenance\Install-GarenaPlatformService.ps1'
if (-not (Test-Path -LiteralPath $installScript)) {
    throw "Install script not found: $installScript"
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installScript -ClientDir $ClientDir
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
