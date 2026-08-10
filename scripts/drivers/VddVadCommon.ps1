# Shared VDD/VAD PnP health, install guards, and removal (Install-VAD-Fallback.ps1,
# Get-VddVadStatus.ps1, silent-install-vdd-vad.ps1, Uninstall-NextGPU.ps1).

$script:VddInstancePatterns = @('DISPLAY\MTT1337*', 'ROOT\MttVDD*')
$script:VddFriendlyRegex = 'Virtual Display|MttVDD|MTT1337|VDD by MTT'
$script:VadPrimaryInstancePatterns = @('ROOT\VirtualAudioDriver*', 'ROOT\MEDIA*')
$script:VadPrimaryFriendlyRegex = 'Virtual Audio Driver'
$script:VbCableFriendlyRegex = 'VB-Audio|CABLE Input|CABLE Output|CABLE In|CABLE Out'
$script:VddVadDriverOriginalNames = @('MttVDD.inf', 'VirtualAudioDriver.inf')
$script:VbCableDriverOriginalPatterns = @('vbaudio_cable*', 'vbcable*', 'vbaudio*')

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

function Write-VddVadLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'SKIP', 'OK')][string]$Level = 'INFO',
        [scriptblock]$LogAction
    )
    if ($LogAction) {
        & $LogAction $Message $Level
    }
}

function Get-VddHealth {
    $devices = @(Get-PnpDevicesFiltered -InstancePatterns $script:VddInstancePatterns `
        -FriendlyNameRegex $script:VddFriendlyRegex)
    $readyDevices = @($devices | Where-Object { Test-PnpRowReady $_ })
    $brokenDevices = @($devices | Where-Object { -not (Test-PnpRowReady $_) })

    $ready = $readyDevices.Count -gt 0
    $summary = 'Not detected'
    $detail = ''

    if ($ready) {
        $summary = 'Detected and ready'
        $detail = $readyDevices[0].FriendlyName
    }
    elseif ($brokenDevices.Count -gt 0) {
        $p = $brokenDevices[0]
        $summary = 'Detected but not ready'
        $detail = "{0} Status={1} Problem={2}" -f $p.FriendlyName, $p.Status, $p.Problem
    }
    elseif ($devices.Count -gt 0) {
        $summary = 'Detected but not ready'
    }

    return [pscustomobject]@{
        Present = ($devices.Count -gt 0)
        Ready   = $ready
        Summary = $summary
        Detail  = $detail
        Devices = $devices
        ReadyDevices = $readyDevices
        BrokenDevices = $brokenDevices
    }
}

function Get-PrimaryVadDevices {
    return @(Get-PnpDevicesFiltered -InstancePatterns $script:VadPrimaryInstancePatterns `
        -FriendlyNameRegex $script:VadPrimaryFriendlyRegex)
}

