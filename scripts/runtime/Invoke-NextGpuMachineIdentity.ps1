#Requires -Version 5.1
<#
.SYNOPSIS
    Bat-friendly wrapper for NextGpuMachineIdentity.ps1.
.EXAMPLE
    powershell -File Invoke-NextGpuMachineIdentity.ps1 -Action SetStatus -Status updating
    powershell -File Invoke-NextGpuMachineIdentity.ps1 -Action GetStatus
    powershell -File Invoke-NextGpuMachineIdentity.ps1 -Action RepairDomain
    powershell -File Invoke-NextGpuMachineIdentity.ps1 -Action SaveIdentity -Domain x -PublicIp y -ComputerName z -VendorId v -VendorIdEnabled yes
    powershell -File Invoke-NextGpuMachineIdentity.ps1 -Action PostStatus -Status online -ComputerName z -PublicIp y -PrivateIp p
    powershell -File Invoke-NextGpuMachineIdentity.ps1 -Action LogEvent -Event CYCLE -Message "checking-update started"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('GetStatus', 'SetStatus', 'RepairDomain', 'SaveIdentity', 'WriteDomain', 'PostStatus', 'LogEvent')]
    [string]$Action,

    [ValidateSet('online', 'updating', 'update_fail', 'error')]
    [string]$Status = 'online',

    [string]$RepoRoot = '',
    [string]$Domain = '',
    [string]$PublicIp = '',
    [string]$ComputerName = '',
    [string]$PrivateIp = '',
    [string]$VendorId = '',
    [string]$VendorIdEnabled = '',
    [string]$Event = 'INFO',
    [string]$Message = ''
)

$script:NextGpuUpdateStatusUrl = 'https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateStatus'

$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'NextGpuMachineIdentity.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    Write-Error "Missing $helper"
    exit 1
}
. $helper

if ([string]::IsNullOrWhiteSpace($RepoRoot) -and -not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
    $RepoRoot = $env:NEXTGPU_REPO_ROOT
}

try {
    switch ($Action) {
        'GetStatus' {
            $value = Get-NextGpuMachineStatus -RepoRoot $RepoRoot
            Write-Output $value
            exit 0
        }
        'SetStatus' {
            $value = Set-NextGpuMachineStatus -Status $Status
            Write-Output $value
            exit 0
        }
        'RepairDomain' {
            $changed = Repair-NextGpuDomainTxtIfNeeded -RepoRoot $RepoRoot
            if ($changed) {
                Write-Output 'repaired'
            }
            else {
                Write-Output 'ok'
            }
            exit 0
        }
        'SaveIdentity' {
            $null = Save-NextGpuMachineIdentity `
                -ComputerName $ComputerName `
                -PublicIp $PublicIp `
                -Domain $Domain `
                -VendorId $VendorId `
                -VendorIdEnabled $VendorIdEnabled
            $null = Write-NextGpuDomainTxtFromIdentity -RepoRoot $RepoRoot -PublishProgramDataCopy
            $null = Set-NextGpuMachineStatus -Status 'online'
            Write-Output 'saved'
            exit 0
        }
        'WriteDomain' {
            $path = Write-NextGpuDomainTxtFromIdentity -RepoRoot $RepoRoot -PublishProgramDataCopy
            Write-Output $path
            exit 0
        }
        'PostStatus' {
            if ([string]::IsNullOrWhiteSpace($ComputerName) -or [string]::IsNullOrWhiteSpace($PublicIp)) {
                throw 'PostStatus requires -ComputerName and -PublicIp.'
            }
            if ([string]::IsNullOrWhiteSpace($PrivateIp)) { $PrivateIp = '127.0.0.1' }
            $payload = [ordered]@{
                computer_name = $ComputerName
                publicIP      = $PublicIp
                privateIP     = $PrivateIp
                status        = $Status
            } | ConvertTo-Json -Compress
            $response = Invoke-NextGpuStatusApiPost -Uri $script:NextGpuUpdateStatusUrl -Body $payload -TimeoutSec 30
            Write-Output $response
            exit 0
        }
        'LogEvent' {
            Write-NextGpuStatusLog -Event $Event -Message $Message
            exit 0
        }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
