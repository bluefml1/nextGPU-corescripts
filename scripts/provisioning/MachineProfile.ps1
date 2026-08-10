#Requires -Version 5.1
<#
.SYNOPSIS
    Read/write machine-profile.json (repo root) for per-host provisioning options.
#>

function Get-NextGpuMachineProfilePath {
    param([string]$RepoRoot)

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        throw 'RepoRoot is required.'
    }

    return Join-Path $RepoRoot.TrimEnd('\') 'machine-profile.json'
}

function Get-NextGpuVddEnabled {
    param([string]$RepoRoot)

    $path = Get-NextGpuMachineProfilePath -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return $true
    }

    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $true
        }

        $profile = $raw | ConvertFrom-Json
        if ($null -eq $profile.vdd) {
            return $true
        }

        return [bool]$profile.vdd.enabled
    }
    catch {
        Write-Warning "Could not read machine profile at $path; defaulting VDD to enabled. $($_.Exception.Message)"
        return $true
    }
}

function Set-NextGpuVddEnabled {
    param(
        [string]$RepoRoot,
        [bool]$Enabled
    )

    $path = Get-NextGpuMachineProfilePath -RepoRoot $RepoRoot
    $profile = [ordered]@{}

    if (Test-Path -LiteralPath $path) {
        try {
            $existing = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json
            if ($null -ne $existing) {
                foreach ($prop in $existing.PSObject.Properties) {
                    $profile[$prop.Name] = $prop.Value
                }
            }
        }
        catch {
            Write-Warning "Could not merge existing machine profile; overwriting. $($_.Exception.Message)"
        }
    }

    $profile['vdd'] = [ordered]@{ enabled = $Enabled }
    $json = ($profile | ConvertTo-Json -Depth 5)
    [System.IO.File]::WriteAllText($path, $json + "`r`n", [Text.UTF8Encoding]::new($false))
}
