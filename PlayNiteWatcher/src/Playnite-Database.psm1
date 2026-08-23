#Requires -Version 5.1
# LiteDB initialization, BSON helpers, database session, game records, and Playnite app management

$script:_moduleRoot = $PSScriptRoot

# Plugin IDs shared across database modules
$script:PlayniteSteamPluginId  = "CB91DFC9-B977-43BF-8E70-55F46E410FAB"
$script:PlayniteEpicPluginId   = "00000002-DBD1-46C6-B5D0-B1BA559D10E4"
$script:PlayniteManualPluginId = "00000000-0000-0000-0000-000000000000"

# ─────────────────────────────────────────────────────────────────────────────
# LiteDB initialization and connection helpers
# ─────────────────────────────────────────────────────────────────────────────

function Get-PlayniteLibraryGamesDbPath {
    param([string]$InstallDir = "", [string]$DataDirectory = "")
    if ([string]::IsNullOrWhiteSpace($DataDirectory)) {
        if ([string]::IsNullOrWhiteSpace($InstallDir)) { throw "Get-PlayniteLibraryGamesDbPath requires InstallDir or DataDirectory." }
        $DataDirectory = Get-PlayniteDataDirectory -InstallDir $InstallDir
    }
    return Join-Path (Join-Path $DataDirectory "library") "games.db"
}

function Test-PlayniteLiteDbDatabase {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 6) { return $false }
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(15, $bytes.Length))
        if ($ascii.StartsWith("SQLite format 3")) { return $false }
        return ($bytes[5] -eq 0xFF)
    }
    catch { return $false }
}

function Get-PlayniteLiteDbInvalidReason {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return "missing" }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -lt 6) { return "too_small" }
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes, 0, [Math]::Min(15, $bytes.Length))
        if ($ascii.StartsWith("SQLite format 3")) { return "sqlite" }
        if ($bytes[5] -ne 0xFF) { return "not_litedb" }
        return $null
    }
    catch {
        if ($_.Exception.Message -match 'being used by another process') { return "locked" }
        return "unreadable"
    }
}

function Initialize-LiteDbFromPlayniteInstall {
    param([string]$InstallDir)
    if ($script:LiteDbAssemblyLoadedFrom -eq $InstallDir) { return }
    $dllPath = Join-Path $InstallDir "LiteDB.dll"
    if (-not (Test-Path -LiteralPath $dllPath)) { throw "LiteDB.dll not found in Playnite install folder: $InstallDir" }
    Add-Type -Path $dllPath
    $script:LiteDbAssemblyLoadedFrom = $InstallDir
}

function Get-PlayniteLiteDbConnectionString {
    param([string]$DbPath)
    return "Filename=$DbPath;Mode=Exclusive;Cache Size=0"
}

# ─────────────────────────────────────────────────────────────────────────────
# LiteDB + PowerShell interop helpers for BSON document manipulation
#
# Rules:
#   1) Return documents as ", $bsonDocument" (comma prefix) to prevent unwrapping
#   2) Never pass LiteDB objects as -Value via functions that return BsonDocument
#   3) Use New-Object LiteDB.BsonValue -ArgumentList @(,$obj) for nested containers
#   4) Do not type parameters as [LiteDB.BsonArray] - empty arrays bind as zero args
#   5) Do not type as [LiteDB.BsonDocument] - IEnumerable binding unwraps documents
# ─────────────────────────────────────────────────────────────────────────────

$script:LiteDbBsonDocumentIndexer = $null

function Set-LiteDbBsonField {
    param(
        [Parameter(Mandatory)][object]$Document,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowNull()][object]$Value
    )
    if ($Document -isnot [LiteDB.BsonDocument]) { throw "Set-LiteDbBsonField: expected LiteDB.BsonDocument, got $($Document.GetType().FullName)." }
    if (-not $script:LiteDbBsonDocumentIndexer) {
        $script:LiteDbBsonDocumentIndexer = [LiteDB.BsonDocument].GetProperty('Item', [type[]]@([string]))
        if (-not $script:LiteDbBsonDocumentIndexer) { throw 'LiteDB.BsonDocument string indexer not found.' }
    }
    if ($null -eq $Value) { $bson = [LiteDB.BsonValue]$null }
    elseif ($Value -is [LiteDB.BsonValue]) { $bson = $Value }
    elseif ($Value -is [LiteDB.BsonDocument] -or $Value -is [LiteDB.BsonArray]) { $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $Value) }
    elseif ($Value -is [guid]) { $bson = [LiteDB.BsonValue]$Value }
    elseif ($Value.GetType().IsGenericType -and $Value.GetType().Name -eq 'KeyValuePair`2') {
        $rebuilt = New-Object LiteDB.BsonDocument
        Set-LiteDbBsonField -Document $rebuilt -Name ([string]$Value.Key) -Value $Value.Value
        $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $rebuilt)
    }
    else { $bson = [LiteDB.BsonValue]$Value }
    $null = $script:LiteDbBsonDocumentIndexer.SetValue($Document, $bson, $Name)
}

