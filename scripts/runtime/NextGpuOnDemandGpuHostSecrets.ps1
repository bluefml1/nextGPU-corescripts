#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for onDemandGPUHost API key (registerMachine / vendor shutdown).
    Storage mirrors user-s3.env: ProgramData secrets file + optional machine env.
#>

Set-StrictMode -Version Latest

$script:NextGpuOnDemandProgramDataDir = Join-Path $env:ProgramData 'nextGPU'
$script:NextGpuOnDemandSecretsDir = Join-Path $script:NextGpuOnDemandProgramDataDir 'secrets'
$script:NextGpuOnDemandSecretsFile = Join-Path $script:NextGpuOnDemandSecretsDir 'ondemand-gpu-host.env'
$script:NextGpuOnDemandEnvVarName = 'NEXTGPU_ONDEMAND_GPU_HOST_API_KEY'
$script:NextGpuHeartbeatSuspendedFlag = Join-Path $script:NextGpuOnDemandProgramDataDir 'heartbeat-suspended.flag'
$script:NextGpuStartupPublishPendingFlag = Join-Path $script:NextGpuOnDemandProgramDataDir 'startup-publish-pending.flag'

function Get-NextGpuOnDemandGpuHostApiKey {
    <#
    .SYNOPSIS
        Returns the API key from machine env, then secrets file. Never writes the value.
    .OUTPUTS
        Hashtable @{ ApiKey = string; Source = string } or $null.
    #>
    $fromEnv = [Environment]::GetEnvironmentVariable($script:NextGpuOnDemandEnvVarName, 'Machine')
    if ([string]::IsNullOrWhiteSpace($fromEnv)) {
        $fromEnv = [Environment]::GetEnvironmentVariable($script:NextGpuOnDemandEnvVarName, 'Process')
    }
    if (-not [string]::IsNullOrWhiteSpace($fromEnv)) {
        return @{ ApiKey = $fromEnv.Trim(); Source = 'environment' }
    }

    if (-not (Test-Path -LiteralPath $script:NextGpuOnDemandSecretsFile)) {
        return $null
    }

    $vars = @{}
    foreach ($line in Get-Content -LiteralPath $script:NextGpuOnDemandSecretsFile -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $idx = $line.IndexOf('=')
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $vars[$key] = $val
    }

    $fileKey = $vars[$script:NextGpuOnDemandEnvVarName]
    if (-not [string]::IsNullOrWhiteSpace($fileKey)) {
        return @{ ApiKey = $fileKey.Trim(); Source = $script:NextGpuOnDemandSecretsFile }
    }
    return $null
}

function Save-NextGpuOnDemandGpuHostApiKey {
    <#
    .SYNOPSIS
        Writes API key to ProgramData secrets with SYSTEM + Administrators ACL.
    #>
    param(
        [Parameter(Mandatory)][string]$ApiKey
    )

    $trimmed = $ApiKey.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'ApiKey is empty.'
    }

    if (-not (Test-Path -LiteralPath $script:NextGpuOnDemandSecretsDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuOnDemandSecretsDir -Force | Out-Null
    }

    $content = @(
        '# Created by Import-RegisterMachineConfig.ps1 - do not commit to git.'
        "$($script:NextGpuOnDemandEnvVarName)=$trimmed"
    )
    Set-Content -LiteralPath $script:NextGpuOnDemandSecretsFile -Value $content -Encoding UTF8 -Force

    try {
        $acl = Get-Acl -LiteralPath $script:NextGpuOnDemandSecretsFile
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $null = $acl.RemoveAccessRule($_) }
        $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $system, 'FullControl', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $admins, 'FullControl', 'Allow')))
        Set-Acl -LiteralPath $script:NextGpuOnDemandSecretsFile -AclObject $acl
    }
    catch {
        Write-Warning "Could not tighten ACL on ondemand-gpu-host.env: $($_.Exception.Message)"
    }

    return $script:NextGpuOnDemandSecretsFile
}

function Remove-NextGpuOnDemandGpuHostApiKey {
    if (Test-Path -LiteralPath $script:NextGpuOnDemandSecretsFile) {
        Remove-Item -LiteralPath $script:NextGpuOnDemandSecretsFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-NextGpuHeartbeatSuspendedFlag {
    param([switch]$Clear)

    if (-not (Test-Path -LiteralPath $script:NextGpuOnDemandProgramDataDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuOnDemandProgramDataDir -Force | Out-Null
    }

    if ($Clear) {
        if (Test-Path -LiteralPath $script:NextGpuHeartbeatSuspendedFlag) {
            Remove-Item -LiteralPath $script:NextGpuHeartbeatSuspendedFlag -Force -ErrorAction SilentlyContinue
        }
        return
    }

    Set-Content -LiteralPath $script:NextGpuHeartbeatSuspendedFlag -Value '1' -Encoding ASCII -Force
}

function Set-NextGpuStartupPublishPendingFlag {
    param([switch]$Clear)

    if (-not (Test-Path -LiteralPath $script:NextGpuOnDemandProgramDataDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuOnDemandProgramDataDir -Force | Out-Null
    }

    if ($Clear) {
        if (Test-Path -LiteralPath $script:NextGpuStartupPublishPendingFlag) {
            Remove-Item -LiteralPath $script:NextGpuStartupPublishPendingFlag -Force -ErrorAction SilentlyContinue
        }
        return
    }

    Set-Content -LiteralPath $script:NextGpuStartupPublishPendingFlag -Value '1' -Encoding ASCII -Force
}

function Test-NextGpuHeartbeatShouldSkip {
    return (Test-Path -LiteralPath $script:NextGpuHeartbeatSuspendedFlag) -or
        (Test-Path -LiteralPath $script:NextGpuStartupPublishPendingFlag)
}

function Clear-NextGpuStatusCoordinationFlags {
    Set-NextGpuHeartbeatSuspendedFlag -Clear
    Set-NextGpuStartupPublishPendingFlag -Clear
}
