# Verifies LiteDB BSON helpers used by desktop app import (run from repo root).
$ErrorActionPreference = 'Stop'
$repoRoot = $PSScriptRoot
. (Join-Path $repoRoot 'Playnite-Common.ps1')

$liteDbDll = $null
foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Playnite\LiteDB.dll'),
        'Z:\Playnite\LiteDB.dll',
        'C:\Playnite\LiteDB.dll'
    )) {
    if (Test-Path -LiteralPath $candidate) {
        $liteDbDll = $candidate
        break
    }
}

if (-not $liteDbDll) {
    $toolsDir = Join-Path $repoRoot 'tools\litedb'
    $liteDbDll = Join-Path $toolsDir 'LiteDB.dll'
    if (-not (Test-Path -LiteralPath $liteDbDll)) {
        New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
        $zip = Join-Path $env:TEMP 'LiteDB.zip'
        $url = 'https://www.nuget.org/api/v2/package/LiteDB/4.1.4'
        Write-Host 'Downloading LiteDB 4.1.4 for BSON smoke test...'
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath (Join-Path $env:TEMP 'LiteDB.nupkg') -Force
        $libDll = Join-Path $env:TEMP 'LiteDB.nupkg\lib\net40\LiteDB.dll'
        Copy-Item -LiteralPath $libDll -Destination $liteDbDll -Force
    }
}

Initialize-LiteDbFromPlayniteInstall -InstallDir (Split-Path -Parent $liteDbDll)

# Must not throw (PowerShell indexer assignment used to fail here).
$exe = 'Z:\Adobe\Acrobat DC\Acrobat\x86\Acrobat\Acrobat.exe'
$doc = New-PlayniteManualGameBsonDocument -Title 'Adobe Acrobat' -ExePath $exe -GameId '5cd76dee-1eba-40cd-adce-f017aaa9f0eb'

$id = Get-BsonValueAsGuid -Value $doc['_id']
if ($id -ne '5cd76dee-1eba-40cd-adce-f017aaa9f0eb') {
    throw "_id GUID mismatch: $id"
}

$pluginId = Get-BsonValueAsGuid -Value $doc['PluginId']
if ($pluginId -ne $script:PlayniteManualPluginId) {
    throw "PluginId mismatch: $pluginId"
}

$actions = @(Get-PlayActionsFromGameDocument -Doc $doc)
if ($actions.Count -ne 1 -or $actions[0].Path -cne $exe) {
    throw "GameActions mismatch: $($actions | ConvertTo-Json -Compress)"
}

$typeVal = Get-BsonValueAsString -Value $doc['GameActions'].AsArray[0].AsDocument['Type']
if ($typeVal -cne 'File') {
    throw "GameAction Type should be 'File' for Playnite mapper, got '$typeVal'"
}
if ($doc.ContainsKey('IsCustomGame')) {
    throw 'IsCustomGame must not be stored in BSON (Playnite computes it from PluginId)'
}

$dbFile = Join-Path $env:TEMP "playnitewatcher-bson-test-$([guid]::NewGuid().ToString('N')).db"
$connectionString = "Filename=$dbFile;Mode=Exclusive;Cache Size=0"
try {
    $db = New-Object LiteDB.LiteDatabase($connectionString)
}
catch {
    if ($_.Exception.Message -match 'System\.Buffers') {
        Write-Host 'OK: BSON document build passed (skipped DB open; LiteDB 4.1.4 needs System.Buffers in this harness).' -ForegroundColor Green
        return
    }
    throw
}
try {
    $collection = $db.GetCollection('Game')
    try {
        [void]$collection.Insert($doc)
    }
    catch {
        if ($_.Exception.Message -match 'System\.Buffers') {
            Write-Host 'OK: BSON document build passed (skipped DB insert in test harness; Playnite ships System.Buffers).' -ForegroundColor Green
            return
        }
        throw
    }
    $readBack = $collection.FindById($doc['_id'])
    if (-not $readBack) {
        throw 'Insert/read round-trip failed: document not found by _id.'
    }
    $readId = Get-BsonValueAsGuid -Value $readBack['_id']
    if ($readId -ne $id) {
        throw "Round-trip _id mismatch: $readId"
    }
    Write-Host 'OK: BSON helpers + LiteDB insert round-trip passed.' -ForegroundColor Green
}
finally {
    $db.Dispose()
    Remove-Item -LiteralPath $dbFile -Force -ErrorAction SilentlyContinue
}