function Add-LiteDbBsonArrayItem {
    param(
        [Parameter(Mandatory)][object]$Array,
        [Parameter(Mandatory)][AllowNull()][object]$Value
    )
    if ($Array -isnot [LiteDB.BsonArray]) { throw "Add-LiteDbBsonArrayItem: expected LiteDB.BsonArray, got $($Array.GetType().FullName)." }
    if ($null -eq $Value) { $bson = [LiteDB.BsonValue]$null }
    elseif ($Value -is [LiteDB.BsonValue]) { $bson = $Value }
    elseif ($Value -is [LiteDB.BsonDocument] -or $Value -is [LiteDB.BsonArray]) { $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $Value) }
    elseif ($Value -is [guid]) { $bson = [LiteDB.BsonValue]$Value }
    elseif ($Value.GetType().IsGenericType -and $Value.GetType().Name -eq 'KeyValuePair`2') {
        $rebuilt = New-Object LiteDB.BsonDocument
        Set-LiteDbBsonField -Document $rebuilt -Name ([string]$Value.Key) -Value $Value.Value
        $bson = New-Object LiteDB.BsonValue -ArgumentList @(, $rebuilt)
    }
    else { $bson = [LiteDB.BsonValue]$Value }
    [void]$Array.Add($bson)
}

function Get-BsonValueAsGuid {
    param($Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsNull) { return "" }
        if ($Value.IsDocument) {
            $doc = $Value.AsDocument
            if ($doc.ContainsKey('$guid')) { return $doc['$guid'].AsString }
        }
        if ($Value.IsGuid) { return $Value.AsGuid.ToString() }
        if ($Value.IsString) {
            $text = $Value.AsString
            if ($text -match '^[0-9a-fA-F-]{36}$') { return $text }
        }
    }
    $text = $Value.ToString()
    if ($text -match '"\$guid"\s*,\s*"([0-9a-fA-F-]{36})"') { return $Matches[1] }
    if ($text -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { return $Matches[1] }
    return ""
}

function Get-BsonValueAsString {
    param($Value)
    if ($null -eq $Value) { return "" }
    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsNull) { return "" }
        if ($Value.IsString) { return $Value.AsString }
    }
    return $Value.ToString()
}

function Get-BsonValueAsBool {
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsBoolean) { return $Value.AsBoolean }
        if ($Value.IsInt32) { return $Value.AsInt32 -ne 0 }
    }
    return [bool]$Value
}

function Get-BsonValueAsInt {
    param($Value)
    if ($null -eq $Value) { return 0 }
    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsInt32) { return $Value.AsInt32 }
        if ($Value.IsInt64) { return [int]$Value.AsInt64 }
        if ($Value.IsString) {
            $text = $Value.AsString
            switch -Regex ($text) {
                '^(?i)File$' { return 0 }
                '^(?i)URL$' { return 1 }
                '^(?i)Emulator$' { return 2 }
                '^(?i)Script$' { return 3 }
                default { if ($text -match '^\d+$') { return [int]$text } }
            }
        }
    }
    return [int]$Value
}

function Copy-LiteDbBsonValue {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [LiteDB.BsonValue]) {
        if ($Value.IsNull) { return [LiteDB.BsonValue]$null }
        if ($Value.IsDocument) { return New-Object LiteDB.BsonValue -ArgumentList @(, (Copy-LiteDbBsonDocument -Source $Value.AsDocument)) }
        if ($Value.IsArray) {
            $copy = New-Object LiteDB.BsonArray
            foreach ($entry in $Value.AsArray) { Add-LiteDbBsonArrayItem -Array $copy -Value (Copy-LiteDbBsonValue -Value $entry) }
            return New-Object LiteDB.BsonValue -ArgumentList @(, $copy)
        }
        if ($Value.IsGuid) { return [LiteDB.BsonValue]$Value.AsGuid }
        if ($Value.IsString) { return [LiteDB.BsonValue]$Value.AsString }
        if ($Value.IsBoolean) { return [LiteDB.BsonValue]$Value.AsBoolean }
        if ($Value.IsInt32) { return [LiteDB.BsonValue]$Value.AsInt32 }
        if ($Value.IsInt64) { return [LiteDB.BsonValue]$Value.AsInt64 }
        if ($Value.IsDouble) { return [LiteDB.BsonValue]$Value.AsDouble }
        if ($Value.IsDateTime) { return [LiteDB.BsonValue]$Value.AsDateTime }
        return [LiteDB.BsonValue]$Value.RawValue
    }
    if ($Value -is [LiteDB.BsonDocument]) { return New-Object LiteDB.BsonValue -ArgumentList @(, (Copy-LiteDbBsonDocument -Source $Value)) }
    if ($Value -is [LiteDB.BsonArray]) {
        $copy = New-Object LiteDB.BsonArray
        foreach ($entry in $Value) { Add-LiteDbBsonArrayItem -Array $copy -Value (Copy-LiteDbBsonValue -Value $entry) }
        return New-Object LiteDB.BsonValue -ArgumentList @(, $copy)
    }
    if ($Value -is [guid]) { return [LiteDB.BsonValue]$Value }
    return [LiteDB.BsonValue]$Value
}

