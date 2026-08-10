#Requires -Version 5.1

$script:_moduleRoot = $PSScriptRoot

function Test-PathIsDirectoryJunction {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

$script:PlayniteSteamPluginId = "CB91DFC9-B977-43BF-8E70-55F46E410FAB"
$script:PlayniteEpicPluginId = "00000002-DBD1-46C6-B5D0-B1BA559D10E4"
$script:PlayniteManualPluginId = "00000000-0000-0000-0000-000000000000"
$script:DesktopAppAllowlistFileName = "desktop-apps.allowlist.json"
# Used only when directory-walking the system/boot drive (e.g. C:\). Not applied to es.exe hits on other drives.
$script:DesktopScanSkipDirNames = @(
    'Windows', '$Recycle.Bin', 'node_modules', 'AppData', 'Packages',
    'Microsoft', 'WinSxS', 'System Volume Information'
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:PlayniteRentalAccessGroup = 'BUILTIN\Users'
$script:PlayniteRentalAdminGroup = 'BUILTIN\Administrators'

function Write-PlayniteRentalAccessLog {
    param(
        [string]$Message,
        [string]$Level = 'INFO',
        [scriptblock]$LogAction
    )

    if ($LogAction) {
        & $LogAction $Message $Level
        return
    }
    Write-Verbose $Message
}

function Grant-PlayniteRentalAccess {
    <#
        Grant BUILTIN\Users Modify on the portable Playnite install folder.
        Works in two passes: (1) Admin Full Control cascades via normal inheritance to
        all existing subfolders/files, then (2) inheritance is broken on the root and
        Users Modify is granted there — (OI)(CI) propagates it to future objects.
        This avoids icacls /T cascading into deep subfolders that may hold rental DENY
        ACEs (which would cause /inheritance:r to fail mid-tree).
        Requires an elevated session (icacls).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    $normalized = Expand-PlayniteInstallDirectory -Path $InstallDir
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        Write-PlayniteRentalAccessLog "Playnite install path is empty: $InstallDir" 'ERROR' $LogAction
        return $false
    }

    # Guard against bare drive roots (e.g. "Z:").  Get-NormalizedDirectoryPath returns
    # the drive root when Test-Path fails because the ACL prevents enumeration.  Running
    # icacls /T on a drive root cascades /inheritance:r down the entire volume, wiping
    # inheritance on every file and locking out all users including Administrator.
    if ($normalized -match '^[A-Za-z]:\\?$') {
        Write-PlayniteRentalAccessLog "Rejecting bare drive root as install path: $normalized. Supply the Playnite subfolder path (e.g. Z:\Playnite)." 'ERROR' $LogAction
        return $false
    }

    if (-not (Test-Path -LiteralPath $normalized)) {
        Write-PlayniteRentalAccessLog "Playnite install folder not found: $InstallDir" 'ERROR' $LogAction
        return $false
    }

    $null = Get-PlayniteDesktopExe -InstallDir $normalized

    if (-not (Test-IsAdministrator)) {
        Write-PlayniteRentalAccessLog 'Grant-PlayniteRentalAccess requires Administrator (elevated setup).' 'WARN' $LogAction
        return $false
    }

    Write-PlayniteRentalAccessLog "Granting rental access on Playnite folder: $normalized" 'INFO' $LogAction

    $ok = $true
    $usersGrant = "${script:PlayniteRentalAccessGroup}:(OI)(CI)M"
    $adminGrant = "${script:PlayniteRentalAdminGroup}:(OI)(CI)F"

    # Step 1: Grant Administrators Full Control on the folder root (no /T).
    # Because /T is omitted this succeeds even if deep subfolders have rental DENY
    # ACEs — it only touches the root.  Admin Full Control is inherited by every
    # existing subfolder/file under the root automatically via normal inheritance.
    & icacls.exe $normalized /grant:r $adminGrant 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    # Step 2: Break inheritance on the folder root only (no /T).  Breaking only
    # the root avoids cascading into files that may have rental DENY ACEs, which
    # would cause icacls /T /inheritance:r to abort mid-tree and leave some files
    # without proper ACLs.
    & icacls.exe $normalized /inheritance:r 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    # Step 3: Grant Users Modify on the folder root (no /T).  (OI)(CI) in the
    # ACE string means newly created subfolders/files inherit Modify automatically.
    & icacls.exe $normalized /grant:r $usersGrant 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    # Step 4: Re-apply Admin Full Control on the folder root (no /T).  After step 2
    # broke inheritance, this re-grants Admin access to the root itself.  (Subfolders
    # and files already have Admin via the inherit chain from step 1.)
    & icacls.exe $normalized /grant:r $adminGrant 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { $ok = $false }

    if ($ok) {
        Write-PlayniteRentalAccessLog "Rental ACL applied ($usersGrant; $adminGrant)." 'INFO' $LogAction
    }
    else {
        Write-PlayniteRentalAccessLog 'One or more icacls steps failed on Playnite install folder.' 'ERROR' $LogAction
    }

    return $ok
}

function Test-PlayniteRentalAccess {
    <#
        True when the current user can write and delete under the portable Playnite install folder.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir
    )

    $normalized = Expand-PlayniteInstallDirectory -Path $InstallDir
    if ([string]::IsNullOrWhiteSpace($normalized) -or -not (Test-Path -LiteralPath $normalized)) {
        return $false
    }

    $probePath = Join-Path $normalized '.nextgpu-acl-probe'
    try {
        [System.IO.File]::WriteAllText($probePath, 'ok')
        Remove-Item -LiteralPath $probePath -Force -ErrorAction Stop
        return $true
    }
    catch {
        if (Test-Path -LiteralPath $probePath) {
            Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

Export-ModuleMember -Function *
