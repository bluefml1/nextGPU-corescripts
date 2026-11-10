#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    AtStartup recovery for EndSession leftover profile/account deletes.
.DESCRIPTION
    Exits immediately if %ProgramData%\nextGPU\endsession-reset-pending.flag is missing.
    Otherwise finishes CIM/folder cleanup and recreates listed users (nextGPU / NextGPU-Admin).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$script:ExitCode = 0
$script:LogPath = $null
$script:Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$script:RecoveryPath = 'normal'

function Write-RecoverLog {
    param([string]$Message)
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message"
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -ErrorAction Stop } catch { }
    }
    try { Write-Host $line } catch { }
}

function Get-RepoRoot {
    $marker = Join-Path $env:ProgramData 'nextGPU\repo-root.txt'
    if (Test-Path -LiteralPath $marker) {
        try {
            $marked = (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim().TrimEnd('\')
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
    # This script lives in scripts\runtime
    $fromHere = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    if (Test-Path -LiteralPath (Join-Path $fromHere 'domain.txt')) {
        return $fromHere
    }
    return $null
}

$logDir = Join-Path $env:ProgramData 'nextGPU\Logs'
if (-not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}
$script:LogPath = Join-Path $logDir ("EndSessionRecovery_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
Write-RecoverLog "EndSession AtStartup recovery started. Log=$script:LogPath"

$repoRoot = Get-RepoRoot
$commonPath = Join-Path $PSScriptRoot 'NextGpuEndSessionCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath) -and $repoRoot) {
    $commonPath = Join-Path $repoRoot 'scripts\runtime\NextGpuEndSessionCommon.ps1'
}
if (-not (Test-Path -LiteralPath $commonPath)) {
    Write-RecoverLog "ERROR: NextGpuEndSessionCommon.ps1 not found."
    exit 1
}
. $commonPath

function Write-BootContext {
    <#
    .SYNOPSIS
        Log when/how this boot happened and the status state the boot starts from.
    #>
    $bootTime = $null
    $uptimeSec = 'unknown'
    try {
        $bootTime = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
        $uptimeSec = [int]((Get-Date) - $bootTime).TotalSeconds
        Write-RecoverLog ("Boot: LastBootUpTime={0:yyyy-MM-dd HH:mm:ss} uptime={1}s (task delay PT20S)" -f $bootTime, $uptimeSec)
    }
    catch {
        Write-RecoverLog "WARN: could not read boot time: $($_.Exception.Message)"
    }

    # 1074 = planned shutdown/restart (process, user, reason); 6006 = clean stop;
    # 6008 / Kernel-Power 41 after boot = previous run ended without a clean shutdown (power cut / hard off).
    $previousShutdown = 'unknown'
    try {
        $since = if ($bootTime) { $bootTime.AddDays(-1) } else { (Get-Date).AddDays(-1) }
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074, 6006, 6008, 41; StartTime = $since } -MaxEvents 10 -ErrorAction SilentlyContinue)
        foreach ($e in $events) {
            $text = (($e.Message -replace '\s*\r?\n\s*', ' ').Trim())
            if ($text.Length -gt 400) { $text = $text.Substring(0, 400) + '...' }
            Write-RecoverLog ("Shutdown history: {0:yyyy-MM-dd HH:mm:ss} id={1} {2}" -f $e.TimeCreated, $e.Id, $text)
        }
        if ($bootTime) {
            $unexpected = @($events | Where-Object { ($_.Id -in @(6008, 41)) -and ($_.TimeCreated -ge $bootTime) })
            $before = @($events | Where-Object { $_.TimeCreated -lt $bootTime })
            $cleanStop = @($before | Where-Object { $_.Id -eq 6006 } | Select-Object -First 1)
            # Only a 1074 from the shutdown that ended the previous run counts, not an older one.
            $plannedAfter = if ($cleanStop.Count -gt 0) { $cleanStop[0].TimeCreated.AddMinutes(-15) } else { $bootTime.AddMinutes(-15) }
            $planned = @($before | Where-Object { $_.Id -eq 1074 -and $_.TimeCreated -ge $plannedAfter } | Select-Object -First 1)
            if ($unexpected.Count -gt 0) {
                $previousShutdown = 'unexpected (no clean shutdown: power cut / hard off)'
            }
            elseif ($planned.Count -gt 0) {
                $previousShutdown = 'planned'
                if ($planned[0].Message -match '(?i)process\s+(\S+)') { $previousShutdown = "planned by $($Matches[1])" }
            }
            elseif ($cleanStop.Count -gt 0) {
                $previousShutdown = 'clean (initiator not logged)'
            }
        }
    }
    catch {
        Write-RecoverLog "WARN: could not read shutdown history: $($_.Exception.Message)"
    }
    Write-RecoverLog "Previous shutdown: $previousShutdown"

    $flags = Get-NextGpuStatusFlagSnapshot
    Write-RecoverLog ("Flags: machine-status={0} heartbeat-suspended={1} startup-publish-pending={2} endsession-pending={3}" -f
        $flags.status, $flags.heartbeatSuspended, $flags.publishPending, $flags.endSessionPending)

    $autoLogon = '(unset)'
    $defaultUser = '(unset)'
    try {
        $winlogon = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction Stop
        if ($null -ne $winlogon.AutoAdminLogon) { $autoLogon = [string]$winlogon.AutoAdminLogon }
        if ($null -ne $winlogon.DefaultUserName) { $defaultUser = [string]$winlogon.DefaultUserName }
    }
    catch { }
    Write-RecoverLog "Autologon: AutoAdminLogon=$autoLogon DefaultUserName=$defaultUser"

    if (Get-Command quser.exe -ErrorAction SilentlyContinue) {
        try {
            $sessions = @(& quser.exe 2>&1 | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
            if ($sessions.Count -eq 0) { $sessions = @('(none)') }
            foreach ($s in $sessions) { Write-RecoverLog "Session: $s" }
        }
        catch {
            Write-RecoverLog "Session: (quser failed: $($_.Exception.Message))"
        }
    }
    else {
        Write-RecoverLog 'Session: (quser.exe not available)'
    }

    $privateIp = Get-NextGpuPrivateIp
    Write-RecoverLog "Network: privateIP=$privateIp"

    $data = [ordered]@{
        lastBoot           = $(if ($bootTime) { $bootTime.ToString('yyyy-MM-dd HH:mm:ss') } else { 'unknown' })
        uptimeSec          = $uptimeSec
        previousShutdown   = $previousShutdown
        status             = $flags.status
        heartbeatSuspended = $flags.heartbeatSuspended
        publishPending     = $flags.publishPending
        endSessionPending  = $flags.endSessionPending
        autoLogon          = $autoLogon
        privateIP          = $privateIp
    }
    Write-NextGpuStatusLog -Event 'BOOT_START' -Data $data -Message "log=$script:LogPath"
}

function Complete-Recovery {
    param([int]$Code)
    $script:ExitCode = $Code
    $ms = $script:Stopwatch.ElapsedMilliseconds
    $flags = Get-NextGpuStatusFlagSnapshot
    Write-NextGpuStatusLog -Event 'BOOT_DONE' -Data ([ordered]@{
            exit               = $Code
            path               = $script:RecoveryPath
            ms                 = $ms
            status             = $flags.status
            heartbeatSuspended = $flags.heartbeatSuspended
            publishPending     = $flags.publishPending
            endSessionPending  = $flags.endSessionPending
        })
    Write-RecoverLog "Finished ExitCode=$Code path=$script:RecoveryPath duration=${ms}ms"
    exit $Code
}

Write-BootContext

$credPath = $null
if ($repoRoot) {
    $credPath = Join-Path $repoRoot 'scripts\provisioning\NextGPU-AdminCredential.ps1'
}
if (-not $credPath -or -not (Test-Path -LiteralPath $credPath)) {
    $credPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'provisioning\NextGPU-AdminCredential.ps1'
}
if (Test-Path -LiteralPath $credPath) {
    . $credPath
    Write-RecoverLog "Loaded admin credential helper: $credPath"
}
else {
    Write-RecoverLog "WARN: NextGPU-AdminCredential.ps1 not found."
}

if (Test-NextGpuEndSessionPendingFlag) {
    $pendingUsers = @(Get-NextGpuEndSessionPendingUsers)
    Write-RecoverLog "Pending users: $($pendingUsers -join ', ')"
    if ($pendingUsers.Count -eq 0) {
        Write-RecoverLog "Flag present but empty user list; clearing flag."
        Clear-NextGpuEndSessionPendingFlag
        $script:RunEndSessionRecovery = $false
    }
    else {
        $script:RunEndSessionRecovery = $true
    }
}
else {
    Write-RecoverLog "No pending flag; skipping EndSession recovery (normal boot)."
    $script:RunEndSessionRecovery = $false
}

if (-not $script:RunEndSessionRecovery) {
    Write-RecoverLog "Publishing online at startup..."
    if (Publish-OnlineAtStartup) {
        Write-RecoverLog "SUCCESS: Publish-OnlineAtStartup completed."
        Complete-Recovery -Code 0
    }
    Write-RecoverLog "ERROR: Publish-OnlineAtStartup failed."
    Complete-Recovery -Code 1
}

# --- EndSession recovery path (pending flag present) ---
$script:RecoveryPath = 'endsession-recovery'
$pendingUsers = @(Get-NextGpuEndSessionPendingUsers)
Write-NextGpuStatusLog -Event 'BOOT_RECOVERY' -Data @{ users = ($pendingUsers -join ',') }
if ($pendingUsers.Count -eq 0) {
    Write-RecoverLog "Publishing online after empty pending clear..."
    if (-not (Publish-OnlineAtStartup)) {
        Complete-Recovery -Code 1
    }
    Complete-Recovery -Code 0
}

function Get-ProfileForUser {
    param([string]$User, [switch]$IncludeRenamed)
    return @(
        Get-CimInstance -ClassName Win32_UserProfile -ErrorAction SilentlyContinue |
            Where-Object {
                if (-not $_.LocalPath) { return $false }
                $folder = ($_.LocalPath -split '\\')[-1]
                if ($folder -eq $User) { return $true }
                if ($IncludeRenamed -and ($folder -like "${User}.*")) { return $true }
                return $false
            }
    )
}

function Get-ProfileFolders {
    param([string]$User)
    $usersRoot = Join-Path $env:SystemDrive 'Users'
    if (-not (Test-Path -LiteralPath $usersRoot)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $User -or $_.Name -like "${User}.*" }
    )
}

function Test-ProfileGone {
    param([string]$User)
    return ((@(Get-ProfileForUser -User $User -IncludeRenamed)).Count -eq 0 -and
            (@(Get-ProfileFolders -User $User)).Count -eq 0)
}

function Unload-Hive {
    param([string]$Sid)
    if ([string]::IsNullOrWhiteSpace($Sid)) { return }
    foreach ($hive in @("HKU\$Sid", "HKU\${Sid}_Classes")) {
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $null = & reg.exe unload $hive 2>&1
        $ErrorActionPreference = $prev
        if ($LASTEXITCODE -eq 0) {
            Write-RecoverLog "Unloaded $hive"
        }
    }
}

function Clear-UserProfileAndAccount {
    param([string]$User)

    Write-RecoverLog "Clearing leftovers for '$User'..."
    $deadline = (Get-Date).AddMinutes(3)
    do {
        foreach ($p in @(Get-ProfileForUser -User $User -IncludeRenamed)) {
            if ($p.Loaded) {
                Unload-Hive -Sid $p.SID
            }
            try {
                $fresh = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
                    Where-Object { $_.SID -eq $p.SID }
                if ($fresh -and -not $fresh.Loaded) {
                    $fresh | Remove-CimInstance -ErrorAction Stop
                    Write-RecoverLog "Deleted CIM $($p.LocalPath)"
                }
            }
            catch {
                Write-RecoverLog "WARN: CIM delete: $_"
            }
        }

        foreach ($dir in @(Get-ProfileFolders -User $User)) {
            try {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                Write-RecoverLog "Deleted folder $($dir.FullName)"
            }
            catch {
                Write-RecoverLog "WARN: folder delete: $_"
            }
        }

        if (Test-ProfileGone -User $User) { break }
        Start-Sleep -Seconds 3
    } while ((Get-Date) -lt $deadline)

    if (-not (Test-ProfileGone -User $User)) {
        Write-RecoverLog "ERROR: leftovers remain for '$User' after wait."
        return $false
    }

    try {
        Remove-LocalUser -Name $User -ErrorAction Stop
        Write-RecoverLog "Deleted account '$User'."
    }
    catch {
        Write-RecoverLog "INFO: account delete '$User': $_"
    }

    return (Test-ProfileGone -User $User)
}

function Ensure-RentalUser {
    param([string]$User)

    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $r = net user $User /add 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-RecoverLog "ERROR: recreate '$User': $r"
            return $false
        }
        Write-RecoverLog "Recreated '$User'."
    }
    else {
        Write-RecoverLog "Account '$User' already exists."
    }

    try {
        Add-LocalGroupMember -Group 'Users' -Member $User -ErrorAction Stop
    }
    catch {
        if ("$_" -notmatch '(?i)already a member') {
            Write-RecoverLog "WARN: Users group: $_"
        }
    }

    $ensure = $null
    if ($repoRoot) {
        $c = Join-Path $repoRoot 'scripts\provisioning\Ensure-NextGpuRestrictedGroup.ps1'
        if (Test-Path -LiteralPath $c) { $ensure = $c }
    }
    if ($ensure) {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ensure -UserName $User
        Write-RecoverLog "Ensure-NextGpuRestrictedGroup exit=$LASTEXITCODE"
    }
    else {
        $g = 'NextGPURestricted'
        if (-not (Get-LocalGroup -Name $g -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $g -Description 'nextGPU rental restricted access' | Out-Null
        }
        try { Add-LocalGroupMember -Group $g -Member $User -ErrorAction Stop } catch { }
    }

    # Recreate only: an unattended first sign-in of the fresh profile can be interrupted
    # mid app-provisioning, which leaves sihost.exe crashing (0xC0000409) for that user.
    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    try {
        Set-ItemProperty -Path $reg -Name AutoAdminLogon -Value '0' -Force -ErrorAction Stop
        Write-RecoverLog "Autologon disabled ('$User' recreated only, not signed in)."
    }
    catch {
        Write-RecoverLog "WARN: disable autologon: $_"
    }
    return $true
}

function Ensure-AdminUser {
    param([string]$User)

    $Password = $null
    if (Get-Command Get-NextGpuAdminCredential -ErrorAction SilentlyContinue) {
        $cred = Get-NextGpuAdminCredential -AdminUser $User -Silent
        if ($cred) {
            $Password = $cred.GetNetworkCredential().Password
        }
    }
    if ([string]::IsNullOrEmpty($Password)) {
        Write-RecoverLog "WARN: no admincred password; skip recreate of '$User'."
        return $false
    }

    if (-not (Get-LocalUser -Name $User -ErrorAction SilentlyContinue)) {
        $r = net user $User $Password /add /y 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-RecoverLog "ERROR: recreate '$User': $r"
            return $false
        }
        Write-RecoverLog "Recreated '$User'."
    }
    else {
        try {
            Set-LocalUser -Name $User -Password (ConvertTo-SecureString $Password -AsPlainText -Force) -ErrorAction Stop
            Write-RecoverLog "Updated password for existing '$User'."
        }
        catch {
            Write-RecoverLog "WARN: set password '$User': $_"
        }
    }

    try {
        Add-LocalGroupMember -Group 'Administrators' -Member $User -ErrorAction Stop
    }
    catch {
        if ("$_" -notmatch '(?i)already a member') {
            Write-RecoverLog "WARN: Administrators: $_"
        }
    }
    try {
        Set-LocalUser -Name $User -PasswordNeverExpires $true -ErrorAction Stop
    }
    catch {     }
    return $true
}

