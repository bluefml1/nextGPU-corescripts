#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot 'VddVadCommon.ps1')

function Get-DeviceStatus([string[]]$Patterns, [string]$FriendlyRegex = "") {
    $items = @(Get-PnpDevicesFiltered -InstancePatterns $Patterns -FriendlyNameRegex $FriendlyRegex)

    if ($items.Count -eq 0) {
        return [pscustomobject]@{
            Present = $false
            Ready = $false
            Summary = "Not detected"
            Items = @()
        }
    }

    $ready = $false
    $rows = @()
    foreach ($d in $items) {
        $problem = if ($null -ne $d.Problem) { [string]$d.Problem } else { "" }
        $isReady = Test-PnpRowReady $d
        if ($isReady) { $ready = $true }
        $rows += [pscustomobject]@{
            InstanceId = $d.InstanceId
            FriendlyName = $d.FriendlyName
            Status = $d.Status
            Problem = $problem
        }
    }

    return [pscustomobject]@{
        Present = $true
        Ready = $ready
        Summary = if ($ready) { "Detected and ready" } else { "Detected but not ready" }
        Items = $rows
    }
}

$vdd = Get-DeviceStatus -Patterns @("DISPLAY\MTT1337*", "ROOT\MttVDD*") -FriendlyRegex "VDD|Virtual Display|MttVDD"
$vadHealth = Get-VadHealth

Write-Host "===== VDD/VAD STATUS =====" -ForegroundColor Cyan
Write-Host ("VDD: {0}" -f $vdd.Summary) -ForegroundColor $(if ($vdd.Ready) { "Green" } else { "Yellow" })
Write-Host ("VAD: {0}" -f $vadHealth.Summary) -ForegroundColor $(if ($vadHealth.Ready) { "Green" } else { "Yellow" })
if ($vadHealth.Detail) {
    Write-Host ("  {0}" -f $vadHealth.Detail) -ForegroundColor DarkGray
}
Write-Host ""

if ($vdd.Items.Count -gt 0) {
    Write-Host "VDD devices:" -ForegroundColor Cyan
    $vdd.Items | Format-Table FriendlyName, Status, Problem, InstanceId -AutoSize | Out-String | Write-Host
}
if ($vadHealth.Primary.Count -gt 0) {
    Write-Host "VAD (primary Virtual Audio Driver):" -ForegroundColor Cyan
    $vadHealth.Primary | ForEach-Object {
        [pscustomobject]@{ FriendlyName = $_.FriendlyName; Status = $_.Status; Problem = $_.Problem; InstanceId = $_.InstanceId }
    } | Format-Table -AutoSize | Out-String | Write-Host
}
if ($vadHealth.Fallback.Count -gt 0) {
    Write-Host "VAD (fallback / VB-CABLE):" -ForegroundColor Cyan
    $vadHealth.Fallback | ForEach-Object {
        [pscustomobject]@{ FriendlyName = $_.FriendlyName; Status = $_.Status; Problem = $_.Problem; InstanceId = $_.InstanceId }
    } | Format-Table -AutoSize | Out-String | Write-Host
}

if ($vadHealth.NeedsFallback) {
    Write-Host "[RECOMMEND] VAD is not usable. Run fallback installer:" -ForegroundColor Yellow
    Write-Host "  scripts\drivers\Install-VAD-Fallback.ps1" -ForegroundColor Yellow
    if ($vadHealth.Primary.Count -gt 0) {
        Write-Host '  (Primary VAD may show Code 52 / CM_PROB_UNSIGNED_DRIVER - VB-CABLE is the signed workaround.)' -ForegroundColor Yellow
    }
}
