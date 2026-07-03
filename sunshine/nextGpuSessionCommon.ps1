# Shared nextGPU rental-user helpers for startSession.ps1 and cancelSession.ps1.
# Caller must set $script:LogPath before dot-sourcing this file.
# Optional: $script:StateFilePath for Clear-SessionStartTime.

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'PASS', 'FAIL', 'WARN')]
        [string]$Level = 'INFO'
    )

    $Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $LogMessage = "[$Timestamp] [$Level] $Message"

    try {
        if ($script:LogPath) {
            Add-Content -Path $script:LogPath -Value $LogMessage -ErrorAction Stop
        }
    }
    catch {
        $tag = if ($script:LogFallbackTag) { $script:LogFallbackTag } else { 'NextGpuSession' }
        $fallback = Join-Path $env:TEMP "${tag}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        Add-Content -Path $fallback -Value $LogMessage -ErrorAction SilentlyContinue
    }
    Write-Host $LogMessage
}

function Get-NextGpuRepoRootForProvisioning {
    $markerPath = Join-Path $env:ProgramData 'nextGPU\repo-root.txt'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marked = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            if ($marked -and (Test-Path -LiteralPath (Join-Path $marked 'domain.txt'))) {
                return $marked
            }
        }
        catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $envRoot = $env:NEXTGPU_REPO_ROOT.Trim().TrimEnd('\')
        if (Test-Path -LiteralPath (Join-Path $envRoot 'domain.txt')) {
            return $envRoot
        }
    }

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady -or $drive.DriveType -ne 'Fixed') {
            continue
        }

        try {
            $domainFiles = Get-ChildItem -LiteralPath $drive.RootDirectory.FullName -Filter 'domain.txt' `
                -File -Recurse -Depth 6 -ErrorAction SilentlyContinue
            foreach ($domainFile in $domainFiles) {
                $repoRoot = $domainFile.Directory.FullName
                $batchPath = Join-Path $repoRoot 'scripts\runtime\checking-update.bat'
                if (Test-Path -LiteralPath $batchPath) {
                    return $repoRoot.TrimEnd('\')
                }
            }
        }
        catch { }
    }

    return $null
}

function Invoke-NextGpuRestrictedGroupEnsure {
    param([string]$Name = 'nextGPU')

    $repoRoot = Get-NextGpuRepoRootForProvisioning
    $helperPs1 = if ($repoRoot) {
        Join-Path $repoRoot 'scripts\provisioning\Ensure-NextGpuRestrictedGroup.ps1'
    } else {
        $null
    }

    if (-not $helperPs1 -or -not (Test-Path -LiteralPath $helperPs1)) {
        Write-Log "Ensure-NextGpuRestrictedGroup.ps1 not found (repo: $repoRoot)." -Level WARN
        return $false
    }

    try {
        $output = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $helperPs1 -UserName $Name 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Write-Log "NextGPURestricted membership ensured for '$Name'." -Level PASS
            return $true
        }
        Write-Log "Ensure-NextGpuRestrictedGroup.ps1 failed (exit $LASTEXITCODE): $($output.Trim())" -Level WARN
    }
    catch {
        Write-Log "Ensure-NextGpuRestrictedGroup.ps1: $($_.Exception.Message)" -Level WARN
    }
    return $false
}

function Test-NextGpuUserSessionActive {
    param([string]$Name)

    try {
        $sessionLine = quser.exe 2>$null | Select-String -SimpleMatch $Name -ErrorAction SilentlyContinue
        return [bool]$sessionLine
    }
    catch {
        return $false
    }
}

function Get-NextGpuQuserLine {
    param([string]$Name)

    $line = quser.exe 2>$null | Select-String -SimpleMatch $Name -ErrorAction SilentlyContinue
    if (-not $line) {
        return $null
    }
    return $line.ToString().Trim().TrimStart('>')
}

function Get-NextGpuSessionId {
    param([string]$Name)

    $line = Get-NextGpuQuserLine -Name $Name
    if (-not $line) {
        return $null
    }

    $parts = @($line -split '\s+' | Where-Object { $_ })
    if ($parts.Count -lt 2) {
        return $null
    }

    # USERNAME ID STATE ... (no session name — common for Disc / idle disconnect)
    if ($parts[1] -match '^\d+$') {
        return $parts[1]
    }

    # USERNAME SESSIONNAME ID STATE ...
    if ($parts.Count -ge 3 -and $parts[2] -match '^\d+$') {
        return $parts[2]
    }

    return $null
}

function Stop-NextGpuUserSession {
    param(
        [string]$Name,
        [int]$TimeoutSeconds = 90
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        $sessionId = Get-NextGpuSessionId -Name $Name
        if (-not $sessionId) {
            Write-Log "No interactive session listed for '$Name'." -Level INFO
            return $true
        }

        try {
            logoff.exe $sessionId 2>$null | Out-Null
            Write-Log "Logged off '$Name' (session id $sessionId)." -Level INFO
        }
        catch {
            Write-Log "Logoff failed for session $sessionId : $_" -Level WARN
        }

        Start-Sleep -Seconds 3

        if (-not (Get-NextGpuSessionId -Name $Name)) {
            Write-Log "Session for '$Name' ended after logoff." -Level PASS
            Start-Sleep -Seconds 2
            return $true
        }
    }

    if (Get-NextGpuSessionId -Name $Name) {
        Write-Log "Session for '$Name' still listed after ${TimeoutSeconds}s." -Level WARN
        return $false
    }

    return $true
}

function Remove-NextGpuProfilesWithRetry {
    param(
        [string]$Name,
        [int]$MaxAttempts = 18,
        [int]$DelaySeconds = 4
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $profiles = @(Get-NextGpuProfiles -Name $Name)
        if ($profiles.Count -eq 0) {
            if ($attempt -gt 1) {
                Write-Log "All profiles removed for '$Name'." -Level PASS
            }
            else {
                Write-Log 'No profile to delete.' -Level INFO
            }
            return $true
        }

        foreach ($profile in $profiles) {
            try {
                if ($profile.Loaded) {
                    Write-Log "Profile $($profile.LocalPath) still loaded (attempt $attempt/$MaxAttempts)." -Level WARN
                    continue
                }

                $profile | Remove-CimInstance -ErrorAction Stop
                Write-Log "Deleted profile $($profile.LocalPath)." -Level PASS
            }
            catch {
                Write-Log "Delete profile attempt $attempt/$MaxAttempts failed: $_" -Level WARN
            }
        }

        $remaining = @(Get-NextGpuProfiles -Name $Name)
        if ($remaining.Count -eq 0) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $leftover = @(Get-NextGpuProfiles -Name $Name)
    if ($leftover.Count -gt 0) {
        $paths = ($leftover | ForEach-Object { $_.LocalPath }) -join '; '
        Write-Log "Profile cleanup incomplete for '$Name': $paths" -Level FAIL
        return $false
    }

    return $true
}

function Test-NextGpuProfileMatchesName {
    param(
        [string]$Name,
        $Profile
    )

    if ($null -eq $Profile) {
        return $false
    }

    $localPath = [string]$Profile.LocalPath
    if ([string]::IsNullOrWhiteSpace($localPath)) {
        return $false
    }

    $folder = ($localPath.Trim().TrimEnd('\') -split '\\')[-1]
    return $folder -ieq $Name
}

function Get-NextGpuProfiles {
    param([string]$Name)

    # Always return a plain array (0, 1, or N real profiles). Do not use a leading comma here —
    # callers must not wrap with @() again or an empty result becomes a fake 1-element array.
    @(
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object { Test-NextGpuProfileMatchesName -Name $Name -Profile $_ }
    )
}

function Remove-BogusRentalUsers {
    param([string]$KeepName)

    foreach ($bogus in @('false', 'true')) {
        if ($bogus -ieq $KeepName) {
            continue
        }

        try {
            $bogusUser = Get-LocalUser -Name $bogus -ErrorAction SilentlyContinue
            if (-not $bogusUser) {
                continue
            }

            if (Test-NextGpuUserSessionActive -Name $bogus) {
                Write-Log "Skipping delete of bogus user '$bogus' (active session)." -Level WARN
                continue
            }

            Remove-LocalUser -Name $bogus -ErrorAction Stop
            Write-Log "Removed bogus local user '$bogus'." -Level PASS
        }
        catch {
            Write-Log "Could not remove bogus user '$bogus': $_" -Level WARN
        }

        try {
            $profiles = Get-NextGpuProfiles -Name $bogus
            foreach ($profile in $profiles) {
                $profile | Remove-CimInstance -ErrorAction Stop
                Write-Log "Removed bogus profile $($profile.LocalPath)." -Level PASS
            }
        }
        catch {
            Write-Log "Could not remove bogus profile '$bogus': $_" -Level WARN
        }
    }
}

function Set-NextGpuAutologon {
    param([string]$Name)

    $RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        Set-ItemProperty -Path $RegPath -Name 'AutoAdminLogon' -Value '1' -Force
        Set-ItemProperty -Path $RegPath -Name 'DefaultUserName' -Value $Name -Force
        Set-ItemProperty -Path $RegPath -Name 'DefaultPassword' -Value '' -Force
        Set-ItemProperty -Path $RegPath -Name 'DefaultDomainName' -Value '.' -Force
        Write-Log "Autologon configured for '$Name'." -Level PASS
    }
    catch {
        Write-Log "Autologon setup failed: $_" -Level WARN
    }
}

function Repair-BogusAutologon {
    param([string]$Name)

    $RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        $defaultUser = (Get-ItemProperty -Path $RegPath -Name 'DefaultUserName' -ErrorAction Stop).DefaultUserName
        if ($defaultUser -match '^(?i:true|false)$') {
            Write-Log "Repairing autologon DefaultUserName=$defaultUser -> $Name" -Level WARN
            Set-NextGpuAutologon -Name $Name
        }
    }
    catch {
        Write-Log "Autologon repair skipped: $_" -Level WARN
    }
}

function New-NextGpuRentalUser {
    param(
        [string]$Name,
        [switch]$SkipLogoffIfSessionActive
    )

    Write-Log "Recreating rental user '$Name'..." -Level INFO

    if ($SkipLogoffIfSessionActive) {
        if (Test-NextGpuUserSessionActive -Name $Name) {
            Write-Log "Session active for '$Name'; skipping logoff (Sunshine prep)." -Level WARN
        }
        else {
            Write-Log "No active session for '$Name'." -Level INFO
        }
    }
    else {
        $null = Stop-NextGpuUserSession -Name $Name
    }

    try {
        Remove-LocalUser -Name $Name -ErrorAction Stop
        Write-Log "Deleted local user '$Name'." -Level PASS
    }
    catch {
        Write-Log "Delete user (may not exist): $_" -Level WARN
    }

    if (-not (Remove-NextGpuProfilesWithRetry -Name $Name)) {
        Write-Log "Could not remove all profiles for '$Name'." -Level FAIL
        return $false
    }

    $existing = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "User '$Name' still exists after cleanup; repairing settings in place." -Level INFO
    }
    else {
        $result = net user $Name /add 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Failed to create user '$Name': $result" -Level FAIL
            return $false
        }
        Write-Log "Created local user '$Name'." -Level PASS
    }

    try {
        $members = @(Get-LocalGroupMember -Group 'Users' -ErrorAction Stop)
        $inGroup = $members.Name | Where-Object { $_ -like "*\$Name" }
        if (-not $inGroup) {
            Add-LocalGroupMember -Group 'Users' -Member $Name -ErrorAction Stop
            Write-Log "Added '$Name' to Users group." -Level PASS
        }
        else {
            Write-Log "'$Name' is already in Users group." -Level PASS
        }
    }
    catch {
        Write-Log "Add to Users group: $_" -Level WARN
    }

    $null = Invoke-NextGpuRestrictedGroupEnsure -Name $Name

    Set-NextGpuAutologon -Name $Name

    $created = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    if (-not $created) {
        Write-Log "User '$Name' not found after recreate." -Level FAIL
        return $false
    }

    Write-Log "Rental user '$Name' recreated successfully." -Level PASS
    return $true
}

function Invoke-NextGpuUserVerify {
    param(
        [string]$Name,
        [ValidateSet('Standard', 'RequireZeroLogon', 'AfterRecreate')]
        [string]$ProfilePolicy = 'Standard'
    )

    $script:failCount = 0

    function Assert-Check {
        param(
            [string]$Label,
            [bool]$Ok,
            [string]$Detail = ''
        )

        if ($Ok) {
            $msg = $Label
            if ($Detail) { $msg += " - $Detail" }
            Write-Log $msg -Level PASS
        }
        else {
            $msg = $Label
            if ($Detail) { $msg += " - $Detail" }
            Write-Log $msg -Level FAIL
            $script:failCount++
        }
    }

    Write-Log "STEP 1: Checking local user '$Name'..."

    $localUser = Get-LocalUser -Name $Name -ErrorAction SilentlyContinue
    Assert-Check -Label 'Local user account exists' -Ok ([bool]$localUser) `
        -Detail $(if ($localUser) { "SID=$($localUser.SID)" } else { 'Account not found' })

    if (-not $localUser) {
        return 1
    }

    Assert-Check -Label 'Local user is enabled' -Ok $localUser.Enabled

    Write-Log "STEP 2: Checking profile / logon state for '$Name' (policy=$ProfilePolicy)..."

    $profiles = Get-NextGpuProfiles -Name $Name

    if ($ProfilePolicy -eq 'RequireZeroLogon') {
        if ($profiles.Count -eq 0) {
            Write-Log 'Zero logon: no prior profile (safe for new rental).' -Level PASS
        }
        else {
            $paths = ($profiles | ForEach-Object { $_.LocalPath }) -join '; '
            Assert-Check -Label 'Zero logon required for new rental' -Ok $false `
                -Detail "Found $($profiles.Count) profile(s): $paths"
        }
    }
    elseif ($profiles.Count -eq 0) {
        Write-Log 'No profile yet (first logon will create it).' -Level PASS
    }
    elseif ($profiles.Count -eq 1) {
        $profile = $profiles[0]
        $sidMatches = ($profile.SID -eq $localUser.SID.Value)
        Assert-Check -Label 'Profile SID matches current user' -Ok $sidMatches `
            -Detail $(if ($sidMatches) { $profile.LocalPath } else { "Profile SID=$($profile.SID) user SID=$($localUser.SID) path=$($profile.LocalPath)" })
    }
    else {
        Assert-Check -Label 'At most one profile for rental user' -Ok $false -Detail "Found $($profiles.Count) profile(s)"
    }

    Write-Log "STEP 3: Checking interactive session for '$Name'..."

    if (Test-NextGpuUserSessionActive -Name $Name) {
        Write-Log 'Active session detected (expected for Sunshine streaming).' -Level PASS
    }
    else {
        Write-Log 'No active session (autologon may run on connect).' -Level INFO
    }

    Write-Log "STEP 4: Checking '$Name' group membership..."

    try {
        $members = @(Get-LocalGroupMember -Group 'Users' -ErrorAction Stop)
        $inGroup = $members.Name -contains "$env:COMPUTERNAME\$Name" -or
            ($members.Name | Where-Object { $_ -like "*\$Name" })
        Assert-Check -Label 'User is member of Users group' -Ok ([bool]$inGroup)
    }
    catch {
        Assert-Check -Label 'User is member of Users group' -Ok $false -Detail $_.Exception.Message
    }

    Write-Log "STEP 5: Checking autologon for '$Name'..."

    $RegPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

    try {
        $autoLogon = (Get-ItemProperty -Path $RegPath -Name 'AutoAdminLogon' -ErrorAction Stop).AutoAdminLogon
        $defaultUser = (Get-ItemProperty -Path $RegPath -Name 'DefaultUserName' -ErrorAction Stop).DefaultUserName

        Assert-Check -Label 'AutoAdminLogon enabled' -Ok ($autoLogon -eq '1')
        Assert-Check -Label 'DefaultUserName matches rental user' -Ok ($defaultUser -ieq $Name) `
            -Detail "DefaultUserName=$defaultUser"
    }
    catch {
        Assert-Check -Label 'Autologon registry configured' -Ok $false -Detail $_.Exception.Message
    }

    if ($script:failCount -eq 0) {
        return 0
    }

    return 1
}

function Clear-SessionStartTime {
    if (-not $script:StateFilePath) {
        return
    }

    try {
        if (Test-Path -LiteralPath $script:StateFilePath) {
            Remove-Item -LiteralPath $script:StateFilePath -Force -ErrorAction Stop
            Write-Log "Removed saved start_time file: $($script:StateFilePath)" -Level INFO
        }
    }
    catch {
        Write-Log "Could not remove saved start_time file: $_" -Level WARN
    }
}