function Copy-LiteDbBsonDocument {
    param($Source)
    if ($null -eq $Source) { return , (New-Object LiteDB.BsonDocument) }
    $sourceDoc = $null
    if ($Source -is [LiteDB.BsonDocument]) { $sourceDoc = $Source }
    elseif ($Source -is [LiteDB.BsonValue] -and $Source.IsDocument) { $sourceDoc = $Source.AsDocument }
    else { throw "Copy-LiteDbBsonDocument: expected BsonDocument, got $($Source.GetType().FullName)." }
    $dest = New-Object LiteDB.BsonDocument
    foreach ($key in $sourceDoc.Keys) { Set-LiteDbBsonField -Document $dest -Name ([string]$key) -Value (Copy-LiteDbBsonValue -Value $sourceDoc[$key]) }
    return , $dest
}

function New-LiteDbGuidBsonDocument {
    param([string]$GuidString)
    $g = if ([string]::IsNullOrWhiteSpace($GuidString)) { [guid]::NewGuid().ToString() } else { $GuidString }
    $inner = New-Object LiteDB.BsonDocument
    Set-LiteDbBsonField -Document $inner -Name '$guid' -Value $g
    return , $inner
}

# ─────────────────────────────────────────────────────────────────────────────
# Playnite log watching helpers
# ─────────────────────────────────────────────────────────────────────────────

function ConvertFrom-PlayniteLogTimestamp {
    param([string]$TimestampText)
    $text = $TimestampText.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    foreach ($format in @('dd-MM HH:mm:ss.fff', 'dd-MM HH:mm:ss')) {
        try {
            $parsed = [datetime]::ParseExact($text, $format, $null)
            return Get-Date -Year (Get-Date).Year -Month $parsed.Month -Day $parsed.Day -Hour $parsed.Hour -Minute $parsed.Minute -Second $parsed.Second -Millisecond $parsed.Millisecond
        }
        catch { continue }
    }
    return $null
}

function Test-PlayniteLogLineIsRecent {
    param([string]$Line, [datetime]$StartedAfter)
    if ($Line -notmatch '^\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}') { return $false }
    $tsText = ($Line -split '\|', 2)[0].Trim()
    $ts = ConvertFrom-PlayniteLogTimestamp -TimestampText $tsText
    if (-not $ts) { return $false }
    return ($ts -ge $StartedAfter.AddSeconds(-2))
}

function Wait-PlayniteLibraryImportInLog {
    param(
        [string]$LogPath,
        [datetime]$StartedAfter,
        [int]$TimeoutMinutes,
        [scriptblock]$LogAction,
        [switch]$WaitForMetadata
    )
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $sawSteamImport = $false
    $sawEpicImport = $false
    $importDone = $false
    $metadataDone = $false
    $write = { param($Message, [string]$Level = "INFO"); if ($LogAction) { & $LogAction $Message $Level } }
    if ($WaitForMetadata) {
        & $write ("Watching {0} for Steam/Epic import + metadata (up to {1} min)..." -f $LogPath, $TimeoutMinutes)
    }
    else {
        & $write ("Watching {0} for Steam/Epic import (up to {1} min)..." -f $LogPath, $TimeoutMinutes)
    }
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (-not (Test-Path -LiteralPath $LogPath)) { continue }
        foreach ($line in (Get-Content -LiteralPath $LogPath -Tail 400 -ErrorAction SilentlyContinue)) {
            if (-not (Test-PlayniteLogLineIsRecent -Line $line -StartedAfter $StartedAfter)) { continue }
            if ($line -match 'Importing games from Steam plugin') {
                if (-not $sawSteamImport) {
                    $sawSteamImport = $true
                    & $write 'Steam library import started.'
                }
            }
            if ($line -match 'Importing games from Epic plugin') {
                if (-not $sawEpicImport) {
                    $sawEpicImport = $true
                    & $write 'Epic library import started.'
                }
            }
            if ($line -match '(?i)(metadata download (completed|finished|complete)|finished (downloading )?metadata|all metadata downloaded)') {
                if (-not $metadataDone) { $metadataDone = $true; & $write 'Playnite metadata download reported in log.' }
            }
            if ($line -match 'Setting Sorting Name for \d+ new games') {
                # Playnite emits this after library import + metadata pass for new games.
                if (-not $importDone -or -not $metadataDone) {
                    $importDone = $true
                    $metadataDone = $true
                    & $write 'Library import + metadata complete (sorting names finished).'
                }
            }
            elseif (-not $importDone) {
                if ($line -match 'Steam library import finished|Steam library update finished') { $importDone = $true; & $write 'Steam library import finished.' }
                elseif ($line -match 'Epic library import finished|Epic library update finished') { $importDone = $true; & $write 'Epic library import finished.' }
                elseif ($line -match 'Finished Library Install Size scan' -and ($sawSteamImport -or $sawEpicImport)) { $importDone = $true; & $write 'Library import complete (install size scan after plugin import).' }
            }
            if ($WaitForMetadata) {
                if ($metadataDone -and ($importDone -or $sawSteamImport -or $sawEpicImport)) { return $true }
            }
            elseif ($importDone) { return $true }
        }
    }
    if ($WaitForMetadata -and $importDone) {
        & $write -Message 'Library import finished but metadata completion was not seen in playnite.log before timeout. Covers may still download in Playnite.' -Level 'WARN'
        return $true
    }
    if ($sawSteamImport -or $sawEpicImport) {
        $partialMsg = 'Import started in log but completion line not seen (Steam: {0}, Epic: {1}).' -f $sawSteamImport, $sawEpicImport
        & $write -Message $partialMsg -Level 'WARN'
        return $true
    }
    $timeoutMsg = 'No Steam/Epic import activity in log within {0} minute(s).' -f $TimeoutMinutes
    & $write -Message $timeoutMsg -Level 'WARN'
    return $false
}

