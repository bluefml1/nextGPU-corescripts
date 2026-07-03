param(
    [string]$Username = 'nextGPU',
    # String (not [bool]) so "-File" callers can pass: true/false/1/0
    [string]$SunshinePrep = 'true',
    # When Moonlight starts the script it passes the same domain.txt path it already loaded.
    [string]$DomainTxtPath = ''
)

# Sunshine prep DO: compare API start_time, verify nextGPU user, recreate user if verify fails.
# Does not call endSession.ps1 — recreate logic is in nextGpuSessionCommon.ps1.
#
# Invoke with named args, e.g.:
#   -Username nextGPU -SunshinePrep 0 -DomainTxtPath "C:\path\domain.txt"

function Test-SunshinePrepLenient {
    param([string]$Value)

    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in @('true', '1', 'yes') } { return $true }
        default { return $false }
    }
}

if ($Username -match '^(?i:true|false)$') {
    if ($Username -ieq 'false') {
        $SunshinePrep = 'false'
    }
    $Username = 'nextGPU'
}

$SunshinePrepLenient = Test-SunshinePrepLenient -Value $SunshinePrep

$script:GetMachineInfoApiBase = 'https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/getMachineInfor'
$script:StateFileName = 'StartSession-last-start-time.txt'

# ── Log setup ─────────────────────────────────────────────────
$logDir = $PSScriptRoot
if ($SunshinePrepLenient -and -not (Test-Path -LiteralPath $logDir -PathType Container)) {
    $logDir = Join-Path $env:TEMP 'nextGPU-startSession'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
}

$script:LogPath = Join-Path $logDir "StartSession_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:StateFilePath = Join-Path $logDir $script:StateFileName
$script:LogFallbackTag = 'StartSession'

$commonPath = Join-Path $PSScriptRoot 'nextGpuSessionCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    Write-Error "Missing shared helpers: $commonPath"
    exit 1
}
. $commonPath

function Get-StartSessionDomainTxtPath {
    if (-not [string]::IsNullOrWhiteSpace($DomainTxtPath)) {
        $explicit = $DomainTxtPath.Trim().Trim([char]0xFEFF, [char]0x200B)
        if (Test-Path -LiteralPath $explicit) {
            return $explicit
        }
        Write-Log "DomainTxtPath not found: $explicit" -Level WARN
    }

    if ($PSScriptRoot) {
        $cwdRelative = Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'domain.txt'
        if (Test-Path -LiteralPath $cwdRelative) {
            return $cwdRelative
        }
    }

    $programDataCopy = Join-Path $env:ProgramData 'nextGPU\domain.txt'
    if (Test-Path -LiteralPath $programDataCopy) {
        return $programDataCopy
    }

    $markerPath = Join-Path $env:ProgramData 'nextGPU\repo-root.txt'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marked = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            $domainPath = Join-Path $marked 'domain.txt'
            if ($marked -and (Test-Path -LiteralPath $domainPath)) {
                return $domainPath
            }
        }
        catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $envRoot = $env:NEXTGPU_REPO_ROOT.Trim().TrimEnd('\')
        $domainPath = Join-Path $envRoot 'domain.txt'
        if (Test-Path -LiteralPath $domainPath) {
            return $domainPath
        }
    }

    return $null
}

function Read-DomainTxtValues {
    param([string]$Path)

    $values = @{
        Domain       = ''
        PublicIp     = ''
        ComputerName = ''
    }

    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if ($line -match '^\s*DOMAIN\s*=\s*(.+)\s*$') {
            $values.Domain = $matches[1].Trim().Trim([char]0xFEFF, [char]0x200B)
        }
        elseif ($line -match '^\s*PUBLIC_IP\s*=\s*(.+)\s*$') {
            $values.PublicIp = $matches[1].Trim().Trim([char]0xFEFF, [char]0x200B)
        }
        elseif ($line -match '^\s*COMPUTER_NAME\s*=\s*(.+)\s*$') {
            $values.ComputerName = $matches[1].Trim().Trim([char]0xFEFF, [char]0x200B)
        }
    }

    return $values
}