function Get-VbCableDevices {
    $all = @(Get-PnpDevicesFiltered -InstancePatterns @() `
        -FriendlyNameRegex $script:VbCableFriendlyRegex)
    return @($all | Where-Object {
        $_.InstanceId -notlike 'ROOT\VirtualAudioDriver*' -and
        ($_.FriendlyName -notmatch 'Virtual Audio Driver')
    })
}

function Get-VadHealth {
    $primary = @(Get-PrimaryVadDevices)
    $fallback = @(Get-VbCableDevices)

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
        PrimaryReady  = $primaryReady
        PrimaryBroken = $primaryBroken
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

function Test-PrimaryVadReady {
    $h = Get-VadHealth
    return ($h.PrimaryReady.Count -gt 0)
}

function Test-VddVadInstallNeeded {
    param(
        [switch]$RequireVad,
        [switch]$Force,
        [switch]$SkipIfInstalled
    )

    $vdd = Get-VddHealth
    $vad = Get-VadHealth

    $installVdd = $false
    $installVad = $false
    $skip = $false
    $reason = ''

    if ($Force) {
        $installVdd = $true
        $installVad = $true
        $reason = 'Force refresh requested'
    }
    elseif ($SkipIfInstalled) {
        $primaryVadReady = ($vad.PrimaryReady.Count -gt 0)
        $brokenPrimaryPhantom = ($vad.PrimaryBroken.Count -gt 0)

        if ($vdd.Ready -and ($primaryVadReady -or ((-not $RequireVad) -and -not $brokenPrimaryPhantom))) {
            $skip = $true
            if ($primaryVadReady) {
                $reason = 'VDD and primary VAD already ready'
            }
            elseif (-not $RequireVad) {
                $reason = 'VDD already ready (VAD not required)'
            }
        }
        elseif ($vdd.Ready -and $brokenPrimaryPhantom -and -not $RequireVad) {
            $skip = $true
            $reason = 'VDD ready; primary VAD not usable (use Install-VAD-Fallback.ps1 for VB-CABLE)'
        }
        else {
            if (-not $vdd.Ready) { $installVdd = $true }
            if ($RequireVad -and -not $primaryVadReady) { $installVad = $true }
            if ($brokenPrimaryPhantom -and $RequireVad) {
                if (-not $vdd.Ready) { $installVdd = $true }
                $installVad = $true
                $reason = 'Broken VDD/VAD devices detected; refresh required'
            }
            elseif (-not $vdd.Ready -and -not $primaryVadReady -and $RequireVad) {
                $reason = 'VDD and primary VAD not ready'
            }
            elseif (-not $vdd.Ready) {
                $reason = 'VDD not ready'
            }
            elseif ($RequireVad -and -not $primaryVadReady) {
                $reason = 'Primary VAD not ready'
            }
            else {
                $reason = 'Install required'
            }
        }
    }
    else {
        if (-not $vdd.Ready) { $installVdd = $true }
        if ($RequireVad -and ($vad.PrimaryReady.Count -eq 0)) { $installVad = $true }
        if ($vad.PrimaryBroken.Count -gt 0) {
            $installVdd = $true
            $installVad = $true
        }
        if (-not $installVdd -and -not $installVad) {
            $skip = $true
            $reason = 'Drivers already present'
        }
        else {
            $reason = 'Missing or broken drivers'
        }
    }

    if (-not $Force -and -not $skip) {
        if ($installVdd -and -not $vdd.Ready -and $vdd.Devices.Count -eq 0 -and -not $installVad) {
            $reason = 'Fresh VDD install'
        }
    }

    return [pscustomobject]@{
        Skip       = $skip
        InstallVdd = $installVdd
        InstallVad = $installVad
        Reason     = $reason
        VddHealth  = $vdd
        VadHealth  = $vad
    }
}

function Test-VddVadAbsent {
    param([switch]$IncludeVbCable)

    $vdd = @(Get-PnpDevicesFiltered -InstancePatterns $script:VddInstancePatterns `
        -FriendlyNameRegex $script:VddFriendlyRegex)
    $vad = @(Get-PrimaryVadDevices)
    $vb = if ($IncludeVbCable) { @(Get-VbCableDevices) } else { @() }

    $remaining = @($vdd + $vad + $vb)
    $parts = @()
    if ($vdd.Count -gt 0) { $parts += ("VDD={0}" -f $vdd.Count) }
    if ($vad.Count -gt 0) { $parts += ("VAD={0}" -f $vad.Count) }
    if ($vb.Count -gt 0) { $parts += ("VB-CABLE={0}" -f $vb.Count) }

    return [pscustomobject]@{
        AllClear = ($remaining.Count -eq 0)
        Summary  = if ($parts.Count -gt 0) { ($parts -join ', ') } else { 'None' }
        Vdd      = $vdd
        Vad      = $vad
        VbCable  = $vb
        Remaining = $remaining
    }
}

function Invoke-PnpRescan {
    param([scriptblock]$LogAction)
    Write-VddVadLog -Message 'Scanning for hardware/device changes...' -LogAction $LogAction
    $output = & pnputil.exe /scan-devices 2>&1 | Out-String
    if ($output.Trim()) { Write-VddVadLog -Message $output.Trim() -LogAction $LogAction }
    if ($LASTEXITCODE -ne 0) {
        Write-VddVadLog -Message "pnputil /scan-devices returned $LASTEXITCODE" -Level WARN -LogAction $LogAction
    }
}

