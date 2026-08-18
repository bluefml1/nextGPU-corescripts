#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Refresh admincred.dat ACL (SYSTEM + Administrators allow; nextGPU deny).
.DESCRIPTION
    Run after nextGPU is created or recreated so the deny ACE targets the new SID.
    Not part of user-storage Setup/Sync.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Repair-NextGpuAdminCredAcl.ps1
#>
[CmdletBinding()]
param([switch]$Quiet)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NextGPU-AdminCredential.ps1')

if (-not (Test-Path -LiteralPath $script:NextGpuAdminCredPath)) {
    if (-not $Quiet) {
        Write-Host '[INFO] admincred.dat not present; nothing to refresh.' -ForegroundColor DarkGray
    }
    exit 0
}

if (Update-NextGpuAdminCredRentalDenyAcl -Silent:$Quiet) {
    if (-not $Quiet) {
        Write-Host '[OK] admincred.dat rental deny ACL refreshed.' -ForegroundColor Green
    }
    exit 0
}

Write-Warning 'admincred.dat ACL refresh did not complete.'
exit 1
