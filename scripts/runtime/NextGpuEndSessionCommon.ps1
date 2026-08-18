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
