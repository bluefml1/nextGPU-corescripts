#Requires -Version 5.1
<#
.SYNOPSIS
    Add, merge, import, export, or remove session-folder-rules.json entries.
#>
[CmdletBinding()]
param(
    [string]$Id = '',
    [string]$Title = '',
    [ValidateSet('delete', 'replace', '')]
    [string]$Action = '',
    [string]$Target = '',
    [string]$Source = '',
    [string]$PreserveJson = '',
    [string]$StopProcessesJson = '',
    [string]$Preserve = '',
    [string]$StopProcesses = '',
    [string]$LogonFallback = '',
    [string]$ImportPath = '',
    [string]$ExportPath = '',
    [string]$DeleteId = '',
    [ValidateSet('Skip', 'Replace')]
    [string]$OnDuplicate = 'Skip'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SessionFolderRules-Common.ps1')

function New-SessionFolderRulesMergeResult {
    param(
        [int]$Added = 0,
        [int]$Skipped = 0,
        [int]$Replaced = 0,
        [int]$Removed = 0,
        [string[]]$Warnings = @(),
        [string]$Path = '',
        [string]$Message = ''
    )
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $Message = "Added $Added, skipped $Skipped, replaced $Replaced, removed $Removed."
    }
    return [PSCustomObject]@{
        Added    = $Added
        Skipped  = $Skipped
        Replaced = $Replaced
        Removed  = $Removed
        Warnings = $Warnings
        Path     = $Path
        Success  = $true
        Message  = $Message
    }
}

function Read-SessionFolderRulesDocument {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        $parsed = [PSCustomObject]@{ rules = @() }
    }
    if ($null -eq $parsed.rules) {
        $parsed | Add-Member -NotePropertyName rules -NotePropertyValue @() -Force
    }
    return $parsed
}

