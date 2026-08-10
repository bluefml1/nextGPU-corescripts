#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Ensure local group NextGPURestricted exists and optionally add the rental user.
.DESCRIPTION
    -CreateGroupOnly: create the group if missing (no user required).
    Full mode: ensure group, verify user exists, add user to group if not already a member.
#>
[CmdletBinding()]
param(
    [string]$UserName = 'nextGPU',
    [string]$GroupName = 'NextGPURestricted',
    [switch]$CreateGroupOnly
)

$ErrorActionPreference = 'Stop'

function Ensure-NextGpuRestrictedGroupMembership {
    param(
        [string]$UserName = 'nextGPU',
        [string]$GroupName = 'NextGPURestricted',
        [switch]$CreateGroupOnly
    )

    $group = Get-LocalGroup -Name $GroupName -ErrorAction SilentlyContinue
    if (-not $group) {
        New-LocalGroup -Name $GroupName -Description 'nextGPU rental restricted access' | Out-Null
        Write-Host "[*] Created local group '$GroupName'." -ForegroundColor Green
    }
    else {
        Write-Host "[*] Local group '$GroupName' already exists." -ForegroundColor DarkGray
    }

    if ($CreateGroupOnly) {
        return $true
    }

    $user = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue
    if (-not $user) {
        Write-Warning "Local user '$UserName' not found; cannot add to '$GroupName'."
        return $false
    }

    # Bypass admin accounts must never be in the deny-delete group — DENY(DE,DC) beats Full Control
    # and breaks Steam/Playnite updates when those apps run elevated as NextGPU-Admin.
    $forbidden = @('NextGPU-Admin', 'NextGPU-Authority', 'Administrator')
    if ($forbidden -contains $UserName) {
        Write-Warning "Refusing to add '$UserName' to '$GroupName' (elevated admin; would block Steam file replace)."
        return $false
    }

    $members = @(Get-LocalGroupMember -Group $GroupName -ErrorAction SilentlyContinue)
    $alreadyMember = $members | Where-Object { $_.SID -eq $user.SID -or $_.Name -like "*\$UserName" }
    if ($alreadyMember) {
        Write-Host "[*] '$UserName' is already in '$GroupName'." -ForegroundColor DarkGray
        return $true
    }

    Add-LocalGroupMember -Group $GroupName -Member $UserName -ErrorAction Stop
    Write-Host "[OK] Added '$UserName' to '$GroupName'." -ForegroundColor Green
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    $ok = Ensure-NextGpuRestrictedGroupMembership @PSBoundParameters
    if (-not $ok) { exit 1 }
    exit 0
}