# ─────────────────────────────────────────────────────────────────────────────
# Game records, play actions, LiteDB document builders and editors
# ─────────────────────────────────────────────────────────────────────────────

function Get-PlayActionsFromGameDocument {
    param($Doc)
    $actions = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Doc -or -not $Doc.ContainsKey('GameActions')) { return , @() }
    $raw = $Doc['GameActions']
    if ($null -eq $raw) { return , @() }
    $array = $null
    if ($raw -is [LiteDB.BsonArray]) { $array = $raw }
    elseif ($raw -is [LiteDB.BsonValue] -and $raw.IsArray) { $array = $raw.AsArray }
    if ($null -eq $array) { return , @() }
    foreach ($entry in $array) {
        if ($null -eq $entry) { continue }
        $actionDoc = $null
        if ($entry -is [LiteDB.BsonValue] -and $entry.IsDocument) { $actionDoc = $entry.AsDocument }
        elseif ($entry -is [LiteDB.BsonDocument]) { $actionDoc = $entry }
        if ($null -eq $actionDoc) { continue }
        $path = Get-BsonValueAsString -Value $actionDoc['Path']
        [void]$actions.Add([PSCustomObject]@{
            Name = Get-BsonValueAsString -Value $actionDoc['Name']
            Path = $path
            WorkingDir = Get-BsonValueAsString -Value $actionDoc['WorkingDir']
            IsPlayAction = Get-BsonValueAsBool -Value $actionDoc['IsPlayAction']
            Type = Get-BsonValueAsInt -Value $actionDoc['Type']
        })
    }
    return , $actions.ToArray()
}

function Get-PrimaryPlayAction {
    param([object[]]$Actions)
    if (-not $Actions -or $Actions.Count -eq 0) { return $null }
    $play = @($Actions | Where-Object { $_.IsPlayAction -and -not [string]::IsNullOrWhiteSpace($_.Path) })
    if ($play.Count -gt 0) { return $play[0] }
    return @($Actions | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } | Select-Object -First 1)
}

function New-PlayniteGameRecordFromBsonDocument {
    param($Doc)
    $id = Get-BsonValueAsGuid -Value $Doc['_id']
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $actions = Get-PlayActionsFromGameDocument -Doc $Doc
    $primary = Get-PrimaryPlayAction -Actions $actions
    return [PSCustomObject]@{
        Id = $id
        GameId = Get-BsonValueAsString -Value $Doc['GameId']
        Name = Get-BsonValueAsString -Value $Doc['Name']
        InstallDirectory = Get-BsonValueAsString -Value $Doc['InstallDirectory']
        PluginId = Get-BsonValueAsGuid -Value $Doc['PluginId']
        PlayActions = $actions
        PrimaryPlayPath = if ($primary) { $primary.Path } else { "" }
        PrimaryWorkingDir = if ($primary) { $primary.WorkingDir } else { "" }
        LiteDbDocument = $Doc
    }
}

function Get-PlayniteGamesWithPlayActions {
    param([string]$InstallDir, [scriptblock]$LogAction, [switch]$StopPlayniteFirst)
    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $dbPath)) { throw "Playnite library database not found: $dbPath" }
    if ($StopPlayniteFirst.IsPresent) { Ensure-PlayniteLibraryDatabaseUnlocked -InstallDir $InstallDir -LogAction $LogAction }
    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir
    if ($LogAction) { & $LogAction "Reading games with play actions from: $dbPath" }
    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)
    $records = New-Object System.Collections.Generic.List[object]
    try {
        $collection = $db.GetCollection("Game")
        foreach ($doc in $collection.FindAll()) {
            $record = New-PlayniteGameRecordFromBsonDocument -Doc $doc
            if ($record) { [void]$records.Add($record) }
        }
    }
    finally { $db.Dispose() }
    return , $records.ToArray()
}

function Normalize-PlayniteGamesArray {
    param([object]$Games)
    if ($null -eq $Games) { return @() }
    $arr = @($Games)
    while ($arr.Count -eq 1 -and ($arr[0] -is [object[]] -or $arr[0] -is [System.Array])) { $arr = @($arr[0]) }
    return $arr
}

function Get-SinglePlayniteGameRecord {
    param([object]$Game)
    if ($null -eq $Game) { return $null }
    if ($Game -is [object[]] -or $Game -is [System.Array] -or $Game -is [System.Collections.IList]) {
        return @($Game) | Where-Object { $_ -and $_.Id } | Select-Object -First 1
    }
    return $Game
}