function Get-PnpDriverRecords {
    $output = & pnputil.exe /enum-drivers 2>&1
    $records = New-Object System.Collections.Generic.List[object]
    $current = @{}

    foreach ($line in $output) {
        $text = [string]$line
        if ($text -match '^\s*$') { continue }
        if ($text -match '^\s*Published Name\s*:\s*(.+)$') {
            if ($current.Count -gt 0) { $records.Add([pscustomobject]$current) }
            $current = @{ PublishedName = $Matches[1].Trim() }
            continue
        }
        if ($text -match '^\s*Original Name\s*:\s*(.+)$') { $current.OriginalName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Provider Name\s*:\s*(.+)$') { $current.ProviderName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Class Name\s*:\s*(.+)$') { $current.ClassName = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Driver Version\s*:\s*(.+)$') { $current.DriverVersion = $Matches[1].Trim(); continue }
        if ($text -match '^\s*Signer Name\s*:\s*(.+)$') { $current.SignerName = $Matches[1].Trim(); continue }
    }

    if ($current.Count -gt 0) { $records.Add([pscustomobject]$current) }
    return $records.ToArray()
}

function Test-OriginalNameMatchesPattern {
    param(
        [string]$OriginalName,
        [string[]]$Patterns
    )
    foreach ($pattern in $Patterns) {
        if ($OriginalName -like $pattern) { return $true }
    }
    return $false
}

function Remove-PnpDevicesByPattern {
    param(
        [Parameter(Mandatory)][string[]]$InstancePatterns,
        [string]$FriendlyNamePattern = '',
        [Parameter(Mandatory)][string]$Label,
        [scriptblock]$LogAction
    )

    $devices = @(Get-PnpDevicesFiltered -InstancePatterns $InstancePatterns -FriendlyNameRegex $FriendlyNamePattern)
    if ($devices.Count -eq 0) {
        Write-VddVadLog -Message "No existing $Label devices found." -Level SKIP -LogAction $LogAction
        return
    }

    foreach ($device in $devices) {
        Write-VddVadLog -Message "Removing $Label device: $($device.InstanceId) [$($device.Status) / $($device.Problem)]" -LogAction $LogAction
        $output = & pnputil.exe /remove-device "$($device.InstanceId)" 2>&1 | Out-String
        if ($output.Trim()) { Write-VddVadLog -Message $output.Trim() -LogAction $LogAction }
        if ($LASTEXITCODE -ne 0) {
            Write-VddVadLog -Message "pnputil /remove-device returned $LASTEXITCODE for $($device.InstanceId)" -Level WARN -LogAction $LogAction
        }
    }
}

function Remove-DriverPackagesByOriginalName {
    param(
        [Parameter(Mandatory)][string[]]$OriginalNames,
        [Parameter(Mandatory)][string]$Label,
        [scriptblock]$LogAction
    )
    try {
        $drivers = @(Get-PnpDriverRecords | Where-Object {
            $original = if ($_.PSObject.Properties.Name -contains 'OriginalName') { $_.OriginalName } else { '' }
            $OriginalNames -contains $original
        })
    }
    catch {
        Write-VddVadLog -Message "Failed to enumerate driver packages for $Label : $($_.Exception.Message)" -Level WARN -LogAction $LogAction
        return
    }

    if ($drivers.Count -eq 0) {
        Write-VddVadLog -Message "No existing $Label driver packages found." -Level SKIP -LogAction $LogAction
        return
    }

    foreach ($driver in $drivers) {
        Write-VddVadLog -Message "Deleting $Label driver package: $($driver.PublishedName) ($($driver.OriginalName))" -LogAction $LogAction
        $output = & pnputil.exe /delete-driver $driver.PublishedName /uninstall /force 2>&1 | Out-String
        if ($output.Trim()) { Write-VddVadLog -Message $output.Trim() -LogAction $LogAction }
        if ($LASTEXITCODE -ne 0) {
            Write-VddVadLog -Message "pnputil /delete-driver returned $LASTEXITCODE for $($driver.PublishedName)" -Level WARN -LogAction $LogAction
        }
    }
}

function Remove-DriverPackagesByProvider {
    param(
        [Parameter(Mandatory)][string]$ProviderName,
        [string[]]$OriginalNamePatterns = @(),
        [Parameter(Mandatory)][string]$Label,
        [scriptblock]$LogAction
    )
    try {
        $drivers = @(Get-PnpDriverRecords | Where-Object {
            $provider = if ($_.PSObject.Properties.Name -contains 'ProviderName') { $_.ProviderName } else { '' }
            $original = if ($_.PSObject.Properties.Name -contains 'OriginalName') { $_.OriginalName } else { '' }
            if ($provider -ne $ProviderName) { return $false }
            if ($OriginalNamePatterns.Count -eq 0) { return $true }
            return (Test-OriginalNameMatchesPattern -OriginalName $original -Patterns $OriginalNamePatterns)
        })
    }
    catch {
        Write-VddVadLog -Message "Failed to enumerate driver packages for $Label : $($_.Exception.Message)" -Level WARN -LogAction $LogAction
        return
    }

    if ($drivers.Count -eq 0) {
        Write-VddVadLog -Message "No existing $Label driver packages found." -Level SKIP -LogAction $LogAction
        return
    }

    foreach ($driver in $drivers) {
        Write-VddVadLog -Message "Deleting $Label driver package: $($driver.PublishedName) ($($driver.OriginalName))" -LogAction $LogAction
        $output = & pnputil.exe /delete-driver $driver.PublishedName /uninstall /force 2>&1 | Out-String
        if ($output.Trim()) { Write-VddVadLog -Message $output.Trim() -LogAction $LogAction }
        if ($LASTEXITCODE -ne 0) {
            Write-VddVadLog -Message "pnputil /delete-driver returned $LASTEXITCODE for $($driver.PublishedName)" -Level WARN -LogAction $LogAction
        }
    }
}

function Invoke-VbCableVendorUninstall {
    param([scriptblock]$LogAction)

    $installRoot = Join-Path $env:ProgramData 'nextGPU\VBCABLE-Install\extracted'
    if (Test-Path -LiteralPath $installRoot) {
        $setup = Get-ChildItem -LiteralPath $installRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq 'VBCABLE_Setup_x64.exe' -or $_.Name -ieq 'VBCABLE_Setup.exe' } |
            Sort-Object { if ($_.Name -ieq 'VBCABLE_Setup_x64.exe') { 0 } else { 1 } } |
            Select-Object -First 1
        if ($setup) {
            Write-VddVadLog -Message "Running VB-CABLE vendor uninstall: $($setup.FullName) -u" -LogAction $LogAction
            $proc = Start-Process -FilePath $setup.FullName -ArgumentList @('-u') -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
            if ($proc -and $proc.ExitCode -ne 0) {
                Write-VddVadLog -Message "VB-CABLE setup -u exit code: $($proc.ExitCode)" -Level WARN -LogAction $LogAction
            }
        }
    }

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        foreach ($id in @('VBurel.VB-CABLE', 'VB-Audio.VB-CABLE', 'VBAudio.VBCABLE')) {
            Write-VddVadLog -Message "Trying winget uninstall: $id" -LogAction $LogAction
            & winget uninstall --id $id --exact --silent --accept-source-agreements 2>&1 | Out-Null
        }
    }
}