function Write-SessionFolderRulesDocument {
    param(
        [string]$Path,
        [object[]]$Rules
    )
    $payload = [PSCustomObject]@{
        _comment = 'Logoff runs all rules. Logon re-runs rules with logonFallback when verification fails. Replace sources default under ProgramData\nextGPU\session-templates\{id}.'
        rules    = @($Rules)
    }
    $json = $payload | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function ConvertTo-SessionFolderRuleSerialized {
    param($Entry)
    $obj = [PSCustomObject]@{
        id            = $Entry.id
        title         = $Entry.title
        action        = $Entry.action
        target        = $Entry.target
        preserve      = @($Entry.preserve)
        stopProcesses = @($Entry.stopProcesses)
        logonFallback = $Entry.logonFallback
    }
    if ($Entry.action -eq 'replace' -and $Entry.source) {
        $obj | Add-Member -NotePropertyName source -NotePropertyValue $Entry.source -Force
    }
    return $obj
}

function Split-RuleListParameter {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    if ($Value.Contains(';')) {
        return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertTo-RuleStringArray {
    param(
        [string]$Csv,
        [string]$Json
    )

    $fromCsv = Split-RuleListParameter -Value $Csv
    if ($fromCsv.Count -gt 0) {
        return $fromCsv
    }

    if ([string]::IsNullOrWhiteSpace($Json)) {
        return @()
    }

    $trim = $Json.Trim()
    if ($trim.StartsWith('[')) {
        return @($trim | ConvertFrom-Json)
    }

    return @($trim)
}

function New-IncomingSessionFolderRule {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Action,
        [string]$Target,
        [string]$Source,
        [string]$PreserveJson,
        [string]$StopProcessesJson,
        [string]$Preserve,
        [string]$StopProcesses,
        [string]$LogonFallback
    )
    $entry = [PSCustomObject]@{
        id            = $Id.Trim()
        title         = $Title.Trim()
        action        = $Action.Trim()
        target        = $Target.Trim()
        source        = $Source.Trim()
        preserve      = @(ConvertTo-RuleStringArray -Csv $Preserve -Json $PreserveJson)
        stopProcesses = @(ConvertTo-RuleStringArray -Csv $StopProcesses -Json $StopProcessesJson)
        logonFallback = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($LogonFallback)) {
        $entry.logonFallback = ($LogonFallback.Trim().ToLowerInvariant() -in @('true', '1', 'yes'))
    }
    return Normalize-SessionFolderRule -Entry $entry
}

function Find-SessionFolderRuleById {
    param(
        [System.Collections.Generic.List[object]]$Entries,
        [string]$RuleId
    )
    if ([string]::IsNullOrWhiteSpace($RuleId)) { return $null }
    return $Entries | Where-Object { $_.id -ieq $RuleId.Trim() } | Select-Object -First 1
}

$targetPath = Ensure-SessionFolderRulesFile
$added = 0
$skipped = 0
$replaced = 0
$removed = 0
$warnings = New-Object System.Collections.Generic.List[string]

try {
    if (-not [string]::IsNullOrWhiteSpace($ExportPath)) {
        $rules = @(Get-SessionFolderRules)
        $serialized = @($rules | ForEach-Object { ConvertTo-SessionFolderRuleSerialized -Entry $_ })
        Write-SessionFolderRulesDocument -Path $ExportPath -Rules $serialized
        $result = New-SessionFolderRulesMergeResult -Path $ExportPath -Message "Exported $($serialized.Count) rules to $ExportPath"
        $result | ConvertTo-Json -Depth 8 -Compress
        exit 0
    }

    $doc = Read-SessionFolderRulesDocument -Path $targetPath
    $existing = [System.Collections.Generic.List[object]]::new()
    foreach ($rule in @($doc.rules)) {
        if ($null -eq $rule) { continue }
        try {
            [void]$existing.Add((Normalize-SessionFolderRule -Entry $rule))
        }
        catch {
            throw "Invalid existing rule in ${targetPath}: $($_.Exception.Message)"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DeleteId)) {
        $before = $existing.Count
        $filtered = [System.Collections.Generic.List[object]]::new()
        foreach ($entry in $existing) {
            if ($entry.id -ieq $DeleteId.Trim()) { continue }
            [void]$filtered.Add($entry)
        }
        $removed = $before - $filtered.Count
        $existing = $filtered
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ImportPath)) {
        if (-not (Test-Path -LiteralPath $ImportPath)) {
            throw "Import file not found: $ImportPath"
        }
        $importDoc = Get-Content -LiteralPath $ImportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $incoming = @($importDoc.rules)
        if ($incoming.Count -eq 0) {
            throw "Import file has no rules array: $ImportPath"
        }
        foreach ($item in $incoming) {
            $norm = Normalize-SessionFolderRule -Entry $item
            $dup = Find-SessionFolderRuleById -Entries $existing -RuleId $norm.id
            if ($dup) {
                if ($OnDuplicate -eq 'Skip') {
                    $skipped++
                    [void]$warnings.Add("Skipped duplicate: $($norm.id)")
                    continue
                }
                $idx = -1
                for ($i = 0; $i -lt $existing.Count; $i++) {
                    if ($existing[$i].id -ieq $norm.id) { $idx = $i; break }
                }
                if ($idx -ge 0) {
                    $existing[$idx] = $norm
                    $replaced++
                }
                continue
            }
            [void]$existing.Add($norm)
            $added++
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Title) `
                -or [string]::IsNullOrWhiteSpace($Action) -or [string]::IsNullOrWhiteSpace($Target)) {
            throw 'Id, Title, Action, and Target are required unless using -ImportPath, -ExportPath, or -DeleteId.'
        }
        $norm = New-IncomingSessionFolderRule -Id $Id -Title $Title -Action $Action -Target $Target `
            -Source $Source -PreserveJson $PreserveJson -StopProcessesJson $StopProcessesJson `
            -Preserve $Preserve -StopProcesses $StopProcesses -LogonFallback $LogonFallback
        $dup = Find-SessionFolderRuleById -Entries $existing -RuleId $norm.id
        if ($dup) {
            if ($OnDuplicate -eq 'Skip') {
                $skipped++
                [void]$warnings.Add("Skipped duplicate: $($norm.id)")
            }
            else {
                $idx = -1
                for ($i = 0; $i -lt $existing.Count; $i++) {
                    if ($existing[$i].id -ieq $norm.id) { $idx = $i; break }
                }
                if ($idx -ge 0) {
                    $existing[$idx] = $norm
                    $replaced++
                }
            }
        }
        else {
            [void]$existing.Add($norm)
            $added++
        }
    }

    $serialized = @($existing | ForEach-Object { ConvertTo-SessionFolderRuleSerialized -Entry $_ })
    Write-SessionFolderRulesDocument -Path $targetPath -Rules $serialized
    $result = New-SessionFolderRulesMergeResult -Added $added -Skipped $skipped -Replaced $replaced `
        -Removed $removed -Warnings $warnings -Path $targetPath
    $result | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
catch {
    [PSCustomObject]@{
        Success = $false
        Message = $_.Exception.Message
    } | ConvertTo-Json -Compress
    exit 1
}