function Get-PlayniteNativeGameBsonTemplateDocument {
    param($Collection)
    foreach ($doc in $collection.FindAll()) {
        $pluginId = Get-BsonValueAsGuid -Value $doc['PluginId']
        if ($pluginId -ieq $script:PlayniteManualPluginId) { continue }
        if (-not $doc.ContainsKey('GameActions')) { continue }
        $actions = Get-RawPlayActionDocumentsFromGameDocument -Doc $doc
        if ($actions.Count -gt 0) { return $doc }
    }
    return $null
}

function Get-RawPlayActionDocumentsFromGameDocument {
    param($Doc)
    $result = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Doc -or -not $Doc.ContainsKey('GameActions')) { return , @() }
    $raw = $Doc['GameActions']
    $array = $null
    if ($raw -is [LiteDB.BsonArray]) { $array = $raw }
    elseif ($raw -is [LiteDB.BsonValue] -and $raw.IsArray) { $array = $raw.AsArray }
    if ($null -eq $array) { return , @() }
    foreach ($entry in $array) {
        if ($entry -is [LiteDB.BsonValue] -and $entry.IsDocument) { [void]$result.Add($entry.AsDocument) }
        elseif ($entry -is [LiteDB.BsonDocument]) { [void]$result.Add($entry) }
    }
    return , $result.ToArray()
}

function Get-PlayniteTemplatePlayActionDocument {
    param($TemplateGameDocument)
    $actions = Get-RawPlayActionDocumentsFromGameDocument -Doc $TemplateGameDocument
    if ($actions.Count -eq 0) { return $null }
    foreach ($action in $actions) {
        $path = Get-BsonValueAsString -Value $action['Path']
        if (-not [string]::IsNullOrWhiteSpace($path)) { return $action }
    }
    return $actions[0]
}

function New-PlayniteFilePlayActionBson {
    param(
        [string]$ExePath,
        [string]$WorkingDir,
        [string]$Arguments = '',
        $TemplateAction = $null
    )
    $work = $WorkingDir
    if ([string]::IsNullOrWhiteSpace($work)) { $work = Split-Path -Path $ExePath -Parent }
    if ($TemplateAction) { $action = Copy-LiteDbBsonDocument -Source $TemplateAction }
    else {
        $action = New-Object LiteDB.BsonDocument
        Set-LiteDbBsonField -Document $action -Name 'Type' -Value 'File'
        Set-LiteDbBsonField -Document $action -Name 'TrackingMode' -Value 'Default'
        Set-LiteDbBsonField -Document $action -Name 'OverrideDefaultArgs' -Value $false
        Set-LiteDbBsonField -Document $action -Name 'EmulatorId' -Value ([guid]::Empty)
        Set-LiteDbBsonField -Document $action -Name 'InitialTrackingDelay' -Value 0
        Set-LiteDbBsonField -Document $action -Name 'TrackingFrequency' -Value 2000
    }
    Set-LiteDbBsonField -Document $action -Name 'Type' -Value 'File'
    Set-LiteDbBsonField -Document $action -Name 'Path' -Value $ExePath
    Set-LiteDbBsonField -Document $action -Name 'WorkingDir' -Value $work
    Set-LiteDbBsonField -Document $action -Name 'IsPlayAction' -Value $true
    Set-LiteDbBsonField -Document $action -Name 'Name' -Value 'Play'
    if (-not [string]::IsNullOrWhiteSpace($Arguments)) {
        Set-LiteDbBsonField -Document $action -Name 'Arguments' -Value $Arguments
        Set-LiteDbBsonField -Document $action -Name 'OverrideDefaultArgs' -Value $true
    }
    elseif ($action.ContainsKey('Arguments') -and [string]::IsNullOrWhiteSpace($Arguments)) {
        # Keep existing Arguments from template when not overriding via param.
    }
    return , $action
}

function New-PlayniteManualGameBsonDocument {
    param([string]$Title, [string]$ExePath, [string]$GameId = "", $TemplateGameDocument = $null)
    $installDir = Split-Path -Path $ExePath -Parent
    $newId = if ([string]::IsNullOrWhiteSpace($GameId)) { [guid]::NewGuid() } else { [guid]::Parse($GameId) }
    $templateAction = $null
    if ($TemplateGameDocument) {
        $templateAction = Get-PlayniteTemplatePlayActionDocument -TemplateGameDocument $TemplateGameDocument
        $doc = Copy-LiteDbBsonDocument -Source $TemplateGameDocument
    }
    else { $doc = New-Object LiteDB.BsonDocument }
    Set-LiteDbBsonField -Document $doc -Name '_id' -Value $newId
    Set-LiteDbBsonField -Document $doc -Name 'Name' -Value $Title
    Set-LiteDbBsonField -Document $doc -Name 'PluginId' -Value ([guid]::Empty)
    Set-LiteDbBsonField -Document $doc -Name 'GameId' -Value $newId.ToString()
    Set-LiteDbBsonField -Document $doc -Name 'IsInstalled' -Value $true
    Set-LiteDbBsonField -Document $doc -Name 'InstallDirectory' -Value $installDir
    Set-LiteDbBsonField -Document $doc -Name 'IncludeLibraryPluginAction' -Value $false
    if ($doc.ContainsKey('IsCustomGame')) { [void]$doc.Remove('IsCustomGame') }
    $action = New-PlayniteFilePlayActionBson -ExePath $ExePath -WorkingDir $installDir -TemplateAction $templateAction
    $arr = New-Object LiteDB.BsonArray
    Add-LiteDbBsonArrayItem -Array $arr -Value $action
    Set-LiteDbBsonField -Document $doc -Name 'GameActions' -Value $arr
    return , $doc
}

