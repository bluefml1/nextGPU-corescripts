#Requires -Version 5.1
<#
.SYNOPSIS
    Shared credential storage functions for NextGPU-Admin password.
    Uses DPAPI to encrypt credentials at rest.
    New stores use LocalMachine scope so SYSTEM (Sunshine endSession) can decrypt.
    Get tries LocalMachine first, then CurrentUser for older admincred.dat files.
    Call . (dot-source) this file in scripts that need to access the admin password.
#>

Add-Type -AssemblyName System.Security

$script:NextGpuAdminCredPath = Join-Path $env:ProgramData "nextGPU\admincred.dat"

function Get-NextGpuAdminCredential {
    <#
    .SYNOPSIS
        Retrieves the NextGPU-Admin credential from secure storage.
    .OUTPUTS
        PSCredential or $null if not found or inaccessible.
    .EXAMPLE
        $cred = Get-NextGpuAdminCredential
        if ($cred) { ... }
    #>
    param(
        [string]$AdminUser = "NextGPU-Admin",
        [switch]$AllowPrompt,
        [switch]$Silent
    )

    if (Test-Path -LiteralPath $script:NextGpuAdminCredPath) {
        $protected = $null
        try {
            $protected = [System.IO.File]::ReadAllBytes($script:NextGpuAdminCredPath)
        }
        catch {
            if (-not $Silent) {
                Write-Warning "Failed to read stored admin password file: $($_.Exception.Message)"
            }
            $protected = $null
        }

        if ($protected) {
            $scopes = @(
                [System.Security.Cryptography.DataProtectionScope]::LocalMachine,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            $lastError = $null
            foreach ($scope in $scopes) {
                try {
                    $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
                        $protected,
                        $null,
                        $scope
                    )
                    $plainText = [System.Text.Encoding]::UTF8.GetString($decrypted)
                    $secure = ConvertTo-SecureString $plainText -AsPlainText -Force
                    return New-Object PSCredential($AdminUser, $secure)
                }
                catch {
                    $lastError = $_
                }
            }

            if (-not $Silent -and $lastError) {
                Write-Warning "Failed to decrypt stored admin password: $($lastError.Exception.Message)"
            }
        }
    }

    if ($AllowPrompt) {
        $cred = Get-Credential -UserName $AdminUser -Message `
            "NextGPU-Admin password. Stored securely after initial setup."
        return $cred
    }

    return $null
}

function Set-NextGpuAdminCredential {
    <#
    .SYNOPSIS
        Stores the NextGPU-Admin password securely using DPAPI.
        The credential is encrypted with the current Windows user's key.
    .EXAMPLE
        Set-NextGpuAdminCredential -Password $securePassword
    #>
    param(
        [Parameter(Mandatory)]
        [SecureString]$Password
    )

    $storageDir = Split-Path -Parent $script:NextGpuAdminCredPath
    if (-not (Test-Path -LiteralPath $storageDir)) {
        New-Item -ItemType Directory -Path $storageDir -Force | Out-Null
    }

    $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainText = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($ptr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($plainText)
    $plainText = $null

    # LocalMachine so Sunshine endSession (often NT AUTHORITY\SYSTEM) can decrypt.
    $protected = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )
    $bytes = $null

    [System.IO.File]::WriteAllBytes($script:NextGpuAdminCredPath, $protected)

    $acl = Get-Acl $script:NextGpuAdminCredPath
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        "SYSTEM", "FullControl", "Allow")))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
        "Administrators", "FullControl", "Allow")))
    Set-Acl -Path $script:NextGpuAdminCredPath -AclObject $acl
}

function Test-NextGpuAdminCredentialExists {
    <#
    .SYNOPSIS
        Checks if a stored NextGPU-Admin credential exists.
    .OUTPUTS
        $true if credential file exists, $false otherwise.
    #>
    return Test-Path -LiteralPath $script:NextGpuAdminCredPath
}

function Remove-NextGpuAdminCredential {
    <#
    .SYNOPSIS
        Removes the stored NextGPU-Admin credential.
        Use with caution - this cannot be undone without a backup.
    #>
    if (Test-Path -LiteralPath $script:NextGpuAdminCredPath) {
        Remove-Item -LiteralPath $script:NextGpuAdminCredPath -Force
    }
}
