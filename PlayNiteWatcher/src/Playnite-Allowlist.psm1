#Requires -Version 5.1

$script:_moduleRoot = $PSScriptRoot

function Get-DesktopAppAllowlistPath {
    param(
        [string]$RepoRoot,
        [string]$OverridePath = ""
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath)) {
        return $OverridePath
    }

    $RepoRoot = Resolve-PlayNiteWatcherRepoRoot -Candidate $RepoRoot
    return Join-Path $RepoRoot "config\playnite\$($script:DesktopAppAllowlistFileName)"
}

function Resolve-DesktopAppAllowlistPath {
    param(
        [string]$RepoRoot,
        [string]$OverridePath = ""
    )

    $path = Get-DesktopAppAllowlistPath -RepoRoot $RepoRoot -OverridePath $OverridePath
    if (Test-Path -LiteralPath $path) {
        return $path
    }

    $template = Join-Path $RepoRoot "config\playnite\desktop-apps.allowlist.json.template"
    if (Test-Path -LiteralPath $template) {
        return $template
    }

    return $path
}

function Get-AllowlistTypeDefinitions {
    return @(
        [PSCustomObject]@{ Type = 'Adobe';      DisplayName = 'Adobe Applications';      Base = 10000000; MinId = 10000001; MaxId = 10000100; MaxSlots = 100 }
        [PSCustomObject]@{ Type = 'Autodesk';   DisplayName = 'Autodesk Applications';   Base = 10000100; MinId = 10000101; MaxId = 10000200; MaxSlots = 100 }
        [PSCustomObject]@{ Type = 'ThirdParty'; DisplayName = 'Third-Party Applications'; Base = 10000200; MinId = 10000201; MaxId = 10000300; MaxSlots = 100 }
        [PSCustomObject]@{ Type = 'Games';      DisplayName = 'Games';                   Base = 10000300; MinId = 10000301; MaxId = 10000999; MaxSlots = 699 }
    )
}

function Get-AllowlistTypeDefinition {
    param([string]$Type)
    if ([string]::IsNullOrWhiteSpace($Type)) { return $null }
    $key = $Type.Trim()
    return Get-AllowlistTypeDefinitions | Where-Object { $_.Type -ieq $key } | Select-Object -First 1
}

function Get-AllowlistTypeFromNameId {
    param([string]$NameId)
    if ([string]::IsNullOrWhiteSpace($NameId)) { return $null }
    if ($NameId -notmatch '^\d+$') { return $null }
    $numeric = [long]$NameId
    foreach ($def in Get-AllowlistTypeDefinitions) {
        if ($numeric -ge $def.MinId -and $numeric -le $def.MaxId) {
            return $def.Type
        }
    }
    return $null
}

function Test-NameIdInAllowlistTypeRange {
    param(
        [string]$NameId,
        [string]$Type = ""
    )
    if ([string]::IsNullOrWhiteSpace($NameId) -or $NameId -notmatch '^\d+$') {
        return $false
    }
    $numeric = [long]$NameId
    if (-not [string]::IsNullOrWhiteSpace($Type)) {
        $def = Get-AllowlistTypeDefinition -Type $Type
        if ($null -eq $def) { return $false }
        return ($numeric -ge $def.MinId -and $numeric -le $def.MaxId)
    }
    return ($null -ne (Get-AllowlistTypeFromNameId -NameId $NameId))
}

