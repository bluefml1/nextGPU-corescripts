#Requires -Version 5.1
<#
    Session folder rules — clean session delete/replace between rentals.
#>

$script:SessionFolderRulesConfigFileName = 'session-folder-rules.json'
$script:SessionFolderRulesTemplateFileName = 'session-folder-rules.json.template'
$script:SessionFolderRulesLogFileName = 'session-folder-rules.log'

function Get-NextGpuProgramDataRoot {
    return Join-Path $env:ProgramData 'nextGPU'
}

function Get-NextGpuSessionTemplateRoot {
    return Join-Path (Get-NextGpuProgramDataRoot) 'session-templates'
}

function Get-NextGpuSessionRulesStateDir {
    return Join-Path (Get-NextGpuProgramDataRoot) 'session-rules'
}

function Get-NextGpuSessionRulesConfigPath {
    return Join-Path (Get-NextGpuProgramDataRoot) $script:SessionFolderRulesConfigFileName
}

function Get-NextGpuSessionRulesLogPath {
    $dir = Join-Path (Get-NextGpuProgramDataRoot) 'logs'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return Join-Path $dir $script:SessionFolderRulesLogFileName
}

function Resolve-NextGpuRepoRootForSessionRules {
    $markerPath = Join-Path (Get-NextGpuProgramDataRoot) 'repo-root.txt'
    if (Test-Path -LiteralPath $markerPath) {
        try {
            $marked = (Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            if ($marked -and (Test-Path -LiteralPath $marked)) {
                return $marked
            }
        }
        catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        $envRoot = $env:NEXTGPU_REPO_ROOT.Trim().TrimEnd('\')
        if (Test-Path -LiteralPath $envRoot) {
            return $envRoot
        }
    }
    $here = $PSScriptRoot
    if ($here) {
        $candidate = (Resolve-Path -LiteralPath (Join-Path $here '..\..') -ErrorAction SilentlyContinue).Path
        if ($candidate) { return $candidate }
    }
    return $null
}

function Get-SessionFolderRulesTemplatePath {
    $repo = Resolve-NextGpuRepoRootForSessionRules
    if (-not $repo) { return $null }
    return Join-Path $repo "config\$($script:SessionFolderRulesTemplateFileName)"
}

function Ensure-NextGpuSessionFolders {
    foreach ($dir in @(
            (Get-NextGpuProgramDataRoot)
            (Get-NextGpuSessionTemplateRoot)
            (Get-NextGpuSessionRulesStateDir)
            (Split-Path -Parent (Get-NextGpuSessionRulesLogPath))
        )) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }
}

function Get-MaintenanceScriptsDirForSessionRules {
    $repo = Resolve-NextGpuRepoRootForSessionRules
    if ($repo) {
        $dir = Join-Path $repo 'scripts\maintenance'
        if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
    }
    if ($PSScriptRoot) {
        $dir = Join-Path (Split-Path $PSScriptRoot -Parent) 'maintenance'
        if (Test-Path -LiteralPath $dir -PathType Container) { return $dir }
    }
    return $null
}

function Import-GarenaClientHelpersForSessionRules {
    if (Get-Command Find-GarenaBundleRootOnDisk -ErrorAction SilentlyContinue) {
        return $true
    }
    $maint = Get-MaintenanceScriptsDirForSessionRules
    if (-not $maint) { return $false }
    $garenaClient = Join-Path $maint 'Install-GarenaClient.ps1'
    if (-not (Test-Path -LiteralPath $garenaClient)) { return $false }

    if (-not (Get-Command Resolve-ManifestExtractPathString -ErrorAction SilentlyContinue)) {
        function script:Resolve-ManifestExtractPathString {
            param([AllowNull()]$Path)
            if ($null -eq $Path) { return '' }
            if ($Path -is [string]) { return $Path.Trim().Trim('"').TrimEnd('\') }
            return ([string]$Path).Trim().Trim('"').TrimEnd('\')
        }
    }
    if (-not (Get-Command ConvertTo-ObjectArray -ErrorAction SilentlyContinue)) {
        function script:ConvertTo-ObjectArray {
            param([AllowNull()]$InputObject)
            if ($null -eq $InputObject) { return @() }
            return @($InputObject)
        }
    }

    . $garenaClient
    return (Get-Command Find-GarenaBundleRootOnDisk -ErrorAction SilentlyContinue) -ne $null
}

function Write-SessionFolderRulesDocumentCore {
    param(
        [Parameter(Mandatory)][string]$Path,
        [object[]]$Rules
    )
    $payload = [PSCustomObject]@{
        _comment = 'Logoff runs all rules. Logon re-runs rules with logonFallback when verification fails. Replace sources default under ProgramData\nextGPU\session-templates\{id}.'
        rules    = @($Rules)
    }
    ($payload | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Upsert-SessionFolderReplaceRule {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Source,
        [string[]]$StopProcesses = @(),
        [string[]]$Preserve = @(),
        [bool]$LogonFallback = $true
    )

    $configPath = Ensure-SessionFolderRulesFile
    $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
    $doc = $null
    try { $doc = $raw | ConvertFrom-Json } catch { $doc = $null }
    if ($null -eq $doc) { $doc = [PSCustomObject]@{ rules = @() } }
    if ($null -eq $doc.rules) {
        $doc | Add-Member -NotePropertyName rules -NotePropertyValue @() -Force
    }

    $incoming = Normalize-SessionFolderRule -Entry ([PSCustomObject]@{
            id            = $Id
            title         = $Title
            action        = 'replace'
            target        = $Target
            source        = $Source
            preserve      = @($Preserve)
            stopProcesses = @($StopProcesses)
            logonFallback = $LogonFallback
        })

    $rules = [System.Collections.Generic.List[object]]::new()
    $replaced = $false
    foreach ($rule in @($doc.rules)) {
        if ($null -eq $rule) { continue }
        $norm = Normalize-SessionFolderRule -Entry $rule
        if ($norm.id -ieq $incoming.id) {
            [void]$rules.Add($incoming)
            $replaced = $true
        }
        else {
            [void]$rules.Add($norm)
        }
    }
    if (-not $replaced) {
        [void]$rules.Add($incoming)
    }

    Write-SessionFolderRulesDocumentCore -Path $configPath -Rules @($rules)
    Write-SessionFolderRulesLog ("Upserted session rule '{0}' source={1} target={2}" -f $incoming.id, $incoming.source, $incoming.target)
    return $incoming
}

function Get-GarenaSessionStopProcesses {
    param([string]$BundleRoot)

    $names = New-Object System.Collections.Generic.List[string]
    [void]$names.Add('Garena.exe')

    if ($BundleRoot) {
        $clientDir = $null
        if (Get-Command Get-GarenaClientSourcePath -ErrorAction SilentlyContinue) {
            $clientDir = Get-GarenaClientSourcePath -BundleRoot $BundleRoot
        }
        if ($clientDir -and (Test-Path -LiteralPath $clientDir -PathType Container)) {
            foreach ($exe in @(Get-ChildItem -LiteralPath $clientDir -Filter '*.exe' -File -ErrorAction SilentlyContinue)) {
                if ($exe.Name -match '^(?i)gxxapphelper\.exe$') {
                    if (-not ($names | Where-Object { $_ -ieq $exe.Name })) {
                        [void]$names.Add($exe.Name)
                    }
                }
            }
            $helper = Get-ChildItem -LiteralPath $clientDir -Filter 'gxxapphelper.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($helper -and -not ($names | Where-Object { $_ -ieq $helper.Name })) {
                [void]$names.Add($helper.Name)
            }
        }
    }

    if (-not ($names | Where-Object { $_ -ieq 'gxxapphelper.exe' })) {
        [void]$names.Add('gxxapphelper.exe')
    }
    return @($names)
}

function Copy-SessionTemplateFolderContents {
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

function Seed-GarenaSessionTemplate {
    if (-not (Import-GarenaClientHelpersForSessionRules)) {
        throw 'Garena helper scripts not available (Install-GarenaClient.ps1).'
    }

    $bundleRoot = Find-GarenaBundleRootOnDisk
    if (-not $bundleRoot) {
        throw 'Garena bundle not found on disk. Run Sync / Setup Games & Apps first.'
    }

    $configFolder = Get-GarenaConfigFolderSourcePath -BundleRoot $bundleRoot
    if (-not $configFolder -or -not (Test-Path -LiteralPath $configFolder -PathType Container)) {
        throw "No Config\* folder with gxx found under: $(Join-Path $bundleRoot 'Config')"
    }

    # Safety: only seed the folder nested under Config\, never the client Garena folder outside Config.
    if (-not (Test-GarenaPathIsUnderConfig -Path $configFolder -BundleRoot $bundleRoot)) {
        throw "Refusing to seed path outside Config\: $configFolder"
    }
    $parentLeaf = Split-Path -Leaf (Split-Path -Parent $configFolder)
    if ($parentLeaf -ine 'Config') {
        throw "Expected a direct child of Config\, got: $configFolder"
    }

    $folderName = Split-Path -Leaf $configFolder
    $dest = Copy-SessionTemplateFolderContents -DestinationId $folderName -SourcePath $configFolder

    $programDataTarget = Join-Path $env:ProgramData $folderName
    $null = Upsert-SessionFolderReplaceRule `
        -Id $folderName `
        -Title ("{0} reset" -f $folderName) `
        -Target $programDataTarget `
        -Source $dest `
        -StopProcesses (Get-GarenaSessionStopProcesses -BundleRoot $bundleRoot)

    Write-SessionFolderRulesLog "Seeded Config\$folderName only (client Garena outside Config was not moved)."
    return $dest
}

# Back-compat alias for callers still using the old name.
function Seed-GarenaGxxSessionTemplate {
    return (Seed-GarenaSessionTemplate)
}

function Test-SessionTemplateSourceCoveredBySeed {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$SeededPath
    )
    if ([string]::IsNullOrWhiteSpace($Source) -or [string]::IsNullOrWhiteSpace($SeededPath)) { return $false }
    if (-not (Test-Path -LiteralPath $SeededPath)) { return $false }
    if ($Source -ieq $SeededPath) { return (Test-Path -LiteralPath $Source) }
    if ($Source.StartsWith(($SeededPath.TrimEnd('\') + '\'), [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Test-Path -LiteralPath $Source)
    }
    return $false
}

function Ensure-SessionFolderReplaceSource {
    param([Parameter(Mandatory)][object]$Rule)

    Ensure-NextGpuSessionFolders | Out-Null

    $source = [string]$Rule.source
    if ([string]::IsNullOrWhiteSpace($source)) {
        throw "Replace rule '$($Rule.id)' has empty source."
    }

    if (Test-Path -LiteralPath $source) {
        return
    }

    Write-SessionFolderRulesLog "Replace source missing: $source" -Level WARN

    $parent = Split-Path -Parent $source
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Write-SessionFolderRulesLog "Created session template parent: $parent"
    }

    $templateRoot = Get-NextGpuSessionTemplateRoot
    $underTemplates = $source.StartsWith($templateRoot, [System.StringComparison]::OrdinalIgnoreCase)
    $sourceLeaf = Split-Path -Leaf $source

    $shouldTryGarenaSeed = $false
    if ($underTemplates -and (Import-GarenaClientHelpersForSessionRules)) {
        try {
            $bundleRoot = Find-GarenaBundleRootOnDisk
            if ($bundleRoot) {
                $configFolder = Get-GarenaConfigFolderSourcePath -BundleRoot $bundleRoot
                if ($configFolder) {
                    $configLeaf = Split-Path -Leaf $configFolder
                    if ($sourceLeaf -ieq $configLeaf -or $sourceLeaf -ieq 'gxx' -or [string]$Rule.id -ieq $configLeaf) {
                        $shouldTryGarenaSeed = $true
                    }
                }
            }
        }
        catch { }
    }

    if ($shouldTryGarenaSeed) {
        try {
            $seeded = Seed-GarenaSessionTemplate
            if (Test-SessionTemplateSourceCoveredBySeed -Source $source -SeededPath $seeded) {
                Write-SessionFolderRulesLog "Auto-seeded session template -> $source"
                return
            }
            if ($seeded -and (Test-Path -LiteralPath $seeded)) {
                $seedLeaf = Split-Path -Leaf $seeded
                if ($sourceLeaf -ieq $seedLeaf -or $sourceLeaf -ieq 'gxx') {
                    if (Test-Path -LiteralPath $source) {
                        Remove-Item -LiteralPath $source -Recurse -Force
                    }
                    $sourceParent = Split-Path -Parent $source
                    if ($sourceParent -and -not (Test-Path -LiteralPath $sourceParent)) {
                        New-Item -ItemType Directory -Path $sourceParent -Force | Out-Null
                    }
                    if ($sourceLeaf -ieq 'gxx' -and (Test-Path -LiteralPath (Join-Path $seeded 'gxx'))) {
                        Copy-Item -LiteralPath (Join-Path $seeded 'gxx') -Destination $source -Recurse -Force
                    }
                    else {
                        Copy-Item -LiteralPath $seeded -Destination $source -Recurse -Force
                    }
                    if (Test-Path -LiteralPath $source) {
                        Write-SessionFolderRulesLog "Copied seeded Config folder to rule source -> $source"
                        return
                    }
                }
            }
        }
        catch {
            throw ("Replace source not found: {0}. Auto-seed failed: {1}" -f $source, $_.Exception.Message)
        }
    }

    throw "Replace source not found: $source. Seed the template under session-templates first."
}

function Write-SessionFolderRulesLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    Ensure-NextGpuSessionFolders | Out-Null
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath (Get-NextGpuSessionRulesLogPath) -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($Level -eq 'WARN') { Write-Warning $Message }
    elseif ($Level -eq 'ERROR') { Write-Host $line -ForegroundColor Red }
    else { Write-Host $line }
}

function Ensure-SessionFolderRulesFile {
    $target = Get-NextGpuSessionRulesConfigPath
    if (Test-Path -LiteralPath $target) {
        return $target
    }
    Ensure-NextGpuSessionFolders | Out-Null
    $template = Get-SessionFolderRulesTemplatePath
    if ($template -and (Test-Path -LiteralPath $template)) {
        Copy-Item -LiteralPath $template -Destination $target -Force
        return $target
    }
  $default = @'
{
  "_comment": "Logoff runs all rules. Logon re-runs rules with logonFallback when verification fails.",
  "rules": []
}
'@
    Set-Content -LiteralPath $target -Value $default -Encoding UTF8
    return $target
}

function Get-DefaultSessionFolderRuleSource {
    param([string]$RuleId)
    if ([string]::IsNullOrWhiteSpace($RuleId)) { return '' }
    return Join-Path (Get-NextGpuSessionTemplateRoot) $RuleId.Trim()
}

function Normalize-SessionFolderRule {
    param($Entry)

    if ($null -eq $Entry) {
        throw 'Rule entry must be an object.'
    }
    $id = if ($Entry.id) { $Entry.id.ToString().Trim() } else { '' }
    $title = if ($Entry.title) { $Entry.title.ToString().Trim() } else { '' }
    $action = if ($Entry.action) { $Entry.action.ToString().Trim().ToLowerInvariant() } else { '' }
    $target = if ($Entry.target) { $Entry.target.ToString().Trim().TrimEnd('\') } else { '' }
    $source = if ($Entry.source) { $Entry.source.ToString().Trim().TrimEnd('\') } else { '' }

    if ([string]::IsNullOrWhiteSpace($id)) { throw 'Each rule requires id.' }
    if ([string]::IsNullOrWhiteSpace($title)) { throw "Rule '$id' requires title." }
    if ($action -notin @('delete', 'replace')) { throw "Rule '$id' action must be delete or replace." }
    if ([string]::IsNullOrWhiteSpace($target)) { throw "Rule '$id' requires target." }

    if ($action -eq 'replace') {
        if ([string]::IsNullOrWhiteSpace($source)) {
            $source = Get-DefaultSessionFolderRuleSource -RuleId $id
        }
        if ([string]::IsNullOrWhiteSpace($source)) {
            throw "Rule '$id' replace requires source or id for default template path."
        }
    }
    else {
        $source = ''
    }

    $preserve = New-Object System.Collections.Generic.List[string]
    if ($Entry.preserve) {
        foreach ($p in @($Entry.preserve)) {
            if ($null -eq $p) { continue }
            $rel = $p.ToString().Trim().TrimStart('\')
            if (-not [string]::IsNullOrWhiteSpace($rel)) {
                [void]$preserve.Add($rel)
            }
        }
    }

    $stopProcesses = New-Object System.Collections.Generic.List[string]
    if ($Entry.stopProcesses) {
        foreach ($proc in @($Entry.stopProcesses)) {
            if ($null -eq $proc) { continue }
            $leaf = $proc.ToString().Trim()
            if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                [void]$stopProcesses.Add($leaf)
            }
        }
    }

    $logonFallback = $true
    if ($null -ne $Entry.logonFallback) {
        $logonFallback = [bool]$Entry.logonFallback
    }

    return [PSCustomObject]@{
        id            = $id
        title         = $title
        action        = $action
        target        = $target
        source        = $source
        preserve      = $preserve.ToArray()
        stopProcesses = $stopProcesses.ToArray()
        logonFallback = $logonFallback
    }
}

function Get-SessionFolderRules {
    $path = Ensure-SessionFolderRulesFile
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $doc = $raw | ConvertFrom-Json
    if ($null -eq $doc -or $null -eq $doc.rules) {
        return @()
    }
    $rules = New-Object System.Collections.Generic.List[object]
    foreach ($item in @($doc.rules)) {
        if ($null -eq $item) { continue }
        [void]$rules.Add((Normalize-SessionFolderRule -Entry $item))
    }
    return $rules.ToArray()
}

function Format-SessionFolderRulePreserveSummary {
    param([string[]]$Preserve)
    $list = @($Preserve)
    if ($list.Count -eq 0) { return '—' }
    if ($list.Count -le 2) { return ($list -join ', ') }
    return "$($list.Count) paths ($($list[0]), …)"
}

function Get-SessionFolderRuleStatePath {
    param([string]$RuleId)
    return Join-Path (Get-NextGpuSessionRulesStateDir) "$RuleId.json"
}

function Get-SessionFolderRuleOkPath {
    param([string]$RuleId)
    return Join-Path (Get-NextGpuSessionRulesStateDir) "$RuleId.ok"
}

function Get-SessionFolderSourceFingerprint {
    param([string]$SourcePath)

    if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath)) {
        return ''
    }
    $item = Get-Item -LiteralPath $SourcePath -Force
    $count = @(Get-ChildItem -LiteralPath $SourcePath -Recurse -Force -ErrorAction SilentlyContinue).Count
    return '{0}|{1}|{2}' -f $item.LastWriteTimeUtc.Ticks, $count, $SourcePath.ToLowerInvariant()
}

function Set-SessionFolderRuleState {
    param(
        [string]$RuleId,
        [string]$Phase,
        [string]$Status,
        [string]$ErrorMessage = '',
        [string]$Fingerprint = ''
    )
    Ensure-NextGpuSessionFolders | Out-Null
    $obj = [PSCustomObject]@{
        ruleId      = $RuleId
        phase       = $Phase
        status      = $Status
        error       = $ErrorMessage
        fingerprint = $Fingerprint
        updatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Get-SessionFolderRuleStatePath -RuleId $RuleId) -Encoding UTF8
}

function Set-SessionFolderRuleOk {
    param(
        [string]$RuleId,
        [string]$Fingerprint
    )
    $content = "ok`n$fingerprint`n$((Get-Date).ToUniversalTime().ToString('o'))"
    Set-Content -LiteralPath (Get-SessionFolderRuleOkPath -RuleId $RuleId) -Value $content -Encoding UTF8 -Force
}

function Clear-SessionFolderRuleOk {
    param([string]$RuleId)
    $ok = Get-SessionFolderRuleOkPath -RuleId $RuleId
    if (Test-Path -LiteralPath $ok) {
        Remove-Item -LiteralPath $ok -Force -ErrorAction SilentlyContinue
    }
}

function Test-SessionFolderTargetEmpty {
    param([string]$TargetPath)

    if (-not (Test-Path -LiteralPath $TargetPath)) {
        return $true
    }
    $item = Get-Item -LiteralPath $TargetPath -Force
    if (-not $item.PSIsContainer) {
        return $false
    }
    return -not (@(Get-ChildItem -LiteralPath $TargetPath -Force -ErrorAction SilentlyContinue).Count -gt 0)
}

function Test-SessionFolderRuleVerified {
    param(
        [object]$Rule,
        [string]$ExpectedFingerprint = ''
    )

    if ($Rule.action -eq 'delete') {
        return (Test-SessionFolderTargetEmpty -TargetPath $Rule.target)
    }

    $okPath = Get-SessionFolderRuleOkPath -RuleId $Rule.id
    if (-not (Test-Path -LiteralPath $okPath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Rule.target)) {
        return $false
    }
    $fp = if ($ExpectedFingerprint) { $ExpectedFingerprint } else { Get-SessionFolderSourceFingerprint -SourcePath $Rule.source }
    if ([string]::IsNullOrWhiteSpace($fp)) {
        return $false
    }
    $okContent = (Get-Content -LiteralPath $okPath -Raw -ErrorAction SilentlyContinue)
    return ($okContent -and $okContent -match [regex]::Escape($fp))
}

function Stop-SessionFolderRuleProcesses {
    param([string[]]$ProcessNames)

    foreach ($name in @($ProcessNames)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $leaf = [System.IO.Path]::GetFileName($name)
        Get-Process -Name ($leaf -replace '\.exe$', '') -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 500
}

function Copy-SessionFolderPreserveFiles {
    param(
        [string]$TargetPath,
        [string[]]$Preserve,
        [string]$TempDir
    )

    $saved = @{}
    foreach ($rel in @($Preserve)) {
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $full = Join-Path $TargetPath $rel
        if (-not (Test-Path -LiteralPath $full)) { continue }
        $dest = Join-Path $TempDir $rel
        $destParent = Split-Path -Parent $dest
        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        if ((Get-Item -LiteralPath $full).PSIsContainer) {
            Copy-Item -LiteralPath $full -Destination $dest -Recurse -Force
        }
        else {
            Copy-Item -LiteralPath $full -Destination $dest -Force
        }
        $saved[$rel] = $dest
    }
    return $saved
}

function Restore-SessionFolderPreserveFiles {
    param(
        [string]$TargetPath,
        [hashtable]$Saved
    )

    foreach ($rel in $Saved.Keys) {
        $src = $Saved[$rel]
        $dest = Join-Path $TargetPath $rel
        $destParent = Split-Path -Parent $dest
        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        if ((Get-Item -LiteralPath $src).PSIsContainer) {
            Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force
        }
        else {
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
    }
}

function Invoke-SessionFolderDelete {
    param(
        [object]$Rule,
        [switch]$WhatIf
    )

    if (-not (Test-Path -LiteralPath $Rule.target)) {
        return
    }
    if ($WhatIf) {
        Write-SessionFolderRulesLog "WhatIf delete: $($Rule.target)"
        return
    }
    Remove-Item -LiteralPath $Rule.target -Recurse -Force -ErrorAction Stop
}

function Sync-SessionFolderReplace {
    param(
        [object]$Rule,
        [switch]$WhatIf
    )

    Ensure-SessionFolderReplaceSource -Rule $Rule

    if ($WhatIf) {
        Write-SessionFolderRulesLog "WhatIf replace: $($Rule.source) -> $($Rule.target)"
        return
    }

    $tempPreserve = Join-Path $env:TEMP ("nextgpu-preserve-" + [guid]::NewGuid().ToString('N'))
    $saved = @{}
    try {
        if ((Test-Path -LiteralPath $Rule.target) -and $Rule.preserve.Count -gt 0) {
            if (-not (Test-Path -LiteralPath $tempPreserve)) {
                New-Item -ItemType Directory -Path $tempPreserve -Force | Out-Null
            }
            $saved = Copy-SessionFolderPreserveFiles -TargetPath $Rule.target -Preserve $Rule.preserve -TempDir $tempPreserve
        }

        if (Test-Path -LiteralPath $Rule.target) {
            Remove-Item -LiteralPath $Rule.target -Recurse -Force -ErrorAction Stop
        }

        $targetParent = Split-Path -Parent $Rule.target
        if ($targetParent -and -not (Test-Path -LiteralPath $targetParent)) {
            New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        }

        Copy-Item -LiteralPath $Rule.source -Destination $Rule.target -Recurse -Force -ErrorAction Stop

        if ($saved.Count -gt 0) {
            Restore-SessionFolderPreserveFiles -TargetPath $Rule.target -Saved $saved
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPreserve) {
            Remove-Item -LiteralPath $tempPreserve -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-SessionFolderRule {
    param(
        [object]$Rule,
        [string]$Phase,
        [switch]$WhatIf
    )

    Write-SessionFolderRulesLog "Running rule '$($Rule.id)' ($($Rule.action)) phase=$Phase"
    Stop-SessionFolderRuleProcesses -ProcessNames $Rule.stopProcesses

    try {
        if ($Rule.action -eq 'delete') {
            Invoke-SessionFolderDelete -Rule $Rule -WhatIf:$WhatIf
        }
        else {
            Sync-SessionFolderReplace -Rule $Rule -WhatIf:$WhatIf
        }

        if ($WhatIf) {
            return [PSCustomObject]@{ Success = $true; Skipped = $true }
        }

        $fp = if ($Rule.action -eq 'replace') { Get-SessionFolderSourceFingerprint -SourcePath $Rule.source } else { 'delete' }
        if ($Phase -eq 'Logoff') {
            Set-SessionFolderRuleOk -RuleId $Rule.id -Fingerprint $fp
        }
        Set-SessionFolderRuleState -RuleId $Rule.id -Phase $Phase -Status 'success' -Fingerprint $fp
        Write-SessionFolderRulesLog "Rule '$($Rule.id)' completed."
        return [PSCustomObject]@{ Success = $true; Skipped = $false }
    }
    catch {
        Clear-SessionFolderRuleOk -RuleId $Rule.id
        Set-SessionFolderRuleState -RuleId $Rule.id -Phase $Phase -Status 'failed' -ErrorMessage $_.Exception.Message
        Write-SessionFolderRulesLog "Rule '$($Rule.id)' failed: $($_.Exception.Message)" -Level ERROR
        return [PSCustomObject]@{ Success = $false; Skipped = $false; Error = $_.Exception.Message }
    }
}

function Invoke-SessionFolderRulesPhase {
    param(
        [ValidateSet('Logoff', 'Logon')]
        [string]$Phase,
        [switch]$WhatIf
    )

    Ensure-NextGpuSessionFolders | Out-Null
    $rules = @(Get-SessionFolderRules)
    if ($rules.Count -eq 0) {
        Write-SessionFolderRulesLog "No session folder rules configured."
        return [PSCustomObject]@{ Ran = 0; Skipped = 0; Failed = 0 }
    }

    $ran = 0
    $skipped = 0
    $failed = 0

    foreach ($rule in $rules) {
        if ($Phase -eq 'Logon') {
            if (-not $rule.logonFallback) {
                $skipped++
                continue
            }
            $fp = if ($rule.action -eq 'replace') { Get-SessionFolderSourceFingerprint -SourcePath $rule.source } else { 'delete' }
            if (Test-SessionFolderRuleVerified -Rule $rule -ExpectedFingerprint $fp) {
                Write-SessionFolderRulesLog "Logon verify OK: $($rule.id)"
                $skipped++
                continue
            }
            Write-SessionFolderRulesLog "Logon fallback re-run: $($rule.id)" -Level WARN
        }

        $result = Invoke-SessionFolderRule -Rule $rule -Phase $Phase -WhatIf:$WhatIf
        if ($result.Skipped) { $skipped++ }
        elseif ($result.Success) { $ran++ }
        else { $failed++ }
    }

    Write-SessionFolderRulesLog "Phase $Phase done: ran=$ran skipped=$skipped failed=$failed"
    return [PSCustomObject]@{ Ran = $ran; Skipped = $skipped; Failed = $failed }
}

function Resolve-InvokeSessionFolderRulesScript {
    $published = Join-Path (Get-NextGpuProgramDataRoot) 'scripts\runtime\Invoke-SessionFolderRules.ps1'
    if (Test-Path -LiteralPath $published) {
        return $published
    }
    $repo = Resolve-NextGpuRepoRootForSessionRules
    if ($repo) {
        $repoScript = Join-Path $repo 'scripts\runtime\Invoke-SessionFolderRules.ps1'
        if (Test-Path -LiteralPath $repoScript) {
            return $repoScript
        }
    }
    return Join-Path $PSScriptRoot 'Invoke-SessionFolderRules.ps1'
}
