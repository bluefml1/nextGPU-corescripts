#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

function Get-DeviceStatus([string[]]$Patterns, [string]$FriendlyRegex = "") {
    $items = @()
    try {
        $items = @(Get-PnpDevice -ErrorAction Stop | Where-Object {
            $match = $false
            foreach ($p in $Patterns) {
                if ($_.InstanceId -like $p) { $match = $true; break }
            }
            if (-not $match -and $FriendlyRegex -and $_.FriendlyName) {
                $match = $_.FriendlyName -match $FriendlyRegex
            }
            $match
        })
    } catch {
        $items = @()
    }

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
        $isReady = $d.Status -eq "OK" -and ($problem -eq "" -or $problem -eq "CM_PROB_NONE")
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
$vad = Get-DeviceStatus -Patterns @("ROOT\VirtualAudioDriver*", "ROOT\MEDIA*") -FriendlyRegex "Virtual Audio|VAD|VB-Audio|CABLE"

Write-Host "===== VDD/VAD STATUS =====" -ForegroundColor Cyan
Write-Host ("VDD: {0}" -f $vdd.Summary) -ForegroundColor (if ($vdd.Ready) { "Green" } else { "Yellow" })
Write-Host ("VAD: {0}" -f $vad.Summary) -ForegroundColor (if ($vad.Ready) { "Green" } else { "Yellow" })
Write-Host ""

if ($vdd.Items.Count -gt 0) {
    Write-Host "VDD devices:" -ForegroundColor Cyan
    $vdd.Items | Format-Table FriendlyName, Status, Problem, InstanceId -AutoSize | Out-String | Write-Host
}
if ($vad.Items.Count -gt 0) {
    Write-Host "VAD devices:" -ForegroundColor Cyan
    $vad.Items | Format-Table FriendlyName, Status, Problem, InstanceId -AutoSize | Out-String | Write-Host
}

if (-not $vad.Ready) {
    Write-Host "[RECOMMEND] VAD is not ready. Run fallback installer:" -ForegroundColor Yellow
    Write-Host "  scripts\drivers\Install-VAD-Fallback.ps1" -ForegroundColor Yellow
}

