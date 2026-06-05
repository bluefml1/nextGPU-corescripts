#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Explain VDD PnP status vs Sunshine output_name and print the VDD device_id when Windows exposes a display path.
#>
[CmdletBinding()]
param(
    [switch]$TryEnable,
    [switch]$SetSunshineConf
)

$ErrorActionPreference = 'Continue'
$displayScript = Join-Path $PSScriptRoot 'Get-DisplayDeviceId.ps1'
$setScript = Join-Path $PSScriptRoot 'Set-SunshineOutputName.ps1'

Write-Host '========================================'
Write-Host ' VDD vs Sunshine output_name'
Write-Host '========================================'
Write-Host ''
Write-Host 'Device Manager "VDD installed" = driver is present (PnP).'
Write-Host 'output_name needs an active MONITOR PATH in Windows (what Sunshine captures).'
Write-Host 'Until Settings > Display shows a second monitor, Sunshine may only list DISPLAY1 (RDP).'
Write-Host ''

Write-Host '--- PnP displays (Device Manager view) ---'
$pnp = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Sort-Object InstanceId)
if ($pnp.Count -eq 0) {
    Write-Host '  No Display class PnP devices found.'
} else {
    foreach ($p in $pnp) {
        $tag = if ($p.InstanceId -like '*MTT1337*' -or $p.InstanceId -like '*MttVDD*') { ' <-- VDD' } else { '' }
        $prob = if ($null -ne $p.Problem) { $p.Problem } else { '' }
        Write-Host ("  [{0}] {1}  Problem={2}{3}" -f $p.Status, $p.InstanceId, $prob, $tag)
    }
}

$vdd = @($pnp | Where-Object { $_.InstanceId -like '*MTT1337*' -or $_.InstanceId -like '*MttVDD*' })
if ($vdd.Count -eq 0) {
    Write-Host ''
    Write-Host '[!] No DISPLAY\MTT1337* PnP node. Re-run scripts\drivers\InstallVDD-VAD.bat and reboot.'
}

$notOk = @($vdd | Where-Object { $_.Status -ne 'OK' })
if ($notOk.Count -gt 0 -and $TryEnable) {
    Write-Host ''
    Write-Host '--- Trying pnputil /enable-device on VDD ---'
    foreach ($p in $notOk) {
        $out = pnputil.exe /enable-device $p.InstanceId 2>&1 | Out-String
        Write-Host "  $($p.InstanceId): $($out.Trim())"
    }
    pnputil.exe /scan-devices 2>&1 | Out-Null
    Start-Sleep -Seconds 3
}

Write-Host ''
Write-Host '--- Display paths (Sunshine / Get-DisplayDeviceId) ---'
if (-not (Test-Path -LiteralPath $displayScript)) {
    Write-Host "[!] Missing: $displayScript"
    exit 1
}

$lines = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $displayScript -ListAll -IncludeInactive 2>&1
$lines | ForEach-Object { Write-Host $_ }

$allText = $lines | Out-String
$vddPath = $null
if ($allText -match '(?s)\[(active|inactive)\]\s+(\{[0-9a-fA-F-]{36}\}).*?instance:\s+(DISPLAY\\MTT1337[^\r\n]+)') {
    $vddPath = @{ DeviceId = $Matches[2]; InstanceId = $Matches[3].Trim(); Active = $Matches[1] }
}

if ($vddPath) {
    Write-Host ''
    Write-Host '========================================' 
    Write-Host ' VDD output_name (use in sunshine.conf):'
    Write-Host " $($vddPath.DeviceId)"
    Write-Host '========================================'
    if ($SetSunshineConf -and (Test-Path -LiteralPath $setScript)) {
        & $setScript -DeviceId $vddPath.DeviceId
    }
    exit 0
}

Write-Host ''
Write-Host '[!] VDD driver is in PnP but no MTT1337 display PATH for Sunshine yet.'
Write-Host ''
Write-Host 'Fix (in order):'
Write-Host '  1. Reboot after VDD install.'
Write-Host '  2. Device Manager > Monitors: enable MTT1337 if Disabled/Disconnected.'
Write-Host '  3. Open Virtual Driver Control (from VDD-VAD-Install folder) and add/enable a virtual display.'
Write-Host '  4. Settings > System > Display > Detect — you must see TWO monitors.'
Write-Host '  5. Restart Sunshine (Start-Sunshine.bat), open its log — two JSON devices; pick the one that is NOT your RDP primary.'
Write-Host '  6. Re-run: powershell -File Get-DisplayDeviceId.ps1 -ListAll -IncludeInactive'
Write-Host ''
exit 1