function Invoke-NextGpuAdminCredRentalDenyAclRefresh {
    if (-not (Get-Command Update-NextGpuAdminCredRentalDenyAcl -ErrorAction SilentlyContinue)) {
        return
    }
    try {
        if (Update-NextGpuAdminCredRentalDenyAcl -Silent) {
            Write-RecoverLog 'Refreshed admincred.dat deny ACL for nextGPU.'
        }
    }
    catch {
        Write-RecoverLog "WARN: admincred.dat ACL refresh: $($_.Exception.Message)"
    }
}

$allOk = $true
foreach ($user in $pendingUsers) {
    Write-RecoverLog "=== Recovering '$user' ==="
    if (-not (Clear-UserProfileAndAccount -User $user)) {
        $allOk = $false
        Write-RecoverLog "ERROR: could not clear '$user'; will keep pending flag."
        continue
    }

    if ($user -eq 'NextGPU-Admin' -or $user -like '*Admin*') {
        if (-not (Ensure-AdminUser -User $user)) {
            $allOk = $false
        }
    }
    else {
        if (-not (Ensure-RentalUser -User $user)) {
            $allOk = $false
        }
        elseif ($user -ieq 'nextGPU') {
            Invoke-NextGpuAdminCredRentalDenyAclRefresh
        }
    }
}

if ($allOk) {
    Clear-NextGpuEndSessionPendingFlag
    Write-RecoverLog "SUCCESS: recovery complete; pending flag cleared."
    Write-RecoverLog "Publishing online after successful EndSession recovery..."
    if (Publish-OnlineAtStartup) {
        Write-RecoverLog "SUCCESS: Publish-OnlineAtStartup completed."
        Complete-Recovery -Code 0
    }
    Write-RecoverLog "ERROR: Publish-OnlineAtStartup failed after recovery."
    Complete-Recovery -Code 1
}

Write-RecoverLog "ERROR: recovery incomplete; pending flag retained for next boot; skipping publish online."
Write-NextGpuStatusLog -Event 'BOOT_RECOVERY' -Data @{ result = 'incomplete'; users = ($pendingUsers -join ',') }
Complete-Recovery -Code 1