function Update-PlayniteGamePlayActionInDocument {
    param($Doc, [string]$ExePath, [string]$Title)
    $installDir = Split-Path -Path $ExePath -Parent
    $leaf = [System.IO.Path]::GetFileName($ExePath)
    if ($leaf -match '\.(cmd|bat|ps1)$') {
        if ([string]::IsNullOrWhiteSpace($installDir)) { $installDir = Split-Path -Path $ExePath -Parent }
    }
    Set-LiteDbBsonField -Document $Doc -Name 'Name' -Value $Title
    Set-LiteDbBsonField -Document $Doc -Name 'InstallDirectory' -Value $installDir
    Set-LiteDbBsonField -Document $Doc -Name 'IsInstalled' -Value $true
    Set-LiteDbBsonField -Document $Doc -Name 'IncludeLibraryPluginAction' -Value $false
    $templateAction = $null
    $existingActions = Get-RawPlayActionDocumentsFromGameDocument -Doc $Doc
    if ($existingActions.Count -gt 0) { $templateAction = $existingActions[0] }
    $action = New-PlayniteFilePlayActionBson -ExePath $ExePath -WorkingDir $installDir -TemplateAction $templateAction
    $arr = New-Object LiteDB.BsonArray
    Add-LiteDbBsonArrayItem -Array $arr -Value $action
    Set-LiteDbBsonField -Document $Doc -Name 'GameActions' -Value $arr
}

function Remove-PlayniteManualGamesFromLiteDb {
    param([string]$InstallDir, [scriptblock]$LogAction)
    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force
    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    if (-not (Test-Path -LiteralPath $dbPath)) { throw "Playnite library database not found: $dbPath" }
    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir
    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)
    $removed = 0
    try {
        $collection = $db.GetCollection("Game")
        foreach ($doc in @($collection.FindAll())) {
            $pluginId = Get-BsonValueAsGuid -Value $doc['PluginId']
            if ($pluginId -ieq $script:PlayniteManualPluginId) {
                [void]$collection.Delete($doc['_id'])
                $removed++
                if ($LogAction) {
                    $title = Get-BsonValueAsString -Value $doc['Name']
                    & $LogAction "Removed manual desktop game from library DB: $title"
                }
            }
        }
    }
    finally { $db.Dispose() }
    if ($LogAction) { & $LogAction "Removed $removed manual desktop game(s) from games.db" }
    return $removed
}

function Find-PlayniteGameForAllowlistExe {
    param([object[]]$Games, [string]$ExeName, [string]$ScanRoot = "")
    $Games = Normalize-PlayniteGamesArray -Games $Games
    if ([string]::IsNullOrWhiteSpace($ExeName)) { return $null }
    $exeKey = $ExeName.ToLowerInvariant()
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($game in $Games) {
        $path = $game.PrimaryPlayPath
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (([System.IO.Path]::GetFileName($path)).ToLowerInvariant() -ne $exeKey) { continue }
        if ($ScanRoot -and -not (Test-PathUnderScanRoot -Path $path -ScanRoot $ScanRoot)) { continue }
        [void]$candidates.Add($game)
    }
    if ($candidates.Count -eq 0) { return $null }
    return Get-SinglePlayniteGameRecord -Game ($candidates | Sort-Object {
        if ($_.PrimaryPlayPath -and (Test-Path -LiteralPath $_.PrimaryPlayPath)) { (Get-Item -LiteralPath $_.PrimaryPlayPath).LastWriteTimeUtc } else { [datetime]::MinValue }
    } -Descending | Select-Object -First 1)
}

function Get-PlayniteGameRecordsFromLiteDb {
    param(
        [string]$InstallDir = "",
        [string]$DataDirectory = "",
        [scriptblock]$LogAction
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir) -and [string]::IsNullOrWhiteSpace($DataDirectory)) {
        throw "Get-PlayniteGameRecordsFromLiteDb requires InstallDir or DataDirectory."
    }

    if ([string]::IsNullOrWhiteSpace($InstallDir)) {
        $InstallDir = $DataDirectory
    }

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir -DataDirectory $DataDirectory
    if (-not (Test-Path -LiteralPath $dbPath)) {
        throw "Playnite library database not found: $dbPath"
    }
    if (-not (Test-PlayniteLiteDbDatabase -Path $dbPath)) {
        throw "Playnite library file is not a LiteDB database (Playnite 10+ format): $dbPath"
    }

    Initialize-LiteDbFromPlayniteInstall -InstallDir $InstallDir

    if ($LogAction) {
        & $LogAction "Reading games from LiteDB: $dbPath"
    }

    $connectionString = Get-PlayniteLiteDbConnectionString -DbPath $dbPath
    $db = New-Object LiteDB.LiteDatabase($connectionString)
    $records = New-Object System.Collections.Generic.List[object]

    try {
        $collection = $db.GetCollection("Game")
        foreach ($doc in $collection.FindAll()) {
            $id = Get-BsonValueAsGuid -Value $doc['_id']
            if ([string]::IsNullOrWhiteSpace($id)) {
                continue
            }

            [void]$records.Add([PSCustomObject]@{
                    Id               = $id
                    GameId           = Get-BsonValueAsString -Value $doc['GameId']
                    Name             = Get-BsonValueAsString -Value $doc['Name']
                    InstallDirectory = Get-BsonValueAsString -Value $doc['InstallDirectory']
                    PluginId         = Get-BsonValueAsGuid -Value $doc['PluginId']
                })
        }
    }
    finally {
        $db.Dispose()
    }

    return $records.ToArray()
}

