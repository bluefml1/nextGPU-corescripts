param(
    [string]$Username = 'nextGPU'
)

# ── Log setup ─────────────────────────────────────────────────
$LogPath = Join-Path $PSScriptRoot "UserReset_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message)

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] $Message"

    Add-Content -Path $LogPath -Value $LogMessage
    Write-Host $LogMessage
}

function Get-NextGpuRepoRootForUpdate {
    $markerPath = Join-Path $env:ProgramData 'nextGPU\repo-root.txt'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marked = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            if ($marked -and (Test-Path -LiteralPath (Join-Path $marked 'domain.txt'))) {
                return $marked
            }
        }
        catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $envRoot = $env:NEXTGPU_REPO_ROOT.Trim().TrimEnd('\')
        if (Test-Path -LiteralPath (Join-Path $envRoot 'domain.txt')) {
            return $envRoot
        }
    }

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady -or $drive.DriveType -ne 'Fixed') {
            continue
        }

        try {
            $domainFiles = Get-ChildItem -LiteralPath $drive.RootDirectory.FullName -Filter 'domain.txt' `
                -File -Recurse -Depth 6 -ErrorAction SilentlyContinue
            foreach ($domainFile in $domainFiles) {
                $repoRoot = $domainFile.Directory.FullName
                $batchPath = Join-Path $repoRoot 'scripts\runtime\checking-update.bat'
                if (Test-Path -LiteralPath $batchPath) {
                    return $repoRoot.TrimEnd('\')
                }
            }
        }
        catch { }
    }

    return $null
}

Write-Log "========================================="
Write-Log "Starting user reset process for '$Username'..."
Write-Log "========================================="

# ── STEP 1: Log off user if active ───────────────────────────
Write-Log "STEP 1: Checking active session for '$Username'..."

$session = (quser | Select-String $Username -ErrorAction SilentlyContinue)

if ($session) {
    $sessionId = ($session -split '\s+')[2]

    logoff $sessionId

    Write-Log "Logged off user '$Username' (Session ID: $sessionId)"

    Start-Sleep -Seconds 5
}
else {
    Write-Log "User '$Username' is not currently logged in."
}

# ── STEP 2: Delete user account ───────────────────────────────
Write-Log "STEP 2: Deleting user account '$Username'..."

try {
    Remove-LocalUser -Name $Username -ErrorAction Stop
    Write-Log "SUCCESS: User account '$Username' deleted."
}
catch {
    Write-Log "ERROR: Failed to delete user account: $_"
}

# ── STEP 3: Delete user profile ───────────────────────────────
Write-Log "STEP 3: Deleting user profile for '$Username'..."

try {
    $profile = Get-CimInstance -ClassName Win32_UserProfile |
        Where-Object { ($_.LocalPath -split '\\')[-1] -eq $Username }

    if ($profile) {
        $profile | Remove-CimInstance -ErrorAction Stop
        Write-Log "SUCCESS: User profile for '$Username' deleted."
    }
    else {
        Write-Log "INFO: No profile found for '$Username'."
    }
}
catch {
    Write-Log "ERROR: Failed to delete user profile: $_"
}

# ── STEP 4: Create fresh user (no password) ───────────────────
Write-Log "STEP 4: Creating fresh user account '$Username'..."

$result = net user $Username /add 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Log "SUCCESS: User account '$Username' created."
}
else {
    Write-Log "ERROR: Failed to create user account: $result"
    Write-Log "Aborting."
    exit 1
}

# ── STEP 5: Add to Users group ────────────────────────────────
Write-Log "STEP 5: Adding '$Username' to Users group..."

try {
    Add-LocalGroupMember -Group "Users" -Member $Username -ErrorAction Stop
    Write-Log "SUCCESS: User added to Users group."
}
catch {
    Write-Log "ERROR: Failed to add user to group: $_"
}

# ── STEP 5b: Add to NextGPURestricted group ─────────────────────
Write-Log "STEP 5b: Ensuring '$Username' is in NextGPURestricted group..."

$RepoRootForGroup = Get-NextGpuRepoRootForUpdate
$GroupHelperPs1 = if ($RepoRootForGroup) {
    Join-Path $RepoRootForGroup 'scripts\provisioning\Ensure-NextGpuRestrictedGroup.ps1'
} else {
    $null
}

if ($GroupHelperPs1 -and (Test-Path -LiteralPath $GroupHelperPs1)) {
    try {
        $groupResult = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass `
            -File $GroupHelperPs1 -UserName $Username 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "SUCCESS: NextGPURestricted group membership ensured for '$Username'."
        }
        else {
            Write-Log "ERROR: Ensure-NextGpuRestrictedGroup.ps1 failed (exit $LASTEXITCODE): $groupResult"
        }
    }
    catch {
        Write-Log "ERROR: Failed to run Ensure-NextGpuRestrictedGroup.ps1: $_"
    }
}
else {
    Write-Log "WARN: Ensure-NextGpuRestrictedGroup.ps1 not found (repo root: $RepoRootForGroup)."
}

# ── STEP 6: Set Autologon (no password) ───────────────────────
Write-Log "STEP 6: Setting autologon for '$Username'..."

$RegPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

try {
    Set-ItemProperty -Path $RegPath -Name "AutoAdminLogon"    -Value "1"       -Force
    Set-ItemProperty -Path $RegPath -Name "DefaultUserName"   -Value $Username -Force
    Set-ItemProperty -Path $RegPath -Name "DefaultPassword"   -Value ""        -Force
    Set-ItemProperty -Path $RegPath -Name "DefaultDomainName" -Value "."       -Force

    Write-Log "SUCCESS: Autologon configured for '$Username'."
}
catch {
    Write-Log "ERROR: Failed to set autologon: $_"
}

# ── STEP 7: Verify user ───────────────────────────────────────
Write-Log "STEP 7: Verifying user '$Username'..."

$verify = Get-LocalUser -Name $Username -ErrorAction SilentlyContinue

if ($verify) {
    Write-Log "SUCCESS: User '$Username' verified - ready for next session."
}
else {
    Write-Log "ERROR: User verification failed."
}

# ── STEP 8: Run checking-update.bat ───────────────────────────
Write-Log "STEP 8: Running checking-update.bat..."

$RepoRoot = Get-NextGpuRepoRootForUpdate
if ($RepoRoot) {
    Write-Log "Resolved nextGPU repo root: $RepoRoot"
    $BatchPath = Join-Path $RepoRoot 'scripts\runtime\checking-update.bat'
}
else {
    $BatchPath = $null
    Write-Log "ERROR: Could not resolve nextGPU repo root (repo-root.txt, NEXTGPU_REPO_ROOT, or domain.txt search)."
}

if ($BatchPath -and (Test-Path -LiteralPath $BatchPath)) {
    try {
        $cmdLine = "set `"NEXTGPU_REPO_ROOT=$RepoRoot`" && `"$BatchPath`""
        Start-Process -FilePath 'cmd.exe' `
            -ArgumentList '/c', $cmdLine `
            -WindowStyle Hidden

        Write-Log "SUCCESS: checking-update.bat started at: $BatchPath"
    }
    catch {
        Write-Log "ERROR: Failed to start checking-update.bat : $_"
    }
}
elseif ($BatchPath) {
    Write-Log "ERROR: checking-update.bat not found at: $BatchPath"
}
Write-Log "========================================="
Write-Log "Reset complete. Log saved to: $LogPath"
Write-Log "========================================="