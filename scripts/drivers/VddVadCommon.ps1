# Shared VDD/VAD PnP health checks (Install-VAD-Fallback.ps1, Get-VddVadStatus.ps1).

function Test-PnpRowReady {
    param($Device)
    $problem = if ($null -ne $Device.Problem) { [string]$Device.Problem } else { '' }
    return ($Device.Status -eq 'OK' -and ($problem -eq '' -or $problem -eq 'CM_PROB_NONE'))
}

function Get-PnpDevicesFiltered {
    param(
        [string[]]$InstancePatterns = @(),
        [string]$FriendlyNameRegex = ''
    )
    try {
        return @(Get-PnpDevice -ErrorAction Stop | Where-Object {
            $match = $false
            foreach ($pattern in $InstancePatterns) {
                if ($_.InstanceId -like $pattern) { $match = $true; break }
            }
            if (-not $match -and $FriendlyNameRegex -and $_.FriendlyName) {
                $match = ($_.FriendlyName -match $FriendlyNameRegex)
            }
            $match
        })
    }
    catch {
        return @()
    }
}

function Get-VadHealth {
    # Primary = VirtualDrivers VAD (may be Code 52 / unsigned on Win11 24H2+).
    $primary = @(Get-PnpDevicesFiltered -InstancePatterns @('ROOT\VirtualAudioDriver*') `
        -FriendlyNameRegex 'Virtual Audio Driver')
    # Signed fallback drivers (VB-CABLE etc.).
    $fallback = @(Get-PnpDevicesFiltered -InstancePatterns @() `
        -FriendlyNameRegex 'VB-Audio|CABLE Input|CABLE Output|CABLE In|CABLE Out')
    $fallback = @($fallback | Where-Object {
        $_.InstanceId -notlike 'ROOT\VirtualAudioDriver*' -and
        ($_.FriendlyName -notmatch 'Virtual Audio Driver')
    })

    $primaryReady = @($primary | Where-Object { Test-PnpRowReady $_ })
    $fallbackReady = @($fallback | Where-Object { Test-PnpRowReady $_ })
    $primaryBroken = @($primary | Where-Object { -not (Test-PnpRowReady $_) })

    $ready = $false
    $needsFallback = $false
    $summary = 'Not detected'
    $detail = ''

    if ($primaryReady.Count -gt 0) {
        $ready = $true
        $summary = 'Primary VAD ready'
        $detail = $primaryReady[0].FriendlyName
    }
    elseif ($primaryBroken.Count -gt 0) {
        $needsFallback = $true
        $p = $primaryBroken[0]
        $summary = 'Primary VAD present but not usable'
        $detail = "{0} Status={1} Problem={2}" -f $p.FriendlyName, $p.Status, $p.Problem
        if ([string]$p.Problem -match 'UNSIGNED') {
            $detail += ' (Code 52 - use VB-CABLE fallback or Virtual Driver Control)'
        }
    }
    elseif ($fallbackReady.Count -gt 0) {
        $ready = $true
        $summary = 'Fallback audio ready (VB-CABLE)'
        $detail = $fallbackReady[0].FriendlyName
    }
    else {
        $needsFallback = $true
        if ($fallback.Count -gt 0) {
            $summary = 'Fallback audio detected but not ready'
        }
        else {
            $summary = 'No usable VAD detected'
        }
    }

    return [pscustomobject]@{
        Ready         = $ready
        NeedsFallback = $needsFallback
        Summary       = $summary
        Detail        = $detail
        Primary       = $primary
        Fallback      = $fallback
    }
}

function Test-VadUsable {
    return (Get-VadHealth).Ready
}

function Test-VadNeedsFallback {
    param([switch]$IncludeMissing)
    $h = Get-VadHealth
    if ($h.NeedsFallback) { return $true }
    if ($IncludeMissing -and -not $h.Ready) { return $true }
    return $false
}
