#Requires -Version 5.1
<#
.SYNOPSIS
    Copy golden template folders into ProgramData\nextGPU\session-templates\.
#>
[CmdletBinding()]
param(
    [switch]$SeedGarena,
    [string]$RuleId = '',
    [string]$FromPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SessionFolderRules-Common.ps1')

$maintenanceDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'maintenance'
$garenaClient = Join-Path $maintenanceDir 'Install-GarenaClient.ps1'
if (Test-Path -LiteralPath $garenaClient) {
    . $garenaClient
}

function Copy-SessionTemplateFolder {
    param(
        [Parameter(Mandatory)][string]$DestinationId,
        [Parameter(Mandatory)][string]$SourcePath
    )

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw "Source path not found: $SourcePath"
    }

    Ensure-NextGpuSessionFolders | Out-Null
    $dest = Join-Path (Get-NextGpuSessionTemplateRoot) $DestinationId
    if (Test-Path -LiteralPath $dest) {
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    $destParent = Split-Path -Parent $dest
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $dest -Recurse -Force
    Write-SessionFolderRulesLog "Seeded template '$DestinationId' from $SourcePath -> $dest"
    return $dest
}

try {
    if ($SeedGarena) {
        $bundleRoot = $null
        if (Get-Command Find-ExistingGarenaSyncPath -ErrorAction SilentlyContinue) {
            $bundleRoot = Find-ExistingGarenaSyncPath
        }
        if (-not $bundleRoot -and (Get-Command Read-SavedGarenaInstallRoot -ErrorAction SilentlyContinue)) {
            $saved = Read-SavedGarenaInstallRoot
            if ($saved) {
                $bundleRoot = Find-GarenaBundleRootUnderExtract -ExtractPath $saved
            }
        }
        if (-not $bundleRoot) {
            throw 'Garena bundle not found on disk. Run Sync / Setup Games & Apps first.'
        }
        $gxxSource = Get-GarenaGxxSourcePath -BundleRoot $bundleRoot
        $dest = Copy-SessionTemplateFolder -DestinationId 'garena-gxx' -SourcePath $gxxSource
        [PSCustomObject]@{ Success = $true; Message = "Seeded garena-gxx to $dest" } | ConvertTo-Json -Compress
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($RuleId) -and -not [string]::IsNullOrWhiteSpace($FromPath)) {
        $dest = Copy-SessionTemplateFolder -DestinationId $RuleId.Trim() -SourcePath $FromPath.Trim()
        [PSCustomObject]@{ Success = $true; Message = "Seeded $($RuleId.Trim()) to $dest" } | ConvertTo-Json -Compress
        exit 0
    }

    throw 'Specify -SeedGarena or both -RuleId and -FromPath.'
}
catch {
    Write-SessionFolderRulesLog $_.Exception.Message -Level ERROR
    [PSCustomObject]@{ Success = $false; Message = $_.Exception.Message } | ConvertTo-Json -Compress
    exit 1
}
