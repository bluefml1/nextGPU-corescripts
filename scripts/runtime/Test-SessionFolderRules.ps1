#Requires -Version 5.1
<#
.SYNOPSIS
    Unit tests for session folder rules (normalize, delete, replace, verify, merge).
#>
$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'SessionFolderRules-Common.ps1')

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw "FAIL: $Label" }
    Write-Host "[OK] $Label" -ForegroundColor Green
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Label)
    if ("$Expected" -ne "$Actual") {
        throw "FAIL: $Label expected '$Expected' got '$Actual'"
    }
    Write-Host "[OK] $Label" -ForegroundColor Green
}

$tempRoot = Join-Path $env:TEMP ("nextgpu-session-rules-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$origProgramData = $env:ProgramData
$testProgramData = Join-Path $tempRoot 'ProgramData'
New-Item -ItemType Directory -Path (Join-Path $testProgramData 'nextGPU') -Force | Out-Null
$env:ProgramData = $testProgramData

try {
    Ensure-NextGpuSessionFolders | Out-Null
    $emptyConfig = Join-Path (Join-Path $testProgramData 'nextGPU') 'session-folder-rules.json'
    Set-Content -LiteralPath $emptyConfig -Value '{"rules":[]}' -Encoding UTF8

    # Normalize
    $norm = Normalize-SessionFolderRule -Entry ([PSCustomObject]@{
            id            = 'test-rule'
            title         = 'Test'
            action        = 'replace'
            target        = 'C:\Target'
            preserve      = @('\keep\file.txt')
            stopProcesses = @('foo.exe')
            logonFallback = $true
        })
    Assert-Equal 'test-rule' $norm.id 'Normalize id'
    Assert-True ($norm.source -like '*session-templates\test-rule') 'Default source path'
    Assert-Equal 1 $norm.preserve.Count 'Preserve count'

    # Delete rule
    $deleteTarget = Join-Path $tempRoot 'delete-me'
    New-Item -ItemType Directory -Path $deleteTarget -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $deleteTarget 'x.txt') -Value 'x'
    $deleteRule = Normalize-SessionFolderRule -Entry ([PSCustomObject]@{
            id = 'del'; title = 'Del'; action = 'delete'; target = $deleteTarget
        })
    $delResult = Invoke-SessionFolderRule -Rule $deleteRule -Phase 'Logoff'
    Assert-True $delResult.Success 'Delete rule success'
    Assert-True (Test-SessionFolderTargetEmpty -TargetPath $deleteTarget) 'Target empty after delete'

    # Replace with preserve
    $source = Join-Path $tempRoot 'golden'
    $target = Join-Path $tempRoot 'runtime'
    $preserveRel = 'saved\state.dat'
    New-Item -ItemType Directory -Path (Join-Path $source 'sub') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $source 'sub\a.txt') -Value 'golden'
    New-Item -ItemType Directory -Path (Join-Path $target 'saved') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $target $preserveRel) -Value 'keep-me'

    $replaceRule = Normalize-SessionFolderRule -Entry ([PSCustomObject]@{
            id       = 'rep'
            title    = 'Rep'
            action   = 'replace'
            target   = $target
            source   = $source
            preserve = @($preserveRel)
        })
    $repResult = Invoke-SessionFolderRule -Rule $replaceRule -Phase 'Logoff'
    Assert-True $repResult.Success 'Replace rule success'
    Assert-True (Test-Path -LiteralPath (Join-Path $target 'sub\a.txt')) 'Golden file copied'
    Assert-Equal 'keep-me' (Get-Content -LiteralPath (Join-Path $target $preserveRel) -Raw).Trim() 'Preserve restored'

    # Verify + logon skip
    $fp = Get-SessionFolderSourceFingerprint -SourcePath $source
    Assert-True (Test-SessionFolderRuleVerified -Rule $replaceRule -ExpectedFingerprint $fp) 'Verified after logoff'

    $rulesDoc = [PSCustomObject]@{
        rules = @(
            [PSCustomObject]@{
                id            = $replaceRule.id
                title         = $replaceRule.title
                action        = $replaceRule.action
                target        = $replaceRule.target
                source        = $replaceRule.source
                preserve      = @($replaceRule.preserve)
                stopProcesses = @()
                logonFallback = $true
            }
        )
    }
    $rulesDoc | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $emptyConfig -Encoding UTF8

    $phaseStats = Invoke-SessionFolderRulesPhase -Phase 'Logon'
    Assert-True ($phaseStats.Skipped -ge 1) 'Logon skips verified rule'
    Assert-True ($phaseStats.Failed -eq 0) 'Logon has no failures'

    # Missing replace source creates session-templates parent, then fails clearly for non-Garena
    $missingSource = Join-Path (Get-NextGpuSessionTemplateRoot) 'missing-template'
    $missingTarget = Join-Path $tempRoot 'missing-runtime'
    New-Item -ItemType Directory -Path $missingTarget -Force | Out-Null
    if (Test-Path -LiteralPath (Get-NextGpuSessionTemplateRoot)) {
        Remove-Item -LiteralPath (Get-NextGpuSessionTemplateRoot) -Recurse -Force
    }
    $missingRule = Normalize-SessionFolderRule -Entry ([PSCustomObject]@{
            id     = 'missing-template'
            title  = 'Missing'
            action = 'replace'
            target = $missingTarget
            source = $missingSource
        })
    $missingResult = Invoke-SessionFolderRule -Rule $missingRule -Phase 'Logoff'
    Assert-True (-not $missingResult.Success) 'Missing non-Garena source fails'
    Assert-True (Test-Path -LiteralPath (Get-NextGpuSessionTemplateRoot)) 'session-templates recreated on missing source'
    Assert-True ($missingResult.Error -match 'Replace source not found') 'Missing source error message'

    # Garena auto-seed when replace source missing (Config\Garena -> session-templates\Garena)
    $fakeBundle = Join-Path $tempRoot 'GarenaBundle'
    $fakeConfigGarena = Join-Path $fakeBundle 'Config\Garena'
    $fakeGxx = Join-Path $fakeConfigGarena 'gxx'
    New-Item -ItemType Directory -Path (Join-Path $fakeGxx 'config') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeGxx 'config\gxx.dat') -Value 'golden-gxx'
    $fakeClient = Join-Path $fakeBundle 'Garena'
    New-Item -ItemType Directory -Path $fakeClient -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fakeClient 'Garena.exe') -Value 'fake'
    $maintDir = Join-Path (Split-Path $scriptRoot -Parent) 'maintenance'
    $garenaClientPath = Join-Path $maintDir 'Install-GarenaClient.ps1'
    Assert-True (Test-Path -LiteralPath $garenaClientPath) 'Install-GarenaClient.ps1 present'
    . $garenaClientPath
    $pathFile = Get-GarenaInstallPathFile
    $origGarenaPath = $null
    if (Test-Path -LiteralPath $pathFile) {
        $origGarenaPath = Get-Content -LiteralPath $pathFile -Raw
    }
    try {
        Set-Content -LiteralPath $pathFile -Value $fakeBundle -Encoding UTF8 -NoNewline
        $garenaSource = Join-Path (Get-NextGpuSessionTemplateRoot) 'Garena'
        if (Test-Path -LiteralPath $garenaSource) {
            Remove-Item -LiteralPath $garenaSource -Recurse -Force
        }
        $garenaTarget = Join-Path $tempRoot 'garena-runtime'
        New-Item -ItemType Directory -Path $garenaTarget -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $garenaTarget 'dirty.txt') -Value 'dirty'
        $garenaRule = Normalize-SessionFolderRule -Entry ([PSCustomObject]@{
                id     = 'Garena'
                title  = 'Garena reset'
                action = 'replace'
                target = $garenaTarget
                source = $garenaSource
            })
        $garenaResult = Invoke-SessionFolderRule -Rule $garenaRule -Phase 'Logoff'
        Assert-True $garenaResult.Success 'Garena auto-seed replace success'
        Assert-True (Test-Path -LiteralPath (Join-Path $garenaSource 'gxx\config\gxx.dat')) 'Garena template seeded from Config'
        Assert-True (Test-Path -LiteralPath (Join-Path $garenaTarget 'gxx\config\gxx.dat')) 'Garena target replaced from template'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $garenaTarget 'dirty.txt'))) 'Dirty file removed by replace'

        $rulesAfterSeed = @(Get-SessionFolderRules)
        $garenaRuleSaved = $rulesAfterSeed | Where-Object { $_.id -ieq 'Garena' } | Select-Object -First 1
        Assert-True ($null -ne $garenaRuleSaved) 'Dynamic Garena rule upserted'
        Assert-True ($garenaRuleSaved.source -like '*\session-templates\Garena') 'Dynamic rule source under session-templates'
        Assert-True ($garenaRuleSaved.target -like '*\Garena') 'Dynamic rule target under ProgramData name'
    }
    finally {
        if ($null -ne $origGarenaPath) {
            Set-Content -LiteralPath $pathFile -Value $origGarenaPath -Encoding UTF8 -NoNewline
        }
        elseif (Test-Path -LiteralPath $pathFile) {
            Remove-Item -LiteralPath $pathFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Merge CRUD
    $mergeScript = Join-Path $scriptRoot 'Merge-SessionFolderRules.ps1'
    $configPath = Ensure-SessionFolderRulesFile
    $mergeOut = & $mergeScript -Id 'merge-test' -Title 'Merge' -Action 'delete' -Target 'C:\Temp\unused' -OnDuplicate Replace 2>&1 | Out-String
    Assert-True ($mergeOut -match 'Added') 'Merge add'
    $rules = @(Get-SessionFolderRules)
    Assert-True (@($rules | Where-Object { $_.id -eq 'merge-test' }).Count -eq 1) 'Merge persisted'

    $exportPath = Join-Path $tempRoot 'export.json'
    $exportOut = & $mergeScript -ExportPath $exportPath 2>&1 | Out-String
    Assert-True (Test-Path -LiteralPath $exportPath) 'Export file created'
    Assert-True ($exportOut -match 'Exported') 'Export message'

    Write-Host ''
    Write-Host 'All session folder rules tests passed.' -ForegroundColor Cyan
}
finally {
    $env:ProgramData = $origProgramData
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
