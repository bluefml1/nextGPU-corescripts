#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Set sunshine.conf display defaults: dd_configuration_option = ensure_only_display, dd_config_revert_on_disconnect = enabled.
.DESCRIPTION
    Does not write output_name — set it manually in Sunshine or sunshine.conf if you need a fixed VDD head.
    -DeviceId is accepted for backward-compatible invocation (e.g. Get-VddOutputName.ps1 -SetSunshineConf) but is not persisted.
.EXAMPLE
    .\Set-SunshineOutputName.ps1
.EXAMPLE
    .\Set-SunshineOutputName.ps1 -DeviceId '{bfb911d1-c758-53cb-a9a2-a52a39313b78}'
#>
[CmdletBinding()]
param(
    [string]$DeviceId = '',
    [string]$ConfigPath = 'C:\Program Files\Sunshine\config\sunshine.conf'
)

$ErrorActionPreference = 'Stop'
if ($DeviceId) {
    $DeviceId = $DeviceId.Trim()
    if ($DeviceId -notmatch '^\{[0-9a-fA-F-]{36}\}$') {
        throw "DeviceId must be a UUID like {xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx} or omit -DeviceId"
    }
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "sunshine.conf not found: $ConfigPath"
}

function Set-Line([string]$Content, [string]$Name, [string]$Value) {
    if ($Content -match ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=')) {
        return ($Content -replace ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=.*'), ($Name + ' = ' + $Value))
    }
    return ($Content.TrimEnd() + "`r`n" + $Name + ' = ' + $Value + "`r`n")
}

$c = Get-Content -Raw -LiteralPath $ConfigPath
$c = Set-Line $c 'dd_configuration_option' 'ensure_only_display'
$c = Set-Line $c 'dd_config_revert_on_disconnect' 'enabled'
[System.IO.File]::WriteAllText($ConfigPath, $c, [Text.UTF8Encoding]::new($false))
Write-Host '[OK] dd_configuration_option = ensure_only_display, dd_config_revert_on_disconnect = enabled (output_name not modified)'
if ($DeviceId) {
    Write-Host "[INFO] -DeviceId not written to config; set output_name manually if needed: $DeviceId"
}

$restart = Join-Path $PSScriptRoot 'Invoke-SunshineApiRestart.ps1'
if (Test-Path -LiteralPath $restart) {
    & $restart
}
