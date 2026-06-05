#Requires -Version 5.1
<#
.SYNOPSIS
    Per-logon UI policy: block shutdown/restart for all users except NextGPU-Authority.
    Invoked by scheduled task "nextGPU-ShutdownPolicyLogon".
#>
[CmdletBinding()]
param(
    [string]$AuthorityAccountName = 'NextGPU-Authority'
)

$ErrorActionPreference = 'SilentlyContinue'

$explorerPolicy = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
if (-not (Test-Path -LiteralPath $explorerPolicy)) {
    New-Item -Path $explorerPolicy -Force | Out-Null
}

$user = $env:USERNAME
if ($user -ieq $AuthorityAccountName) {
    Remove-ItemProperty -LiteralPath $explorerPolicy -Name 'NoClose' -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $explorerPolicy -Name 'NoStartMenuSubItems' -ErrorAction SilentlyContinue
} else {
    Set-ItemProperty -LiteralPath $explorerPolicy -Name 'NoClose' -Value 1 -Type DWord -Force
    # Hides Shut down / Restart / Sleep on Start menu and Win+X power menu (legacy policy).
    Set-ItemProperty -LiteralPath $explorerPolicy -Name 'NoStartMenuSubItems' -Value 1 -Type DWord -Force
}

exit 0
