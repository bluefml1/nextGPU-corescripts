#Requires -Version 5.1
<#
.SYNOPSIS
    Shared credential storage functions for NextGPU-Admin password.
    Uses DPAPI to encrypt credentials at rest.
    New stores use LocalMachine scope so SYSTEM (Sunshine endSession) can decrypt.
    File ACL: SYSTEM + Administrators allow; nextGPU explicit FullControl deny.
    Get tries LocalMachine first, then CurrentUser for older admincred.dat files.
    Call . (dot-source) this file in scripts that need to access the admin password.
#>

Add-Type -AssemblyName System.Security

$script:NextGpuAdminCredPath = Join-Path $env:ProgramData "nextGPU\admincred.dat"
$script:NextGpuRentalAccountName = 'nextGPU'

function Get-NextGpuRentalAccountSid {
    <#
    .SYNOPSIS
        SID of the rental nextGPU account, or $null when the user does not exist.
    #>
    try {
        $user = Get-LocalUser -Name $script:NextGpuRentalAccountName -ErrorAction Stop
        return [System.Security.Principal.SecurityIdentifier]$user.SID.Value
    }
    catch {
        return $null
    }
}

function Set-NextGpuAdminCredFileAcl {
    <#
    .SYNOPSIS
        Locks admincred.dat to SYSTEM + Administrators, with explicit DENY for nextGPU.
    .DESCRIPTION
        Inheritance disabled. Rental user gets FullControl Deny (read/write/execute/delete).
        Re-run after nextGPU delete/recreate so the deny ACE targets the new SID.
    #>
    param(
        [string]$Path = $script:NextGpuAdminCredPath,
        [switch]$Silent
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $Silent) {
            Write-Warning "admincred.dat not found: $Path"
        }
        return $false
    }

    $inheritNone = [System.Security.AccessControl.InheritanceFlags]::None
    $propNone = [System.Security.AccessControl.PropagationFlags]::None
    $fullControl = [System.Security.AccessControl.FileSystemRights]::FullControl

    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)

    foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            $fullControl,
            $inheritNone,
            $propNone,
            [System.Security.AccessControl.AccessControlType]::Allow)))
    }

    $rentalSid = Get-NextGpuRentalAccountSid
    if ($rentalSid) {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $rentalSid,
            $fullControl,
            $inheritNone,
            $propNone,
            [System.Security.AccessControl.AccessControlType]::Deny)))
    }
    elseif (-not $Silent) {
        Write-Warning "Local user '$($script:NextGpuRentalAccountName)' not found; admincred.dat ACL has no rental deny yet."
    }

    Set-Acl -LiteralPath $Path -AclObject $acl

    if (-not $Silent -and $rentalSid) {
        Write-Host "[OK] admincred.dat ACL: SYSTEM + Administrators allow; $($script:NextGpuRentalAccountName) deny."
    }

    return $true
}

function Update-NextGpuAdminCredRentalDenyAcl {
    <#
    .SYNOPSIS
        Re-apply admincred.dat deny ACE for the current nextGPU SID (after recreate).
    .DESCRIPTION
        Call after nextGPU is created or recreated — not from user-storage Sync.
    #>
    param([switch]$Silent)

    if (-not (Test-Path -LiteralPath $script:NextGpuAdminCredPath)) {
        return $false
    }

    return (Set-NextGpuAdminCredFileAcl -Path $script:NextGpuAdminCredPath -Silent:$Silent)
}

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

function Test-NextGpuAdminCredentialLocalMachine {
    <#
    .SYNOPSIS
        Returns $true if admincred.dat decrypts with LocalMachine DPAPI (SYSTEM-readable).
    #>
    if (-not (Test-Path -LiteralPath $script:NextGpuAdminCredPath)) {
        return $false
    }

    try {
        $protected = [System.IO.File]::ReadAllBytes($script:NextGpuAdminCredPath)
        $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $protected,
            $null,
            [System.Security.Cryptography.DataProtectionScope]::LocalMachine
        )
        $ok = ($null -ne $decrypted -and $decrypted.Length -gt 0)
        if ($decrypted) { [Array]::Clear($decrypted, 0, $decrypted.Length) }
        return $ok
    }
    catch {
        return $false
    }
}

function Set-NextGpuAdminCredential {
    <#
    .SYNOPSIS
        Stores the NextGPU-Admin password using LocalMachine DPAPI so SYSTEM can decrypt.
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

    $null = Set-NextGpuAdminCredFileAcl -Silent
}

function Repair-NextGpuAdminCredentialToLocalMachine {
    <#
    .SYNOPSIS
        Re-encrypts admincred.dat as LocalMachine DPAPI.
        Run as an Administrator who can decrypt the current blob (often CurrentUser).
        SYSTEM / EndSession cannot do this when the blob is CurrentUser-only.
    .OUTPUTS
        $true if LocalMachine decrypt works after repair (or already did).
    #>
    param(
        [string]$AdminUser = "NextGPU-Admin",
        [switch]$Force
    )

    if (-not $Force -and (Test-NextGpuAdminCredentialLocalMachine)) {
        $null = Set-NextGpuAdminCredFileAcl -Silent
        Write-Host "[OK] admincred.dat already decrypts with LocalMachine DPAPI (ACL refreshed)."
        return $true
    }

    $cred = Get-NextGpuAdminCredential -AdminUser $AdminUser
    if (-not $cred) {
        Write-Warning "Cannot decrypt admincred.dat as this user. Re-run Bypass admin password setup, then Store-NextGpuAdminCredential.ps1 -Repair if needed."
        return $false
    }

    $len = $cred.GetNetworkCredential().Password.Length
    if ($len -lt 1) {
        Write-Warning "Decrypted password is empty; refusing to rewrite admincred.dat."
        return $false
    }

    Set-NextGpuAdminCredential -Password $cred.Password

    if (Test-NextGpuAdminCredentialLocalMachine) {
        Write-Host "[OK] Rewrote $($script:NextGpuAdminCredPath) as LocalMachine DPAPI (SYSTEM can decrypt)."
        return $true
    }

    Write-Warning "Rewrite completed but LocalMachine decrypt check failed."
    return $false
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