function Get-StartTimeFromApiData {
    param($Data)

    if ($null -eq $Data) { return $null }
    if ($Data.PSObject.Properties['start_time']) {
        $value = [string]$Data.start_time
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    return $null
}

function Get-MachineStartTimeFromApi {
    param(
        [string]$PublicIp,
        [string]$ComputerName
    )

    $query = @{
        publicIP      = $PublicIp
        computer_name = $ComputerName
    }
    $queryString = ($query.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f [uri]::EscapeDataString($_.Key), [uri]::EscapeDataString([string]$_.Value)
    }) -join '&'
    $uri = '{0}?{1}' -f $script:GetMachineInfoApiBase, $queryString

    Write-Log "Calling getMachineInfor: publicIP=$PublicIp computer_name=$ComputerName" -Level INFO

    $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 15 -ErrorAction Stop
    if (-not $response.success) {
        throw 'API returned success=false'
    }

    $startTime = Get-StartTimeFromApiData -Data $response.data
    if ([string]::IsNullOrWhiteSpace($startTime)) {
        throw 'API response missing start_time'
    }

    return $startTime
}

function Get-SavedSessionStartTime {
    if (Test-Path -LiteralPath $script:StateFilePath) {
        try {
            $saved = (Get-Content -LiteralPath $script:StateFilePath -Raw -ErrorAction Stop).Trim()
            if ($saved) {
                Write-Log "Found saved start_time in $($script:StateFileName): $saved" -Level INFO
                return $saved
            }
        }
        catch { }
    }

    $logs = @(Get-ChildItem -LiteralPath $logDir -Filter 'StartSession_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $script:LogPath } |
        Sort-Object LastWriteTime -Descending)

    foreach ($log in $logs) {
        try {
            $lines = Get-Content -LiteralPath $log.FullName -Tail 100 -ErrorAction Stop
            foreach ($line in $lines) {
                if ($line -match 'SESSION_START_TIME=(.+)') {
                    $saved = $matches[1].Trim()
                    if ($saved) {
                        Write-Log "Found saved start_time in $($log.Name): $saved" -Level INFO
                        return $saved
                    }
                }
            }
        }
        catch { }
    }

    return $null
}

function Save-SessionStartTime {
    param([string]$StartTime)

    if ([string]::IsNullOrWhiteSpace($StartTime)) { return }

    Write-Log "SESSION_START_TIME=$StartTime" -Level INFO
    try {
        Set-Content -LiteralPath $script:StateFilePath -Value $StartTime -Encoding UTF8 -Force
    }
    catch {
        Write-Log "Could not write state file: $_" -Level WARN
    }
}

function Test-ShouldRunSessionVerify {
    $domainPath = Get-StartSessionDomainTxtPath
    if (-not $domainPath) {
        Write-Log 'domain.txt not found; proceeding with verify.' -Level WARN
        return @{ ShouldVerify = $true; Reason = 'domain.txt not found'; StartTime = $null }
    }

    Write-Log "Using domain.txt: $domainPath" -Level INFO

    try {
        $domain = Read-DomainTxtValues -Path $domainPath
    }
    catch {
        Write-Log "Failed to read domain.txt: $_" -Level WARN
        return @{ ShouldVerify = $true; Reason = 'domain.txt read failed'; StartTime = $null }
    }

    if ([string]::IsNullOrWhiteSpace($domain.PublicIp) -or [string]::IsNullOrWhiteSpace($domain.ComputerName)) {
        Write-Log 'PUBLIC_IP or COMPUTER_NAME missing from domain.txt; proceeding with verify.' -Level WARN
        return @{ ShouldVerify = $true; Reason = 'domain.txt missing PUBLIC_IP or COMPUTER_NAME'; StartTime = $null }
    }

    try {
        $apiStartTime = Get-MachineStartTimeFromApi -PublicIp $domain.PublicIp -ComputerName $domain.ComputerName
    }
    catch {
        Write-Log "getMachineInfor API failed: $_" -Level WARN
        return @{ ShouldVerify = $true; Reason = 'API call failed'; StartTime = $null }
    }

    Write-Log "API start_time=$apiStartTime" -Level INFO

    $savedStartTime = Get-SavedSessionStartTime
    if ([string]::IsNullOrWhiteSpace($savedStartTime)) {
        Write-Log 'No saved start_time; proceeding with verify.' -Level WARN
        return @{
            ShouldVerify = $true
            Reason       = 'No saved start_time from previous session'
            StartTime    = $apiStartTime
        }
    }

    Write-Log "Saved start_time=$savedStartTime" -Level INFO

    if ($apiStartTime -eq $savedStartTime) {
        return @{
            ShouldVerify = $false
            Reason       = 'API start_time matches saved start_time'
            StartTime    = $apiStartTime
        }
    }

    return @{
        ShouldVerify = $true
        Reason       = 'API start_time differs from saved start_time'
        StartTime    = $apiStartTime
    }
}

