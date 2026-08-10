# Steam-LibraryAcl.ps1
# Standalone NTFS ACL helpers for NextGPU Steam library rental (NextGPU-Admin).
#Requires -Version 5.1

function Test-IsSteamClientInstallPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path.TrimEnd('\')
    if ($p.Length -lt 3) { return $false }  # reject bare drive roots like Z:
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $p 'steam.exe')) -or
        (Test-Path -LiteralPath (Join-Path $p 'steamapps'))
}

function Get-SteamInstallPath {
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($hive in @(
            @{ Hive = 'HKLM'; Key = 'HKLM:\Software\Valve\Steam' },
            @{ Hive = 'HKCU'; Key = 'HKCU:\Software\Valve\Steam' }
        )) {
        try {
            $p = (Get-ItemProperty -LiteralPath $hive.Key -Name InstallPath -ErrorAction SilentlyContinue).InstallPath
            if ($p -and (Test-IsSteamClientInstallPath -Path $p)) {
                [void]$paths.Add([System.IO.Path]::GetFullPath($p.TrimEnd('\')))
            }
        } catch { }
    }
    if ($paths.Count -eq 0) { return $null }
    return @($paths | Sort-Object -Unique)[0]
}

function Read-SteamLibraryFolderPathsFromVdf {
    param([Parameter(Mandatory)][string]$VdfPath)

    if (-not (Test-Path -LiteralPath $VdfPath)) { return @() }
    $content = Get-Content -LiteralPath $VdfPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) { return @() }

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($content, '"path"\s+"([^"]+)"')) {
        $raw = $m.Groups[1].Value
        $raw = $raw -replace '\\\\', '\'
        [void]$found.Add($raw.TrimEnd('\'))
    }
    return @($found | Select-Object -Unique)
}

function ConvertTo-SteamLibraryRootPath {
    param([Parameter(Mandatory)][string]$Candidate)

    $p = $Candidate.TrimEnd('\')
    if (Test-Path -LiteralPath (Join-Path $p 'steamapps')) { return $p }
    if ($p -match '\\steamapps\\?$') { return (Split-Path -LiteralPath $p -Parent) }
    return $p
}

function Get-SteamLibraryRootsFromCommonFolders {
    $roots = New-Object System.Collections.Generic.List[string]
    try {
        $drives = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
            Where-Object { $_.Free -ge 0 } |
            ForEach-Object { $_.Root.TrimEnd('\') }
    } catch {
        $drives = @("$($env:SystemDrive.TrimEnd('\'))")
    }

    $suffixes = @(
        'SteamLibrary',
        'Steam'
    )
    foreach ($drive in $drives) {
        foreach ($suffix in $suffixes) {
            $candidate = Join-Path $drive $suffix
            $common = Join-Path (Join-Path $candidate 'steamapps') 'common'
            if (Test-Path -LiteralPath $common) {
                [void]$roots.Add([System.IO.Path]::GetFullPath($candidate))
            }
        }
    }
    return @($roots | Sort-Object -Unique)
}

function Resolve-SteamLibraryRoots {
    $roots = New-Object System.Collections.Generic.List[string]

    $install = Get-SteamInstallPath
    if ($install) {
        $installRoot = ConvertTo-SteamLibraryRootPath -Candidate $install
        if (Test-Path -LiteralPath (Join-Path $installRoot 'steamapps')) {
            [void]$roots.Add($installRoot)
        }
        foreach ($rel in @(
                (Join-Path $install 'config\libraryfolders.vdf'),
                (Join-Path $install 'steamapps\libraryfolders.vdf')
            )) {
            foreach ($pathEntry in (Read-SteamLibraryFolderPathsFromVdf -VdfPath $rel)) {
                $root = ConvertTo-SteamLibraryRootPath -Candidate $pathEntry
                if (Test-Path -LiteralPath (Join-Path $root 'steamapps')) {
                    [void]$roots.Add($root)
                }
            }
        }
    }

    foreach ($discovered in (Get-SteamLibraryRootsFromCommonFolders)) {
        [void]$roots.Add($discovered)
    }

    $unique = @(
        $roots |
            ForEach-Object {
                try { [System.IO.Path]::GetFullPath($_.TrimEnd('\')) }
                catch { $_.TrimEnd('\') }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_.Length -ge 3 } |
            Sort-Object -Unique
    )
    return $unique
}

function Get-SteamApprovedGameDirs {
    param(
        [Parameter(Mandatory)][string]$LibraryRoot
    )

    $common = Join-Path (Join-Path $LibraryRoot 'steamapps') 'common'
    if (-not (Test-Path -LiteralPath $common)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )
}

function Invoke-SteamLibraryIcacls {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$WhatIf
    )

    $quoted = foreach ($a in $Arguments) {
        if ($a -match '\s') { '"' + $a + '"' } else { $a }
    }
    Write-Host ('> icacls.exe ' + ($quoted -join ' '))

    if ($WhatIf) { return $true }

    # Native icacls writes failures to stderr; under $ErrorActionPreference=Stop that becomes terminating.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & icacls.exe @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prev
    }
    foreach ($line in @($output)) {
        $text = "$line"
        if ($text.Trim()) { Write-Host "  $text" }
    }
    return ($code -eq 0)
}

function Remove-SteamLibraryAdminAce {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AdminUser,
        [switch]$WhatIf
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    # Grant + deny ACEs (inherited denys need /inheritance:d first on child paths)
    $okG = Invoke-SteamLibraryIcacls -Arguments @($Path, '/remove:g', $AdminUser) -WhatIf:$WhatIf
    $okD = Invoke-SteamLibraryIcacls -Arguments @($Path, '/remove:d', $AdminUser) -WhatIf:$WhatIf
    return ($okG -or $okD -or $true)
}

function Clear-SteamLibraryAdminAceIncludingInherited {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AdminUser,
        [switch]$WhatIf
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    # Convert inherited ACEs to explicit so /remove can strip NextGPU-Admin DENY from common.
    $null = Invoke-SteamLibraryIcacls -Arguments @($Path, '/inheritance:d') -WhatIf:$WhatIf
    return (Remove-SteamLibraryAdminAce -Path $Path -AdminUser $AdminUser -WhatIf:$WhatIf)
}

function Remove-SteamLibraryRestrictedDeny {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RestrictedGroup = 'NextGPURestricted',
        [switch]$WhatIf
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    # Explicit deny only (call after /inheritance:d when ACE was inherited).
    return (Invoke-SteamLibraryIcacls -Arguments @($Path, '/remove:d', $RestrictedGroup) -WhatIf:$WhatIf)
}

function Ensure-NextGpuAdminNotInRestrictedGroup {
    <#
    .SYNOPSIS
        NextGPU-Admin (and builtin Authority) must NOT be in NextGPURestricted.
        Restricted DENY(DE,DC) beats Full Control — Steam updates fail with "Missing file privileges".
    #>
    param(
        [string]$AdminUser = 'NextGPU-Admin',
        [string]$RestrictedGroup = 'NextGPURestricted',
        [switch]$WhatIf
    )

    $toRemove = @($AdminUser, 'NextGPU-Authority')
    $group = Get-LocalGroup -Name $RestrictedGroup -ErrorAction SilentlyContinue
    if (-not $group) {
        Write-Host "Group '$RestrictedGroup' not present; skip membership fix."
        return $true
    }

    $ok = $true
    foreach ($name in $toRemove) {
        $user = Get-LocalUser -Name $name -ErrorAction SilentlyContinue
        if (-not $user) { continue }
        $members = @(Get-LocalGroupMember -Group $RestrictedGroup -ErrorAction SilentlyContinue)
        $hit = $members | Where-Object { $_.SID -eq $user.SID -or $_.Name -like "*\$name" }
        if (-not $hit) {
            Write-Host "'$name' is not in '$RestrictedGroup'."
            continue
        }
        Write-Host "Removing '$name' from '$RestrictedGroup' (required for Steam update delete/replace)..."
        if ($WhatIf) { continue }
        try {
            Remove-LocalGroupMember -Group $RestrictedGroup -Member $name -ErrorAction Stop
            Write-Host "  Removed '$name' from '$RestrictedGroup'."
        }
        catch {
            Write-Host "  FAILED removing '$name' from '$RestrictedGroup': $_"
            $ok = $false
        }
    }
    return $ok
}

function Prepare-SteamLibraryWriteDir {
    <#
    .SYNOPSIS
        Break inherit, strip NextGPU-Admin + NextGPURestricted DENY, ready for grant.
        Restricted deny-delete must not remain on Steam write paths when Admin was in that group.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AdminUser,
        [string]$RestrictedGroup = 'NextGPURestricted',
        [switch]$WhatIf
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    $null = Invoke-SteamLibraryIcacls -Arguments @($Path, '/inheritance:d') -WhatIf:$WhatIf
    Remove-SteamLibraryAdminAce -Path $Path -AdminUser $AdminUser -WhatIf:$WhatIf | Out-Null
    Remove-SteamLibraryRestrictedDeny -Path $Path -RestrictedGroup $RestrictedGroup -WhatIf:$WhatIf | Out-Null
    return $true
}

function Repair-SteamGameDirChildInheritance {
    <#
    .SYNOPSIS
        Keep game-folder root blocked from common inherit, but force all children
        to inherit Admin Full Control from that game folder (fix empty/orphan DACLs).
        Also DENY delete on the game folder object itself (NP only) so Admin cannot
        remove the install directory, while children keep Delete for Steam file replace.
    #>
    param(
        [Parameter(Mandatory)][string]$GameDir,
        [Parameter(Mandatory)][string]$AdminUser,
        [switch]$WhatIf
    )

    if (-not (Test-Path -LiteralPath $GameDir)) { return $true }

    Write-Host "  Restoring child inheritance from game folder (root stays non-inheriting from common)..."
    # Explicit Full on root with OI/CI so /reset children pick it up.
    if (-not (Invoke-SteamLibraryIcacls -Arguments @($GameDir, '/grant:r', "${AdminUser}:(OI)(CI)(F)") -WhatIf:$WhatIf)) {
        return $false
    }

    if ($WhatIf) { return $true }

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $children = @(Get-ChildItem -LiteralPath $GameDir -Force -ErrorAction SilentlyContinue)
        foreach ($child in $children) {
            # /reset /T: replace broken explicit/empty DACLs with inherit-from-parent (this game folder).
            # Do NOT /reset the game folder itself - that would re-inherit common DENYs.
            $null = & icacls.exe $child.FullName '/reset' '/T' '/C' '/Q' 2>&1
        }

        # Still apply explicit-propagating grant for containers that kept inheritance off.
        $null = & icacls.exe $GameDir '/grant:r' "${AdminUser}:(OI)(CI)(F)" '/T' '/C' '/Q' 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  takeown + reset retry for incomplete tree..."
            $null = & takeown.exe /F $GameDir /R /D Y 2>&1
            foreach ($child in $children) {
                $null = & icacls.exe $child.FullName '/reset' '/T' '/C' '/Q' 2>&1
            }
            $null = & icacls.exe $GameDir '/grant:r' "${AdminUser}:(OI)(CI)(F)" '/T' '/C' '/Q' 2>&1
        }
    }
    finally {
        $ErrorActionPreference = $prev
    }

    # After /T grant: re-assert root F, then DENY delete on THIS folder only (no inherit).
    # DENY beats Allow - Admin can update/replace files inside, but cannot delete the game directory.
    if (-not (Invoke-SteamLibraryIcacls -Arguments @($GameDir, '/grant:r', "${AdminUser}:(OI)(CI)(F)") -WhatIf:$WhatIf)) {
        return $false
    }
    Write-Host "  DENY delete on game folder only (NP) - protect install dir..."
    if (-not (Invoke-SteamLibraryIcacls -Arguments @($GameDir, '/deny', "${AdminUser}:(NP)(DE)") -WhatIf:$WhatIf)) {
        return $false
    }

    return $true
}

function Grant-SteamLibraryAdminAcl {
    param(
        [Parameter(Mandatory)][string]$LibraryRoot,
        [Parameter(Mandatory)][string]$AdminUser = 'NextGPU-Admin',
        [string[]]$ApprovedDirs,
        [switch]$WhatIf
    )

    $LibraryRoot = $LibraryRoot.TrimEnd('\')
    $steamApps = Join-Path $LibraryRoot 'steamapps'
    $common = Join-Path $steamApps 'common'
    $downloading = Join-Path $steamApps 'downloading'
    $temp = Join-Path $steamApps 'temp'
    $workshop = Join-Path $steamApps 'workshop'

    if (-not (Test-Path -LiteralPath $steamApps)) {
        Write-Host "steamapps folder missing under $LibraryRoot"
        return $false
    }

    if (-not $ApprovedDirs -or $ApprovedDirs.Count -eq 0) {
        $ApprovedDirs = Get-SteamApprovedGameDirs -LibraryRoot $LibraryRoot
    }

    $ok = $true

    Write-Host "Grant-SteamLibraryAdminAcl: library root $LibraryRoot"
    if (-not (Ensure-NextGpuAdminNotInRestrictedGroup -AdminUser $AdminUser -WhatIf:$WhatIf)) {
        $ok = $false
    }

    if (Test-Path -LiteralPath $common) {
        Write-Host 'Applying common folder policy (RX inherit + deny create ON common only, no inherit into games)...'
        Remove-SteamLibraryAdminAce -Path $common -AdminUser $AdminUser -WhatIf:$WhatIf | Out-Null
        # Keep NextGPURestricted on common (rental: no delete new install folders as restricted users).
        # RX may inherit into game dirs (OK alongside Full on games).
        if (-not (Invoke-SteamLibraryIcacls -Arguments @($common, '/grant:r', "${AdminUser}:(OI)(CI)(RX)") -WhatIf:$WhatIf)) { $ok = $false }
        # DENY create folder/file ONLY on common itself - do NOT use (CI)/(OI) or denys poison game folders.
        if (-not (Invoke-SteamLibraryIcacls -Arguments @($common, '/deny', "${AdminUser}:(AD)") -WhatIf:$WhatIf)) { $ok = $false }
        if (-not (Invoke-SteamLibraryIcacls -Arguments @($common, '/deny', "${AdminUser}:(WD)") -WhatIf:$WhatIf)) { $ok = $false }
    } else {
        Write-Host "Warning: common folder not found: $common"
    }

    foreach ($gameDir in $ApprovedDirs) {
        if (-not (Test-Path -LiteralPath $gameDir)) { continue }
        Write-Host "Granting Full Control + child inherit on approved game dir: $gameDir"
        Prepare-SteamLibraryWriteDir -Path $gameDir -AdminUser $AdminUser -WhatIf:$WhatIf | Out-Null
        if (-not (Repair-SteamGameDirChildInheritance -GameDir $gameDir -AdminUser $AdminUser -WhatIf:$WhatIf)) {
            $ok = $false
        }
    }

    foreach ($dirSpec in @(
            @{ Name = 'downloading'; Path = $downloading },
            @{ Name = 'temp'; Path = $temp }
        )) {
        if (-not (Test-Path -LiteralPath $dirSpec.Path)) {
            Write-Host "Creating steamapps\$($dirSpec.Name)..."
            if (-not $WhatIf) {
                New-Item -ItemType Directory -Path $dirSpec.Path -Force | Out-Null
            }
        }
        Write-Host "Granting Modify on steamapps\$($dirSpec.Name) (strip Restricted DENY)..."
        Prepare-SteamLibraryWriteDir -Path $dirSpec.Path -AdminUser $AdminUser -WhatIf:$WhatIf | Out-Null
        if (-not (Invoke-SteamLibraryIcacls -Arguments @($dirSpec.Path, '/grant:r', "${AdminUser}:(OI)(CI)M") -WhatIf:$WhatIf)) { $ok = $false }
    }

    if (Test-Path -LiteralPath $workshop) {
        Write-Host 'Granting Modify on steamapps\workshop (strip Restricted DENY)...'
        Prepare-SteamLibraryWriteDir -Path $workshop -AdminUser $AdminUser -WhatIf:$WhatIf | Out-Null
        if (-not (Invoke-SteamLibraryIcacls -Arguments @($workshop, '/grant:r', "${AdminUser}:(OI)(CI)M") -WhatIf:$WhatIf)) { $ok = $false }
    }

    Write-Host 'Granting Modify on steamapps (strip Restricted DENY; this folder only, not /T)...'
    Prepare-SteamLibraryWriteDir -Path $steamApps -AdminUser $AdminUser -WhatIf:$WhatIf | Out-Null
    if (-not (Invoke-SteamLibraryIcacls -Arguments @($steamApps, '/grant:r', "${AdminUser}:(OI)(CI)M") -WhatIf:$WhatIf)) { $ok = $false }

    return $ok
}

function Revoke-SteamLibraryAdminAcl {
    <#
    .SYNOPSIS
        Remove all NextGPU-Admin ACEs previously applied by Grant-SteamLibraryAdminAcl
        (including Full Control on game dirs and non-inheriting deny on common).
        Does not change Users / NextGPURestricted / Administrators ACLs.
    #>
    param(
        [Parameter(Mandatory)][string]$LibraryRoot,
        [Parameter(Mandatory)][string]$AdminUser = 'NextGPU-Admin',
        [switch]$WhatIf
    )

    $LibraryRoot = $LibraryRoot.TrimEnd('\')
    $steamApps = Join-Path $LibraryRoot 'steamapps'
    $common = Join-Path $steamApps 'common'
    $downloading = Join-Path $steamApps 'downloading'
    $temp = Join-Path $steamApps 'temp'
    $workshop = Join-Path $steamApps 'workshop'

    Write-Host "Revoke-SteamLibraryAdminAcl: library root $LibraryRoot (user=$AdminUser)"

    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($p in @($steamApps, $common, $downloading, $temp, $workshop)) {
        if (Test-Path -LiteralPath $p) { [void]$paths.Add($p) }
    }
    foreach ($gameDir in @(Get-SteamApprovedGameDirs -LibraryRoot $LibraryRoot)) {
        [void]$paths.Add($gameDir)
    }

    $ok = $true
    foreach ($path in $paths) {
        Write-Host "Removing $AdminUser ACEs from: $path"
        if (-not (Remove-SteamLibraryAdminAce -Path $path -AdminUser $AdminUser -WhatIf:$WhatIf)) {
            # Also try grant-only / deny-only remove variants
            $null = Invoke-SteamLibraryIcacls -Arguments @($path, '/remove:g', $AdminUser) -WhatIf:$WhatIf
            $null = Invoke-SteamLibraryIcacls -Arguments @($path, '/remove:d', $AdminUser) -WhatIf:$WhatIf
            if (-not (Remove-SteamLibraryAdminAce -Path $path -AdminUser $AdminUser -WhatIf:$WhatIf)) {
                Write-Host "WARN: could not fully remove $AdminUser from $path"
                $ok = $false
            }
        }
    }

    return $ok
}

function Unlock-SteamLibraryFoldersVdf {
    param(
        [Parameter(Mandatory)][string]$SteamInstallPath,
        [Parameter(Mandatory)][string]$AdminUser = 'NextGPU-Admin',
        [switch]$WhatIf
    )

    $SteamInstallPath = $SteamInstallPath.TrimEnd('\')
    $vdf = Join-Path $SteamInstallPath 'config\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) {
        Write-Host "libraryfolders.vdf not found: $vdf"
        return $true
    }

    Write-Host "Removing $AdminUser ACEs from $vdf"
    $ok = Remove-SteamLibraryAdminAce -Path $vdf -AdminUser $AdminUser -WhatIf:$WhatIf
    if (-not $ok) {
        $null = Invoke-SteamLibraryIcacls -Arguments @($vdf, '/remove:d', $AdminUser) -WhatIf:$WhatIf
        $null = Invoke-SteamLibraryIcacls -Arguments @($vdf, '/remove:g', $AdminUser) -WhatIf:$WhatIf
        $ok = $true
    }
    return $ok
}

function Lock-SteamLibraryFoldersVdf {
    param(
        [Parameter(Mandatory)][string]$SteamInstallPath,
        [Parameter(Mandatory)][string]$AdminUser = 'NextGPU-Admin',
        [switch]$WhatIf
    )

    $SteamInstallPath = $SteamInstallPath.TrimEnd('\')
    $vdf = Join-Path $SteamInstallPath 'config\libraryfolders.vdf'
    if (-not (Test-Path -LiteralPath $vdf)) {
        Write-Host "libraryfolders.vdf not found: $vdf"
        return $false
    }

    Write-Host "Locking write access for $AdminUser on $vdf"
    Remove-SteamLibraryAdminAce -Path $vdf -AdminUser $AdminUser -WhatIf:$WhatIf | Out-Null
    return (Invoke-SteamLibraryIcacls -Arguments @($vdf, '/deny', "${AdminUser}:(W)") -WhatIf:$WhatIf)
}

function Get-SteamLibraryIcaclsSummary {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AdminUser
    )

    if (-not (Test-Path -LiteralPath $Path)) { return '(missing)' }
    $out = (& icacls.exe $Path 2>&1 | Out-String)
    $line = ($out -split "`n" | Where-Object { $_ -match [regex]::Escape($AdminUser) } | Select-Object -First 1)
    if ($line) { return $line.Trim() }
    return '(no ACE for user)'
}

function Test-SteamLibraryAdminAcl {
    param(
        [Parameter(Mandatory)][string]$LibraryRoot,
        [Parameter(Mandatory)][string]$AdminUser = 'NextGPU-Admin'
    )

    $LibraryRoot = $LibraryRoot.TrimEnd('\')
    $steamApps = Join-Path $LibraryRoot 'steamapps'
    $common = Join-Path $steamApps 'common'

    $lines = New-Object System.Collections.Generic.List[string]
    [void]$lines.Add("LibraryRoot: $LibraryRoot")
    [void]$lines.Add("  steamapps: $(Get-SteamLibraryIcaclsSummary -Path $steamApps -AdminUser $AdminUser)")
    [void]$lines.Add("  common:    $(Get-SteamLibraryIcaclsSummary -Path $common -AdminUser $AdminUser)")

    $approved = Get-SteamApprovedGameDirs -LibraryRoot $LibraryRoot
    [void]$lines.Add("  approved game dirs: $($approved.Count)")
    foreach ($g in ($approved | Select-Object -First 5)) {
        [void]$lines.Add("    $g -> $(Get-SteamLibraryIcaclsSummary -Path $g -AdminUser $AdminUser)")
    }
    if ($approved.Count -gt 5) {
        [void]$lines.Add("    ... and $($approved.Count - 5) more")
    }

    return ($lines -join [Environment]::NewLine)
}