# ─────────────────────────────────────────────────────────────────────────────
# Database session management and Playnite app lifecycle
# ─────────────────────────────────────────────────────────────────────────────

function Ensure-PlayniteLibraryDatabaseUnlocked {
    param(
        [string]$InstallDir,
        [int]$WaitSeconds = 30,
        [scriptblock]$LogAction
    )

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    if ($LogAction) {
        & $LogAction "Stopping Playnite so games.db can be updated..."
    }
    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds $WaitSeconds -Force

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    $reason = Get-PlayniteLiteDbInvalidReason -Path $dbPath
    if ($reason -eq 'locked') {
        if ($LogAction) {
            & $LogAction "games.db still locked; forcing Playnite to close..." "WARN"
        }
        Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds $WaitSeconds -Force
        Start-Sleep -Seconds 2
        $reason = Get-PlayniteLiteDbInvalidReason -Path $dbPath
        if ($reason -eq 'locked') {
            throw "Playnite library database is locked: $dbPath Close Playnite manually and try again."
        }
    }
}

function Stop-PlayniteApplication {
    param(
        [string]$PlayniteExe = "",
        [string]$InstallDir = "",
        [int]$WaitSeconds = 20,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace($InstallDir) -and $PlayniteExe -and (Test-Path -LiteralPath $PlayniteExe)) {
        $InstallDir = Split-Path -Path $PlayniteExe -Parent
    }

    $processNames = @("Playnite.DesktopApp", "Playnite.FullscreenApp")
    $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)

    if (-not $Force -and $running.Count -gt 0 -and $PlayniteExe -and (Test-Path -LiteralPath $PlayniteExe)) {
        try {
            Start-PlayniteProcess -PlayniteExe $PlayniteExe -ArgumentList "--shutdown" -WindowStyle Hidden | Out-Null
        }
        catch { }

        $graceDeadline = [datetime]::UtcNow.AddSeconds([Math]::Min(12, $WaitSeconds))
        while ([datetime]::UtcNow -lt $graceDeadline) {
            $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
            if ($running.Count -eq 0) {
                break
            }
            Start-Sleep -Milliseconds 500
        }
    }

    Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    if ($InstallDir) {
        try {
            $installPrefix = $InstallDir.TrimEnd('\') + '\'
            Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.ExecutablePath -and
                    $_.ExecutablePath.StartsWith($installPrefix, [StringComparison]::OrdinalIgnoreCase) -and
                    $_.Name -match '^Playnite\.'
                } |
                ForEach-Object {
                    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                }
        }
        catch { }
    }

    $deadline = [datetime]::UtcNow.AddSeconds($WaitSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        $running = @(Get-Process -Name $processNames -ErrorAction SilentlyContinue)
        if ($running.Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 500
    }

    Get-Process -Name $processNames -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Move-PlayniteLibraryDatabaseAside {
    param(
        [Parameter(Mandatory = $true)]
        [string]$DbPath,
        [string]$PlayniteExe = "",
        [string]$InstallDir = "",
        [int]$MaxAttempts = 6,
        [scriptblock]$LogAction
    )

    if (-not (Test-Path -LiteralPath $DbPath)) {
        return $null
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupPath = "$DbPath.invalid-$stamp"
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if ($LogAction -and $attempt -gt 1) {
            & $LogAction "games.db still locked; force-stopping Playnite (attempt $attempt / $MaxAttempts)..." "WARN"
        }

        Stop-PlayniteApplication -PlayniteExe $PlayniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force
        Start-Sleep -Seconds ([Math]::Min(2 * $attempt, 8))

        try {
            Move-Item -LiteralPath $DbPath -Destination $backupPath -Force -ErrorAction Stop
            if ($LogAction) {
                & $LogAction "Backed up invalid library to: $backupPath"
            }
            return $backupPath
        }
        catch {
            $lastError = $_
            if ($_.Exception.Message -notmatch 'being used by another process') {
                throw
            }
        }
    }

    throw "Could not move locked Playnite library database after $MaxAttempts attempt(s): $DbPath. $($lastError.Exception.Message)"
}

function Invoke-PlayniteLibraryDatabaseBootstrap {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,
        [int]$MaxWaitSeconds = 90,
        [scriptblock]$LogAction
    )

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir
    $libraryDir = Split-Path -Path $dbPath -Parent

    if (-not (Test-Path -LiteralPath $libraryDir)) {
        New-Item -ItemType Directory -Path $libraryDir -Force | Out-Null
    }

    if ($LogAction) {
        & $LogAction "Bootstrapping Playnite library database: $dbPath"
    }

    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force

    $initArgs = @("--startdesktop", "--hidesplashscreen", "--safestartup", "--nolibupdate")
    $init = Start-PlayniteProcess -PlayniteExe $playniteExe -ArgumentList $initArgs -PassThru

    $deadline = (Get-Date).AddSeconds($MaxWaitSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-PlayniteLiteDbDatabase -Path $dbPath) {
            if ($LogAction) {
                & $LogAction "Library database created: $dbPath"
            }
            break
        }
        if ($init.HasExited) {
            if ($LogAction) {
                & $LogAction "Playnite exited during library bootstrap." "WARN"
            }
            break
        }
    }

    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force
    if (-not $init.HasExited) {
        try { $init.WaitForExit(10000) } catch { }
    }

    return (Test-PlayniteLiteDbDatabase -Path $dbPath)
}

