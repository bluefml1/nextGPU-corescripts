#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Re-bind user storage tasks and ACLs to the current local nextGPU account (same name, new SID after recreate).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Sync-NextGpuUserStorageForLocalUser.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'UserStorageCommon.ps1')

$ok = Sync-NextGpuUserStorageForLocalUser -SourceDir $PSScriptRoot
if (-not $ok) { exit 1 }
exit 0
