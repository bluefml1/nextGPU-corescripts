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

if (-not (Test-NextGpuEndSessionPendingFlag)) {
    Write-RecoverLog "No pending flag; exiting (normal boot)."
    exit 0
}

$pendingUsers = @(Get-NextGpuEndSessionPendingUsers)
Write-RecoverLog "Pending users: $($pendingUsers -join ', ')"
if ($pendingUsers.Count -eq 0) {
    Write-RecoverLog "Flag present but empty user list; clearing flag."
    Clear-NextGpuEndSessionPendingFlag
    exit 0
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

    $reg = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty -Path $reg -Name AutoAdminLogon -Value '1' -Force
    Set-ItemProperty -Path $reg -Name DefaultUserName -Value $User -Force
    Set-ItemProperty -Path $reg -Name DefaultPassword -Value '' -Force
    Set-ItemProperty -Path $reg -Name DefaultDomainName -Value '.' -Force
    Write-RecoverLog "Autologon set for '$User'."
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
    $script:ExitCode = 0
}
else {
    Write-RecoverLog "ERROR: recovery incomplete; pending flag retained for next boot."
    $script:ExitCode = 1
}

Write-RecoverLog "Finished ExitCode=$script:ExitCode"
exit $script:ExitCode