function Repair-PlayniteLibraryDatabaseIfNeeded {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallDir,
        [scriptblock]$LogAction
    )

    $playniteExe = Get-PlayniteDesktopExe -InstallDir $InstallDir
    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir

    if ($LogAction) {
        & $LogAction "Force-stopping Playnite before library database check..."
    }
    Stop-PlayniteApplication -PlayniteExe $playniteExe -InstallDir $InstallDir -WaitSeconds 30 -Force
    Start-Sleep -Seconds 2

    if (Test-PlayniteLiteDbDatabase -Path $dbPath) {
        if ($LogAction) {
            & $LogAction "Playnite library database is valid after ensuring Playnite is closed: $dbPath"
        }
        return [PSCustomObject]@{
            Success              = $true
            Repaired             = $false
            NeedsLibraryUpdate   = $false
            DatabasePath         = $dbPath
            InvalidReason        = $null
        }
    }

    $reason = Get-PlayniteLiteDbInvalidReason -Path $dbPath
    $reasonText = if ($reason) { $reason } else { "unknown" }

    if ($LogAction) {
        $detail = switch ($reason) {
            "sqlite" { "SQLite (pre-Playnite 10) library at $dbPath" }
            "missing" { "library database missing at $dbPath" }
            "too_small" { "library database too small or empty at $dbPath" }
            "locked" { "library database locked at $dbPath" }
            default { "invalid library database at $dbPath ($reasonText)" }
        }
        & $LogAction "Repairing Playnite library: $detail" "WARN"
    }

    if (Test-Path -LiteralPath $dbPath) {
        $backupPath = Move-PlayniteLibraryDatabaseAside `
            -DbPath $dbPath `
            -PlayniteExe $playniteExe `
            -InstallDir $InstallDir `
            -LogAction $LogAction

        if ($backupPath -match '\.invalid-(\d{8}-\d{6})$') {
            $stamp = $Matches[1]
        }
        else {
            $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
        }

        foreach ($suffix in @("-lock", ".backup")) {
            $sidecar = "$dbPath$suffix"
            if (Test-Path -LiteralPath $sidecar) {
                $sidecarBackup = "$sidecar.invalid-$stamp"
                try {
                    Move-Item -LiteralPath $sidecar -Destination $sidecarBackup -Force -ErrorAction Stop
                }
                catch {
                    if ($LogAction) {
                        & $LogAction "Could not move sidecar file $sidecar : $($_.Exception.Message)" "WARN"
                    }
                }
            }
        }
    }

    $bootOk = Invoke-PlayniteLibraryDatabaseBootstrap -InstallDir $InstallDir -LogAction $LogAction
    return [PSCustomObject]@{
        Success              = $bootOk
        Repaired             = $true
        NeedsLibraryUpdate   = $bootOk
        DatabasePath         = $dbPath
        InvalidReason        = $reasonText
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Library stats
# ─────────────────────────────────────────────────────────────────────────────

function Get-PlayniteLibraryGameStats {
    param(
        [string]$InstallDir = "",
        [string]$DataDirectory = ""
    )

    $dbPath = Get-PlayniteLibraryGamesDbPath -InstallDir $InstallDir -DataDirectory $DataDirectory
    $stats = @{
        DbExists   = (Test-Path -LiteralPath $dbPath)
        TotalGames = 0
        SteamGames = 0
        EpicGames  = 0
        DbSizeKb   = 0
    }

    if (-not $stats.DbExists) {
        return $stats
    }

    $stats.DbSizeKb = [math]::Round((Get-Item -LiteralPath $dbPath).Length / 1KB, 1)
    if (-not (Test-PlayniteLiteDbDatabase -Path $dbPath)) {
        return $stats
    }

    $games = Get-PlayniteGameRecordsFromLiteDb -InstallDir $InstallDir -DataDirectory $DataDirectory
    $stats.TotalGames = $games.Count
    $stats.SteamGames = @($games | Where-Object { $_.PluginId -ieq $script:PlayniteSteamPluginId }).Count
    $stats.EpicGames = @($games | Where-Object { $_.PluginId -ieq $script:PlayniteEpicPluginId }).Count
    return $stats
}

Export-ModuleMember -Function *