function Test-VerifyRequiresZeroLogon {
    param([string]$Reason)

    return $Reason -in @(
        'API start_time differs from saved start_time',
        'No saved start_time from previous session'
    )
}

Write-Log '========================================='
Write-Log "Preparing '$Username' for Moonlight session (SunshinePrep=$SunshinePrepLenient)..."
Write-Log '========================================='

Remove-BogusRentalUsers -KeepName $Username
Repair-BogusAutologon -Name $Username

$verifyGate = Test-ShouldRunSessionVerify

if (-not $verifyGate.ShouldVerify) {
    Write-Log "Skipping verify: $($verifyGate.Reason)" -Level PASS
    Write-Log 'Moonlight session can start.' -Level PASS
    Write-Log "Log saved to: $script:LogPath"
    exit 0
}

Write-Log "Verify required: $($verifyGate.Reason)" -Level INFO

$profilePolicy = 'Standard'
if (Test-VerifyRequiresZeroLogon -Reason $verifyGate.Reason) {
    $profilePolicy = 'RequireZeroLogon'
    Write-Log 'New rental session: profile must be absent (zero logon) or verify will fail and trigger user reset.' -Level INFO
}

$verifyExit = Invoke-NextGpuUserVerify -Name $Username -ProfilePolicy $profilePolicy

if ($verifyExit -ne 0) {
    if (Test-NextGpuUserSessionActive -Name $Username) {
        if ($profilePolicy -eq 'RequireZeroLogon') {
            Write-Log 'New rental: stale profile/session detected while nextGPU is logged in; logging off and recreating rental user...' -Level WARN
            $recreated = New-NextGpuRentalUser -Name $Username
        }
        elseif (-not $SunshinePrepLenient) {
            Write-Log 'Invalid rental user while session active; blocking connect (no logoff). Wipe requires explicit POST /host/cancel from the rental API (Moonlight does not call it automatically).' -Level FAIL
            Write-Log "Log saved to: $script:LogPath"
            exit 1
        }
        else {
            Write-Log 'Verify failed with active session (Sunshine prep; skipping logoff)...' -Level WARN
            $recreated = New-NextGpuRentalUser -Name $Username -SkipLogoffIfSessionActive
        }
    }
    else {
        Write-Log 'Verify failed - recreating rental user (machine idle)...' -Level WARN
        $recreated = New-NextGpuRentalUser -Name $Username
    }

    if (-not $recreated) {
        Write-Log 'Could not recreate rental user (run DO command Elevated).' -Level FAIL
        if ($SunshinePrepLenient) {
            Write-Log 'Sunshine prep exits 0 so stream may still attempt to start.' -Level WARN
            Write-Log "Log saved to: $script:LogPath"
            exit 0
        }
        Write-Log "Log saved to: $script:LogPath"
        exit 1
    }
    $verifyExit = Invoke-NextGpuUserVerify -Name $Username -ProfilePolicy 'AfterRecreate'
}

if ($verifyExit -eq 0) {
    if (-not [string]::IsNullOrWhiteSpace($verifyGate.StartTime)) {
        Save-SessionStartTime -StartTime $verifyGate.StartTime
    }
    Write-Log "OK: '$Username' is ready. Moonlight session can start." -Level PASS
    Write-Log "Log saved to: $script:LogPath"
    exit 0
}

if ($SunshinePrepLenient) {
    Write-Log 'Verify still failing after recreate; Sunshine prep exits 0.' -Level WARN
    Write-Log "Log saved to: $script:LogPath"
    exit 0
}

Write-Log "FAILED: '$Username' is not ready for streaming." -Level FAIL
Write-Log "Log saved to: $script:LogPath"
exit 1
