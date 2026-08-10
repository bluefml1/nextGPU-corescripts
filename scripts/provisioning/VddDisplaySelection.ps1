#Requires -Version 5.1
# Shared VDD display selection (Get-SunshineDeviceIdFromLog.ps1, Set-SunshineVddOutput.ps1).
param([switch]$TestSamples)

function Test-IsVddSunshineDisplay {
    param($Display)
    if (-not $Display) { return $false }

    $fn = [string]$Display.friendly_name
    if ($fn -match 'VDD by MTT') { return $true }

    $edid = $Display.edid
    if ($edid) {
        $mfg = [string]$edid.manufacturer_id
        $pc = $edid.product_code
        $pcStr = if ($null -eq $pc) { '' } else { [string]$pc }
        if ($mfg -eq 'MTT' -and ($pcStr -eq '1337' -or $pcStr -eq '0x1337' -or $pc -eq 1337)) {
            return $true
        }
    }
    return $false
}

function Test-IsUsableVddSunshineLogEntry {
    param($Display)
    if (-not $Display) { return $false }

    $dn = [string]$Display.display_name
    if ($dn -match '^\\\\\.\\DISPLAY\d+$') { return $true }

    if ($Display.info) {
        if ($Display.info.primary -eq $true) { return $true }
        if ($Display.info.resolution) { return $true }
    }
    return $false
}

function Get-VddSunshineLogEntryScore {
    param($Display)
    if (-not $Display) { return 0 }

    $score = 0
    $dn = [string]$Display.display_name
    if ($dn -match '^\\\\\.\\DISPLAY\d+$') { $score += 100 }
    elseif (-not [string]::IsNullOrWhiteSpace($dn)) { $score += 50 }

    if ($Display.info) {
        if ($Display.info.primary -eq $true) { $score += 80 }
        if ($Display.info.resolution) { $score += 40 }
        if ($Display.info.refresh_rate) { $score += 10 }
    }

    $fn = [string]$Display.friendly_name
    if ($fn -match 'VDD by MTT') { $score += 20 }

    $edid = $Display.edid
    if ($edid) {
        $mfg = [string]$edid.manufacturer_id
        $pc = $edid.product_code
        $pcStr = if ($null -eq $pc) { '' } else { [string]$pc }
        if ($mfg -eq 'MTT' -and ($pcStr -eq '1337' -or $pcStr -eq '0x1337' -or $pc -eq 1337)) {
            $score += 15
        }
    }
    return $score
}

function Get-VddSunshineLogEntrySummary {
    param($Display)
    if (-not $Display) {
        return [pscustomobject]@{
            DisplayName = ''
            Primary     = $false
            Usable      = $false
            Score       = 0
        }
    }
    $primary = $false
    if ($Display.info -and $Display.info.primary -eq $true) { $primary = $true }
    return [pscustomobject]@{
        DisplayName = [string]$Display.display_name
        Primary     = $primary
        Usable      = (Test-IsUsableVddSunshineLogEntry -Display $Display)
        Score       = (Get-VddSunshineLogEntryScore -Display $Display)
    }
}

function Select-BestVddSunshineLogEntry {
    param([array]$Entries)

    if (-not $Entries -or $Entries.Count -eq 0) { return $null }

    $scored = @(
        foreach ($e in $Entries) {
            $summary = Get-VddSunshineLogEntrySummary -Display $e.Display
            [pscustomobject]@{
                Entry       = $e
                DeviceId    = [string]$e.DeviceId
                Index       = [int]$e.Index
                Usable      = $summary.Usable
                Score       = $summary.Score
                DisplayName = $summary.DisplayName
                Primary     = $summary.Primary
            }
        }
    )

    $usable = @($scored | Where-Object { $_.Usable })
    if ($usable.Count -eq 0) { return $null }

    $best = $usable | Sort-Object `
        @{ Expression = 'Score'; Descending = $true }, `
        @{ Expression = 'Index'; Descending = $true } `
        | Select-Object -First 1

    return [pscustomobject]@{
        DeviceId    = $best.DeviceId
        Entry       = $best.Entry
        Score       = $best.Score
        DisplayName = $best.DisplayName
        Primary     = $best.Primary
        Index       = $best.Index
    }
}

function Test-VddDisplaySelectionSamples {
    $completeJson = @'
{
  "device_id": "{f8eb32ab-e556-5015-b383-2f2dbbcc08b3}",
  "display_name": "\\\\.\\DISPLAY8",
  "edid": {
    "manufacturer_id": "MTT",
    "product_code": "1337",
    "serial_number": 518463207
  },
  "friendly_name": "VDD by MTT",
  "info": {
    "hdr_state": "Disabled",
    "origin_point": { "x": 0, "y": 0 },
    "primary": true,
    "refresh_rate": { "type": "rational", "value": { "denominator": 1, "numerator": 120 } },
    "resolution": { "height": 1440, "width": 2560 },
    "resolution_scale": { "type": "rational", "value": { "denominator": 100, "numerator": 125 } }
  }
}
'@

    $incompleteJsons = @(
        '{"device_id":"{2875b41d-d5e2-5492-bf7b-f1a3a5ed27a4}","display_name":"","edid":null,"friendly_name":"","info":null}',
        '{"device_id":"{5eb52002-659f-5729-bdd8-9cdc4efd1bf5}","display_name":"","edid":{"manufacturer_id":"MTT","product_code":"1337","serial_number":518463207},"friendly_name":"VDD by MTT","info":null}',
        '{"device_id":"{9acddf6d-43cc-576e-9aff-0c5fc80b4cc8}","display_name":"","edid":{"manufacturer_id":"MTT","product_code":"1337","serial_number":518463207},"friendly_name":"VDD by MTT","info":null}'
    )

    $complete = $completeJson | ConvertFrom-Json
    $entries = [System.Collections.Generic.List[object]]::new()
    $idx = 0
    foreach ($j in $incompleteJsons) {
        $obj = $j | ConvertFrom-Json
        $entries.Add([pscustomobject]@{
            Display  = $obj
            Index    = $idx
            DeviceId = [string]$obj.device_id
            IsVdd    = (Test-IsVddSunshineDisplay -Display $obj)
        })
        $idx += 100
    }
    $entries.Add([pscustomobject]@{
        Display  = $complete
        Index    = 50
        DeviceId = [string]$complete.device_id
        IsVdd    = (Test-IsVddSunshineDisplay -Display $complete)
    })

    $pick = Select-BestVddSunshineLogEntry -Entries @($entries)
    if (-not $pick) {
        Write-Error 'Sample test failed: expected complete VDD to be selected.'
        return $false
    }
    if ($pick.DeviceId -ne '{f8eb32ab-e556-5015-b383-2f2dbbcc08b3}') {
        Write-Error "Sample test failed: wrong device_id selected ($($pick.DeviceId))."
        return $false
    }

    $incompleteOnly = @(
        foreach ($j in $incompleteJsons) {
            $obj = $j | ConvertFrom-Json
            [pscustomobject]@{
                Display  = $obj
                Index    = 0
                DeviceId = [string]$obj.device_id
                IsVdd    = $true
            }
        }
    )
    $none = Select-BestVddSunshineLogEntry -Entries $incompleteOnly
    if ($null -ne $none) {
        Write-Error 'Sample test failed: incomplete-only set should return null.'
        return $false
    }

    Write-Host '[OK] VddDisplaySelection sample tests passed.'
    return $true
}

if ($TestSamples) {
    $ok = Test-VddDisplaySelectionSamples
    if (-not $ok) { exit 1 }
    exit 0
}