function Remove-VddVadStack {
    param(
        [switch]$RemoveVdd,
        [switch]$RemoveVad,
        [switch]$IncludeVbCable,
        [switch]$RemoveVddSettings,
        [scriptblock]$LogAction
    )

    $removeAll = (-not $RemoveVdd.IsPresent) -and (-not $RemoveVad.IsPresent) -and (-not $IncludeVbCable.IsPresent)
    if ($removeAll) {
        $RemoveVdd = $true
        $RemoveVad = $true
    }

    if ($RemoveVdd) {
        Write-VddVadLog -Message 'Removing VDD devices...' -LogAction $LogAction
        Remove-PnpDevicesByPattern -InstancePatterns $script:VddInstancePatterns `
            -FriendlyNamePattern $script:VddFriendlyRegex -Label 'VDD' -LogAction $LogAction
    }

    if ($RemoveVad) {
        Write-VddVadLog -Message 'Removing primary VAD devices...' -LogAction $LogAction
        Remove-PnpDevicesByPattern -InstancePatterns $script:VadPrimaryInstancePatterns `
            -FriendlyNamePattern $script:VadPrimaryFriendlyRegex -Label 'VAD' -LogAction $LogAction
    }

    if ($IncludeVbCable) {
        Write-VddVadLog -Message 'Removing VB-CABLE devices...' -LogAction $LogAction
        Remove-PnpDevicesByPattern -InstancePatterns @() `
            -FriendlyNamePattern $script:VbCableFriendlyRegex -Label 'VB-CABLE' -LogAction $LogAction
        Invoke-VbCableVendorUninstall -LogAction $LogAction
    }

    Invoke-PnpRescan -LogAction $LogAction

    if ($RemoveVdd -or $RemoveVad) {
        Remove-DriverPackagesByOriginalName -OriginalNames $script:VddVadDriverOriginalNames `
            -Label 'VDD/VAD' -LogAction $LogAction
    }

    if ($IncludeVbCable) {
        Remove-DriverPackagesByProvider -ProviderName 'VB-Audio Software' `
            -OriginalNamePatterns $script:VbCableDriverOriginalPatterns -Label 'VB-CABLE' -LogAction $LogAction
        $vbInstallRoot = Join-Path $env:ProgramData 'nextGPU\VBCABLE-Install'
        if (Test-Path -LiteralPath $vbInstallRoot) {
            Write-VddVadLog -Message "Removing VB-CABLE install folder: $vbInstallRoot" -LogAction $LogAction
            Remove-Item -LiteralPath $vbInstallRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if ($RemoveVddSettings) {
        $settingsDir = 'C:\VirtualDisplayDriver'
        if (Test-Path -LiteralPath $settingsDir) {
            Write-VddVadLog -Message "Removing VDD settings folder: $settingsDir" -LogAction $LogAction
            Remove-Item -LiteralPath $settingsDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
