#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Apply, revoke, or status NTFS ACL policy for NextGPU-Admin on Steam library folders.
#>
param(
    [string]$AdminUser = 'NextGPU-Admin',
    [switch]$StatusOnly,
    [switch]$Revoke,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$aclModule = Join-Path $scriptDir 'Steam-LibraryAcl.ps1'
if (-not (Test-Path -LiteralPath $aclModule)) {
    Write-Error "Missing helper module: $aclModule"
    exit 1
}

. $aclModule

if ($StatusOnly -and $Revoke) {
    Write-Error 'Use only one of -StatusOnly or -Revoke.'
    exit 1
}

$steamInstall = Get-SteamInstallPath
$libraryRoots = @(Resolve-SteamLibraryRoots)

if (-not $steamInstall) {
    foreach ($root in $libraryRoots) {
        $vdf = Join-Path $root 'config\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            $steamInstall = $root
            break
        }
    }
}

if ($libraryRoots.Count -eq 0) {
    Write-Host 'No Steam library roots resolved.'
    if (-not $StatusOnly) { exit 1 }
}

if ($StatusOnly) {
    Write-Host '--- Steam library ACL status ---'
    Write-Host ("AdminUser: {0}" -f $AdminUser)
    foreach ($root in $libraryRoots) {
        Write-Host ''
        Write-Host (Test-SteamLibraryAdminAcl -LibraryRoot $root -AdminUser $AdminUser)
    }
    Write-Host ''
    Write-Host ('SteamInstall: ' + $steamInstall)
    Write-Host ('LibraryRoots: ' + ($libraryRoots -join '; '))
    exit 0
}

$allOk = $true

if ($Revoke) {
    foreach ($root in $libraryRoots) {
        Write-Host ''
        Write-Host "=== Revoking NextGPU-Admin Steam ACLs: $root ==="
        if (-not (Revoke-SteamLibraryAdminAcl -LibraryRoot $root -AdminUser $AdminUser -WhatIf:$WhatIf)) {
            $allOk = $false
        }
    }

    if ($steamInstall) {
        Write-Host ''
        Write-Host '=== Unlocking libraryfolders.vdf (remove NextGPU-Admin ACEs) ==='
        if (-not (Unlock-SteamLibraryFoldersVdf -SteamInstallPath $steamInstall -AdminUser $AdminUser -WhatIf:$WhatIf)) {
            $allOk = $false
        }
    }

    if (-not $allOk) { exit 1 }
    Write-Host ''
    Write-Host 'Steam library ACL revoke completed (NextGPU-Admin ACEs removed). Users/NextGPURestricted unchanged.'
    exit 0
}

foreach ($root in $libraryRoots) {
    Write-Host ''
    Write-Host "=== Applying ACLs: $root ==="
    if (-not (Grant-SteamLibraryAdminAcl -LibraryRoot $root -AdminUser $AdminUser -WhatIf:$WhatIf)) {
        $allOk = $false
    }
}

if ($steamInstall) {
    Write-Host ''
    Write-Host '=== Locking libraryfolders.vdf ==='
    if (-not (Lock-SteamLibraryFoldersVdf -SteamInstallPath $steamInstall -AdminUser $AdminUser -WhatIf:$WhatIf)) {
        $allOk = $false
    }
}
else {
    Write-Host 'Warning: Steam install path not found; skipping libraryfolders.vdf lock.'
    $allOk = $false
}

if (-not $allOk) { exit 1 }
Write-Host ''
Write-Host 'Steam library ACL apply completed successfully.'
exit 0
