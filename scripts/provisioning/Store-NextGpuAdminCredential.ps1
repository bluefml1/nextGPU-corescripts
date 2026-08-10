#Requires -Version 5.1
<#
.SYNOPSIS
    Stores the NextGPU-Admin password and optionally creates the local admin account.
.DESCRIPTION
    Called from NextGPU App (Bypass page Setup dialog) and Import-RegisterMachineConfig.ps1.
    The app passes a Base64 DPAPI blob encrypted with CurrentUser scope; this script
    decrypts it and re-stores via Set-NextGpuAdminCredential (LocalMachine DPAPI).
#>
[CmdletBinding()]
param(
    [string]$EncryptedPassword,
    [switch]$CreateUser,
    [switch]$StatusOnly,
    [string]$AdminUser = 'NextGPU-Admin'
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NextGPU-AdminCredential.ps1')

function Test-NextGpuAdminUserExists {
    param([string]$AdminUser = 'NextGPU-Admin')
    try {
        if (Get-LocalUser -Name $AdminUser -ErrorAction Stop) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

function Test-NextGpuAdminIsAdmin {
    param([string]$AdminUser = 'NextGPU-Admin')
    try {
        $members = Get-LocalGroupMember -Group 'Administrators' -ErrorAction SilentlyContinue
        if ($members -and ($members | Where-Object { $_.Name -like "*$AdminUser" })) {
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

function New-NextGpuAdminUser {
    param(
        [Parameter(Mandatory)]
        [SecureString]$Password,
        [string]$AdminUser = 'NextGPU-Admin'
    )

    try {
        $existingUser = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-Host "[INFO] User '$AdminUser' already exists"
            Set-LocalUser -Name $AdminUser -Password $Password -ErrorAction Stop
            Write-Host "[OK] Updated password for '$AdminUser'"

            if (-not (Test-NextGpuAdminIsAdmin -AdminUser $AdminUser)) {
                Add-LocalGroupMember -Group 'Administrators' -Member $AdminUser -ErrorAction Stop
                Write-Host "[OK] Added '$AdminUser' to Administrators group"
            }
            return $true
        }

        New-LocalUser -Name $AdminUser -Password $Password -Description 'NextGPU bypass admin account' -PasswordNeverExpires -ErrorAction Stop
        Write-Host "[OK] Created local user '$AdminUser'"

        Add-LocalGroupMember -Group 'Administrators' -Member $AdminUser -ErrorAction Stop
        Write-Host "[OK] Added '$AdminUser' to Administrators group"
        return $true
    }
    catch {
        Write-Error "Failed to create or update user account: $_"
        return $false
    }
}

if ($StatusOnly) {
    $userExists = [bool](Test-NextGpuAdminUserExists -AdminUser $AdminUser)
    $isAdmin = [bool](Test-NextGpuAdminIsAdmin -AdminUser $AdminUser)
    $credExists = [bool](Test-NextGpuAdminCredentialExists)
    @{
        UserExists = $userExists
        IsAdmin    = $isAdmin
        CredExists = $credExists
    } | ConvertTo-Json -Compress
    exit 0
}

if ([string]::IsNullOrWhiteSpace($EncryptedPassword)) {
    Write-Error 'EncryptedPassword is required.'
    exit 1
}

try {
    Add-Type -AssemblyName System.Security

    $protectedBytes = [Convert]::FromBase64String($EncryptedPassword)
    $decrypted = $null
    foreach ($scope in @(
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )) {
        try {
            $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $protectedBytes, $null, $scope)
            break
        }
        catch {
            # Try the next scope.
        }
    }

    if (-not $decrypted) {
        Write-Error 'Failed to decrypt EncryptedPassword.'
        exit 1
    }

    $plainText = [System.Text.Encoding]::UTF8.GetString($decrypted)
    $secure = ConvertTo-SecureString $plainText -AsPlainText -Force
    $plainText = $null

    if ($CreateUser) {
        if (-not (New-NextGpuAdminUser -Password $secure -AdminUser $AdminUser)) {
            exit 1
        }
    }

    Set-NextGpuAdminCredential -Password $secure
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
