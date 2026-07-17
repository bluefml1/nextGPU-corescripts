#Requires -Version 5.1
<#
.SYNOPSIS
    Stores the NextGPU-Admin password securely using DPAPI and ensures the user account exists as admin.
    Called by Import-RegisterMachineConfig.ps1 after parsing the UI config.
.PARAMETER EncryptedPassword
    Base64-encoded DPAPI-encrypted password from the NextGPU app.
.PARAMETER CreateUser
    If specified, creates the NextGPU-Admin user account if it doesn't exist.
    The user will be created as a member of the Administrators group.
.EXAMPLE
    .\Store-NextGpuAdminCredential.ps1 -EncryptedPassword "AQAA..."
.EXAMPLE
    .\Store-NextGpuAdminCredential.ps1 -EncryptedPassword "AQAA..." -CreateUser
#>
param(
    [string]$EncryptedPassword,
    [switch]$CreateUser,
    [switch]$StatusOnly
)

Add-Type -AssemblyName System.Security

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "NextGPU-AdminCredential.ps1")

function Test-NextGpuAdminUserExists {
    param([string]$AdminUser = "NextGPU-Admin")
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
    param([string]$AdminUser = "NextGPU-Admin")
    try {
        $members = Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue
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
        [string]$AdminUser = "NextGPU-Admin"
    )
    $ErrorActionPreference = "Stop"
    try {
        # Check if user already exists
        $existingUser = Get-LocalUser -Name $AdminUser -ErrorAction SilentlyContinue
        if ($existingUser) {
            Write-Host "[INFO] User '$AdminUser' already exists"
            # Ensure user is in Administrators group
            $isInAdmin = Test-NextGpuAdminIsAdmin -AdminUser $AdminUser
            if (-not $isInAdmin) {
                Add-LocalGroupMember -Group "Administrators" -Member $AdminUser -ErrorAction Stop
                Write-Host "[OK] Added '$AdminUser' to Administrators group"
            }
            return $true
        }

        # Create new local user
        New-LocalUser -Name $AdminUser -Password $Password -Description "NextGPU bypass admin account" -PasswordNeverExpires -ErrorAction Stop
        Write-Host "[OK] Created local user '$AdminUser'"

        # Add to Administrators group
        Add-LocalGroupMember -Group "Administrators" -Member $AdminUser -ErrorAction Stop
        Write-Host "[OK] Added '$AdminUser' to Administrators group"

        return $true
    }
    catch {
        Write-Error "Failed to create user account: $_"
        return $false
    }
}

# StatusOnly mode - just check and report status, no credential storage needed
if ($StatusOnly) {
    $userExists = [bool](Test-NextGpuAdminUserExists)
    $isAdmin = [bool](Test-NextGpuAdminIsAdmin)
    $credExists = [bool](Test-NextGpuAdminCredentialExists)

    $result = @{
        UserExists = $userExists
        IsAdmin = $isAdmin
        CredExists = $credExists
    }

    Write-Output ($result | ConvertTo-Json -Compress)
    exit 0
}

try {
    # Only decrypt and store password if not StatusOnly
    if (-not $StatusOnly) {
        if ([string]::IsNullOrWhiteSpace($EncryptedPassword)) {
            throw "EncryptedPassword is required when not using -StatusOnly"
        }
        Write-Host "[DEBUG] Received EncryptedPassword length: $($EncryptedPassword.Length)"
        Write-Host "[DEBUG] Received EncryptedPassword prefix: $($EncryptedPassword.Substring(0, [Math]::Min(20, $EncryptedPassword.Length)))..."

        $protectedBytes = [Convert]::FromBase64String($EncryptedPassword)
        $decryptedBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protectedBytes,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $plainText = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
        $decryptedBytes = $null

        $secure = ConvertTo-SecureString $plainText -AsPlainText -Force
        $plainText = $null
    }
    else {
        $secure = $null
    }

    # Create user account if requested
    if ($CreateUser) {
        Write-Host "[INFO] Creating NextGPU-Admin user account..."
        $userCreated = New-NextGpuAdminUser -Password $secure
        if (-not $userCreated) {
            throw "Failed to create NextGPU-Admin user account"
        }
    }

    Set-NextGpuAdminCredential -Password $secure

    Write-Host "[OK] NextGPU-Admin password stored securely in $script:NextGpuAdminCredPath"
    exit 0
}
catch {
    Write-Error "Failed to store admin credential: $_"
    exit 1
}
