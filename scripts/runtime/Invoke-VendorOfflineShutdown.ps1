#Requires -Version 5.1
<#
.SYNOPSIS
    Vendor host post-update: call onDemandGPUHost shutdown only.
    Leaves machine status as updating (no offline updateStatus / domain.txt change).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ComputerName
)

$ErrorActionPreference = 'Stop'

$secretsHelper = Join-Path $PSScriptRoot 'NextGpuOnDemandGpuHostSecrets.ps1'
if (-not (Test-Path -LiteralPath $secretsHelper)) {
    Write-Host "[ERROR] NextGpuOnDemandGpuHostSecrets.ps1 not found at $secretsHelper"
    exit 1
}
. $secretsHelper

$cred = Get-NextGpuOnDemandGpuHostApiKey
if (-not $cred -or [string]::IsNullOrWhiteSpace($cred.ApiKey)) {
    Write-Host '[ERROR] On-demand GPU host API key missing. Set NEXTGPU_ONDEMAND_GPU_HOST_API_KEY or %ProgramData%\nextGPU\secrets\ondemand-gpu-host.env'
    Write-NextGpuStatusLog -Event 'VENDOR_SHUTDOWN' -Data @{ result = 'skipped'; reason = 'API key missing'; computer_name = $ComputerName }
    Clear-NextGpuStatusCoordinationFlags
    exit 2
}

Set-NextGpuHeartbeatSuspendedFlag
Set-NextGpuStartupPublishPendingFlag

$shutdownBody = @{
    action        = 'shutdown'
    computer_name = $ComputerName
} | ConvertTo-Json -Compress

Write-NextGpuStatusLog -Event 'VENDOR_SHUTDOWN' -Data @{ result = 'requesting'; computer_name = $ComputerName; keySource = $cred.Source }
try {
    $headers = @{ 'x-api-key' = $cred.ApiKey }
    $response = Invoke-NextGpuStatusApiPost `
        -Uri 'https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/onDemandGPUHost' `
        -Headers $headers `
        -Body $shutdownBody
    Write-Host "[*] onDemandGPUHost shutdown requested (status left as updating). Response: $response"
}
catch {
    Write-Host ('[ERROR] onDemandGPUHost shutdown failed: ' + $_.Exception.Message)
    Clear-NextGpuStatusCoordinationFlags
    exit 4
}

exit 0