function Resolve-AllowlistNameId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Type,
        [Parameter(Mandatory = $true)]
        [string]$SlotInput
    )

    $def = Get-AllowlistTypeDefinition -Type $Type
    if ($null -eq $def) {
        throw "Unknown allowlist type: $Type"
    }

    $digits = ($SlotInput -replace '\D', '').Trim()
    if ([string]::IsNullOrWhiteSpace($digits)) {
        throw "Name ID input must contain digits."
    }

    $numeric = [long]$digits
    if ($digits.Length -ge 8 -and $numeric -ge $def.MinId -and $numeric -le $def.MaxId) {
        return $numeric.ToString()
    }

    $slot = [int]($numeric % 1000)
    $suffixBase = 10000000
    if ($def.Type -ieq 'Games') {
        if ($slot -lt 1 -or $slot -gt $def.MaxSlots) {
            throw "Slot $slot is outside Games short-ID range 1-$($def.MaxSlots) or 301-999 (nameId $($def.MinId)-$($def.MaxId))."
        }
    }
    else {
        $minSlot = [int]($def.MinId - $suffixBase)
        $maxSlot = [int]($def.MaxId - $suffixBase)
        if ($slot -lt $minSlot -or $slot -gt $maxSlot) {
            throw "Slot $slot is outside $($def.Type) short-ID range $minSlot-$maxSlot (nameId $($def.MinId)-$($def.MaxId))."
        }
    }

    $suffixCandidate = $suffixBase + $slot
    if ($suffixCandidate -ge $def.MinId -and $suffixCandidate -le $def.MaxId) {
        return $suffixCandidate.ToString()
    }

    if ($def.Type -ieq 'Games') {
        $offsetCandidate = $def.Base + $slot
        if ($offsetCandidate -ge $def.MinId -and $offsetCandidate -le $def.MaxId) {
            return $offsetCandidate.ToString()
        }
    }

    throw "Resolved nameId for slot $slot is outside $($def.Type) range $($def.MinId)-$($def.MaxId). Use the type's short-ID range (Adobe 1-100, Autodesk 101-200, ThirdParty 201-300, Games 301-999)."
}

function Get-DesktopAppAllowlist {
    param(
        [string]$RepoRoot,
        [string]$AllowlistPath = ""
    )

    $path = Resolve-DesktopAppAllowlistPath -RepoRoot $RepoRoot -OverridePath $AllowlistPath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Desktop app allowlist not found: $path (copy desktop-apps.allowlist.json.template to desktop-apps.allowlist.json)"
    }

    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed -or $null -eq $parsed.apps) {
        throw "Allowlist has no apps array: $path"
    }

    $apps = @($parsed.apps)
    $nameIds = @{}
    $exes = @{}
    $normalized = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $apps) {
        if ($null -eq $entry) { continue }
        $exe = if ($entry.exe) { $entry.exe.ToString().Trim() } else { "" }
        $nameId = if ($entry.nameId) { $entry.nameId.ToString().Trim() } else { "" }
        $title = if ($entry.title) { $entry.title.ToString().Trim() } else { "" }
        $type = if ($entry.type) { $entry.type.ToString().Trim() } else { "" }

        if ([string]::IsNullOrWhiteSpace($exe) -or [string]::IsNullOrWhiteSpace($nameId)) {
            throw "Each allowlist app requires exe and nameId: $path"
        }

        if ([string]::IsNullOrWhiteSpace($type)) {
            $type = Get-AllowlistTypeFromNameId -NameId $nameId
            if ([string]::IsNullOrWhiteSpace($type)) {
                throw "nameId $nameId is outside known type ranges and entry has no type field: $path"
            }
        }
        elseif (-not (Test-NameIdInAllowlistTypeRange -NameId $nameId -Type $type)) {
            throw "nameId $nameId is outside type $type range: $path"
        }

        $exeKey = $exe.ToLowerInvariant()
        if ($exes.ContainsKey($exeKey)) {
            Write-Warning "Allowlist: '$exe' shares the same executable name as another entry (Windows is case-insensitive). Each entry is kept; use nameId to distinguish in Sunshine."
        }
        if ($nameIds.ContainsKey($nameId)) {
            throw "Duplicate nameId in allowlist: $nameId"
        }

        $exes[$exeKey] = $true
        $nameIds[$nameId] = $true

        if ([string]::IsNullOrWhiteSpace($title)) {
            $title = [System.IO.Path]::GetFileNameWithoutExtension($exe)
        }

        [void]$normalized.Add([PSCustomObject]@{
                Exe    = $exe
                NameId = $nameId
                Title  = $title
                Type   = $type
            })
    }

    return $normalized.ToArray()
}

Export-ModuleMember -Function *
