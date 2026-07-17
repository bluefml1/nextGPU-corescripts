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

try {
    if ($SeedGarena) {
        $dest = Seed-GarenaSessionTemplate
        [PSCustomObject]@{ Success = $true; Message = "Seeded Garena template to $dest" } | ConvertTo-Json -Compress
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($RuleId) -and -not [string]::IsNullOrWhiteSpace($FromPath)) {
        $dest = Copy-SessionTemplateFolderContents -DestinationId $RuleId.Trim() -SourcePath $FromPath.Trim()
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
