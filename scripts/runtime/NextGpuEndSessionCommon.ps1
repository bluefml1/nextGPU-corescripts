#Requires -Version 5.1
<#
.SYNOPSIS
    Shared EndSession pending-flag / vendor_id helpers for EndSession and AtStartup recovery.
#>

$script:NextGpuProgramDataDir = Join-Path $env:ProgramData 'nextGPU'
$script:NextGpuVendorIdPath = Join-Path $script:NextGpuProgramDataDir 'vendor-id.txt'
$script:NextGpuEndSessionPendingFlagPath = Join-Path $script:NextGpuProgramDataDir 'endsession-reset-pending.flag'

function Get-NextGpuVendorId {
    <#
    .SYNOPSIS
        Returns trimmed vendor_id or $null.
    #>
    if (Test-Path -LiteralPath $script:NextGpuVendorIdPath) {
        try {
            $v = (Get-Content -LiteralPath $script:NextGpuVendorIdPath -Raw -ErrorAction Stop).Trim()
            if (-not [string]::IsNullOrWhiteSpace($v)) {
                return $v
            }
        }
        catch { }
    }

    # Fallback: domain.txt VENDOR_ID= (repo or ProgramData copy)
    $domainCandidates = @(
        (Join-Path $script:NextGpuProgramDataDir 'domain.txt')
    )
    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $domainCandidates += (Join-Path $env:NEXTGPU_REPO_ROOT.TrimEnd('\') 'domain.txt')
    }
    $marker = Join-Path $script:NextGpuProgramDataDir 'repo-root.txt'
    if (Test-Path -LiteralPath $marker) {
        try {
            $root = (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            if ($root) { $domainCandidates += (Join-Path $root 'domain.txt') }
        }
        catch { }
    }

    foreach ($domainPath in $domainCandidates) {
        if (-not (Test-Path -LiteralPath $domainPath)) { continue }
        try {
            foreach ($line in Get-Content -LiteralPath $domainPath -ErrorAction Stop) {
                if ($line -match '^\s*VENDOR_ID\s*=\s*(.+)\s*$') {
                    $v = $Matches[1].Trim().Trim('"')
                    if (-not [string]::IsNullOrWhiteSpace($v)) {
                        return $v
                    }
                }
            }
        }
        catch { }
    }

    # Fallback: register-machine-ui-config.json (already-registered hosts)
    $uiConfigs = @()
    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $uiConfigs += (Join-Path $env:NEXTGPU_REPO_ROOT.TrimEnd('\') 'logs\register-machine-ui-config.json')
    }
    if (Test-Path -LiteralPath $marker) {
        try {
            $root = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim().TrimEnd('\')
            if ($root) {
                $uiConfigs += (Join-Path $root 'logs\register-machine-ui-config.json')
            }
        }
        catch { }
    }

    foreach ($cfg in $uiConfigs) {
        if (-not (Test-Path -LiteralPath $cfg)) { continue }
        try {
            $json = Get-Content -LiteralPath $cfg -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $json.vendorId) {
                $v = [string]$json.vendorId
                if (-not [string]::IsNullOrWhiteSpace($v)) {
                    return $v.Trim()
                }
            }
        }
        catch { }
    }

    return $null
}

function Test-NextGpuHasVendorId {
    return -not [string]::IsNullOrWhiteSpace((Get-NextGpuVendorId))
}

function Set-NextGpuVendorId {
    param([string]$VendorId)

    if (-not (Test-Path -LiteralPath $script:NextGpuProgramDataDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuProgramDataDir -Force | Out-Null
    }

    $trimmed = if ($null -eq $VendorId) { '' } else { $VendorId.Trim() }
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        if (Test-Path -LiteralPath $script:NextGpuVendorIdPath) {
            Remove-Item -LiteralPath $script:NextGpuVendorIdPath -Force -ErrorAction SilentlyContinue
        }
        return
    }

    Set-Content -LiteralPath $script:NextGpuVendorIdPath -Value $trimmed -Encoding ASCII -Force
}

function Get-NextGpuEndSessionPendingUsers {
    if (-not (Test-Path -LiteralPath $script:NextGpuEndSessionPendingFlagPath)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $script:NextGpuEndSessionPendingFlagPath -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @()
        }

        # Prefer JSON: {"users":["nextGPU","NextGPU-Admin"],"created":"..."}
        try {
            $obj = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($obj.users) {
                return @($obj.users | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            }
        }
        catch { }

        # Plain one-user-per-line fallback
        return @(
            Get-Content -LiteralPath $script:NextGpuEndSessionPendingFlagPath -ErrorAction Stop |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -and $_ -notmatch '^\s*\{' }
        )
    }
    catch {
        return @()
    }
}

function Set-NextGpuEndSessionPendingFlag {
    param(
        [Parameter(Mandatory)]
        [string[]]$Users
    )

    if (-not (Test-Path -LiteralPath $script:NextGpuProgramDataDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuProgramDataDir -Force | Out-Null
    }

    $existing = @(Get-NextGpuEndSessionPendingUsers)
    $merged = @($existing + $Users | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

    $payload = @{
        created = (Get-Date -Format 'o')
        users   = @($merged)
    } | ConvertTo-Json -Compress

    Set-Content -LiteralPath $script:NextGpuEndSessionPendingFlagPath -Value $payload -Encoding UTF8 -Force
    return $merged
}

function Clear-NextGpuEndSessionPendingFlag {
    if (Test-Path -LiteralPath $script:NextGpuEndSessionPendingFlagPath) {
        Remove-Item -LiteralPath $script:NextGpuEndSessionPendingFlagPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-NextGpuEndSessionPendingFlag {
    return (Test-Path -LiteralPath $script:NextGpuEndSessionPendingFlagPath)
}

function Test-NextGpuIsValidRepoRoot {
    <#
    .SYNOPSIS
        True only for the real corescripts folder (never %ProgramData%\nextGPU).
    #>
    param([string]$Root)
    if ([string]::IsNullOrWhiteSpace($Root)) { return $false }
    $root = $Root.Trim().TrimEnd('\')
    $programData = $script:NextGpuProgramDataDir.TrimEnd('\')
    if ($root -ieq $programData) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'domain.txt'))) { return $false }
    $markers = @(
        (Join-Path $root 'scripts\runtime\checking-update.bat'),
        (Join-Path $root 'scripts\runtime\UserStorageCommon.ps1'),
        (Join-Path $root 'RegisterMachine_Beta.bat')
    )
    foreach ($m in $markers) {
        if (Test-Path -LiteralPath $m) { return $true }
    }
    return $false
}

function Get-NextGpuRepoRootForUpdate {
    <#
    .SYNOPSIS
        Resolve corescripts root for EndSession checking-update.bat (after fallback).
        Never returns %ProgramData%\nextGPU.
    #>
    $markerPath = Join-Path $script:NextGpuProgramDataDir 'repo-root.txt'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marked = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            if (Test-NextGpuIsValidRepoRoot -Root $marked) {
                return $marked
            }
        }
        catch { }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $envRoot = $env:NEXTGPU_REPO_ROOT.Trim().TrimEnd('\')
        if (Test-NextGpuIsValidRepoRoot -Root $envRoot) {
            return $envRoot
        }
    }

    try {
        $dir = $PSScriptRoot
        if (-not $dir -and $MyInvocation.MyCommand.Path) {
            $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
        }
        for ($i = 0; $i -lt 8 -and $dir; $i++) {
            if (Test-NextGpuIsValidRepoRoot -Root $dir) {
                return $dir.TrimEnd('\')
            }
            $parent = Split-Path -Parent $dir
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
            $dir = $parent
        }
    }
    catch { }

    foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
        if (-not $drive.IsReady -or $drive.DriveType -ne 'Fixed') { continue }
        try {
            $domainFiles = Get-ChildItem -LiteralPath $drive.RootDirectory.FullName -Filter 'domain.txt' `
                -File -Recurse -Depth 6 -ErrorAction SilentlyContinue
            foreach ($domainFile in $domainFiles) {
                $repoRoot = $domainFile.Directory.FullName
                if (Test-NextGpuIsValidRepoRoot -Root $repoRoot) {
                    return $repoRoot.TrimEnd('\')
                }
            }
        }
        catch { }
    }
    return $null
}

function Resolve-NextGpuDomainTxtPath {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $candidates += (Join-Path $env:NEXTGPU_REPO_ROOT.TrimEnd('\') 'domain.txt')
    }
    $marker = Join-Path $script:NextGpuProgramDataDir 'repo-root.txt'
    if (Test-Path -LiteralPath $marker) {
        try {
            $root = (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            if ($root) { $candidates += (Join-Path $root 'domain.txt') }
        }
        catch { }
    }
    $candidates += (Join-Path $script:NextGpuProgramDataDir 'domain.txt')
    foreach ($path in $candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }
    return $null
}

function Get-NextGpuPrivateIp {
    try {
        $lines = ipconfig 2>$null | Select-String -Pattern '192\.168\.1\.'
        foreach ($line in $lines) {
            if ($line.Line -match ':\s*([0-9.]+)\s*$') {
                return $Matches[1].Trim()
            }
        }
    }
    catch { }
    return '127.0.0.1'
}

function Publish-UpdatingAtEndSession {
    <#
    .SYNOPSIS
        Suspend heartbeat, write STATUS=updating to domain.txt, POST updateStatus updating.
        Called from sunshine/endSession.ps1 before clean-session (steps 1-7).
    .OUTPUTS
        $true on success, $false on failure.
    #>

    $secretsHelper = Join-Path $PSScriptRoot 'NextGpuOnDemandGpuHostSecrets.ps1'
    if (Test-Path -LiteralPath $secretsHelper) {
        . $secretsHelper
        Set-NextGpuHeartbeatSuspendedFlag
    }
    else {
        if (-not (Test-Path -LiteralPath $script:NextGpuProgramDataDir)) {
            New-Item -ItemType Directory -Path $script:NextGpuProgramDataDir -Force | Out-Null
        }
        $suspend = Join-Path $script:NextGpuProgramDataDir 'heartbeat-suspended.flag'
        Set-Content -LiteralPath $suspend -Value '1' -Encoding ASCII -Force
    }

    $domainPath = Resolve-NextGpuDomainTxtPath
    if (-not $domainPath) {
        Write-Host '[Publish-Updating] ERROR: domain.txt not found; cannot publish updating.'
        return $false
    }

    $computerName = $null
    $publicIp = $null
    try {
        foreach ($line in Get-Content -LiteralPath $domainPath -ErrorAction Stop) {
            if ($line -match '^\s*COMPUTER_NAME\s*=\s*(.+)\s*$') { $computerName = $Matches[1].Trim() }
            if ($line -match '^\s*PUBLIC_IP\s*=\s*(.+)\s*$') { $publicIp = $Matches[1].Trim() }
        }
    }
    catch {
        Write-Host "[Publish-Updating] ERROR: reading domain.txt: $($_.Exception.Message)"
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($computerName) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        Write-Host '[Publish-Updating] ERROR: COMPUTER_NAME or PUBLIC_IP missing in domain.txt.'
        return $false
    }

    $privateIp = Get-NextGpuPrivateIp

    try {
        $lines = Get-Content -LiteralPath $domainPath -ErrorAction Stop
        $lines = $lines | ForEach-Object {
            if ($_ -match '^STATUS=') { 'STATUS=updating' } else { $_ }
        }
        if (-not ($lines -match '^STATUS=')) { $lines += 'STATUS=updating' }
        $lines | Set-Content -LiteralPath $domainPath -Encoding UTF8
        Write-Host "[Publish-Updating] domain.txt STATUS=updating written ($domainPath)."
    }
    catch {
        Write-Host "[Publish-Updating] ERROR: writing STATUS=updating: $($_.Exception.Message)"
        return $false
    }

    try {
        $statusFlag = Join-Path $env:TEMP 'machine_status_flag.txt'
        Set-Content -LiteralPath $statusFlag -Value 'updating' -Encoding ASCII -Force
    }
    catch {
        Write-Host "[Publish-Updating] WARN: could not write machine_status_flag.txt: $($_.Exception.Message)"
    }

    $payload = @{
        computer_name = $computerName
        publicIP      = $publicIp
        privateIP     = $privateIp
        status        = 'updating'
    } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Method Post `
            -Uri 'https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus' `
            -ContentType 'application/json' `
            -Body $payload | Out-Null
        Write-Host '[Publish-Updating] updateStatus updating posted.'
    }
    catch {
        Write-Host "[Publish-Updating] ERROR: updateStatus updating failed: $($_.Exception.Message)"
        return $false
    }

    return $true
}

function Publish-OnlineAtStartup {
    <#
    .SYNOPSIS
        Repair domain.txt from identity if needed, set machine-status.flag=online,
        POST updateStatus online, clear coordination flags.
    .OUTPUTS
        $true on success, $false on failure.
    #>

    $identityHelper = Join-Path $PSScriptRoot 'NextGpuMachineIdentity.ps1'
    if (Test-Path -LiteralPath $identityHelper) {
        . $identityHelper
        try {
            $null = Repair-NextGpuDomainTxtIfNeeded
        }
        catch {
            Write-Host "[Publish-Online] WARN: Repair-NextGpuDomainTxtIfNeeded: $($_.Exception.Message)"
        }
    }

    $computerName = $null
    $publicIp = $null

    if (Get-Command -Name Read-NextGpuMachineIdentity -ErrorAction SilentlyContinue) {
        try {
            $identity = Read-NextGpuMachineIdentity
            $computerName = [string]$identity.COMPUTER_NAME
            $publicIp = [string]$identity.PUBLIC_IP
        }
        catch {
            Write-Host "[Publish-Online] WARN: Read-NextGpuMachineIdentity: $($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace($computerName) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        $domainPath = Resolve-NextGpuDomainTxtPath
        if (-not $domainPath) {
            Write-Host "[Publish-Online] ERROR: domain.txt not found; cannot publish online."
            return $false
        }
        try {
            foreach ($line in Get-Content -LiteralPath $domainPath -ErrorAction Stop) {
                if ($line -match '^\s*COMPUTER_NAME\s*=\s*(.+)\s*$') { $computerName = $Matches[1].Trim() }
                if ($line -match '^\s*PUBLIC_IP\s*=\s*(.+)\s*$') { $publicIp = $Matches[1].Trim() }
            }
        }
        catch {
            Write-Host "[Publish-Online] ERROR: reading domain.txt: $($_.Exception.Message)"
            return $false
        }
    }

    if ([string]::IsNullOrWhiteSpace($computerName) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        Write-Host '[Publish-Online] ERROR: COMPUTER_NAME or PUBLIC_IP missing in identity/domain.txt.'
        return $false
    }

    $privateIp = Get-NextGpuPrivateIp

    if (Get-Command -Name Set-NextGpuMachineStatus -ErrorAction SilentlyContinue) {
        try {
            $null = Set-NextGpuMachineStatus -Status 'online'
            Write-Host '[Publish-Online] machine-status.flag=online written.'
        }
        catch {
            Write-Host "[Publish-Online] ERROR: writing machine-status.flag: $($_.Exception.Message)"
            return $false
        }
    }
    else {
        Write-Host '[Publish-Online] WARN: NextGpuMachineIdentity.ps1 not loaded; status flag not updated.'
    }

    $payload = @{
        computer_name = $computerName
        publicIP      = $publicIp
        privateIP     = $privateIp
        status        = 'online'
    } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod -Method Post `
            -Uri 'https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus' `
            -ContentType 'application/json' `
            -Body $payload | Out-Null
        Write-Host '[Publish-Online] updateStatus online posted.'
    }
    catch {
        Write-Host "[Publish-Online] ERROR: updateStatus online failed: $($_.Exception.Message)"
        return $false
    }

    $secretsHelper = Join-Path $PSScriptRoot 'NextGpuOnDemandGpuHostSecrets.ps1'
    if (Test-Path -LiteralPath $secretsHelper) {
        . $secretsHelper
        Clear-NextGpuStatusCoordinationFlags
        Write-Host '[Publish-Online] Cleared heartbeat-suspended and startup-publish-pending flags.'
    }
    else {
        $suspend = Join-Path $script:NextGpuProgramDataDir 'heartbeat-suspended.flag'
        $pending = Join-Path $script:NextGpuProgramDataDir 'startup-publish-pending.flag'
        if (Test-Path -LiteralPath $suspend) { Remove-Item -LiteralPath $suspend -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
        Write-Host '[Publish-Online] Cleared coordination flags (inline).'
    }

    return $true
}
