#Requires -Version 5.1
<#
    Shared headless Sunshine export logic (Steam/Epic Playnite entries).
    Same CRC AppID algorithm as Add-SteamGames.ps1 / SunshineAppExport.psm1.
#>

$script:SunshineExportCoreRoot = $PSScriptRoot
if (-not (Get-Command Test-IsAdministrator -ErrorAction SilentlyContinue)) {
    . (Join-Path $script:SunshineExportCoreRoot "..\Playnite-Common.ps1")
}

$script:SunshineEventLogsUndo = 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Program Files\Sunshine\scripts\eventLogs.ps1"'

function Get-Crc32 {
    param([byte[]]$Bytes)
    $table = New-Object 'UInt32[]' 256
    for ($i = 0; $i -lt 256; $i++) {
        [int64]$crc = $i
        for ($j = 0; $j -lt 8; $j++) {
            if (($crc -band 1) -ne 0) {
                $crc = ((0xEDB88320L -bxor ($crc -shr 1)) -band 0xFFFFFFFFL)
            }
            else {
                $crc = (($crc -shr 1) -band 0xFFFFFFFFL)
            }
        }
        $table[$i] = [uint32]$crc
    }
    [int64]$crc = 0xFFFFFFFFL
    foreach ($b in $Bytes) {
        $idx = (($crc -bxor [int64]$b) -band 0xFFL)
        $crc = (([int64]$table[[int]$idx] -bxor ($crc -shr 8)) -band 0xFFFFFFFFL)
    }
    return [uint32](($crc -bxor 0xFFFFFFFFL) -band 0xFFFFFFFFL)
}

function Get-SignedAbsInt32String {
    param([uint32]$U32)
    $bytes = [BitConverter]::GetBytes($U32)
    $i32 = [BitConverter]::ToInt32($bytes, 0)
    if ($i32 -eq [int32]::MinValue) { return "2147483648" }
    return ([Math]::Abs($i32)).ToString()
}

function Get-AppIdFromName {
    param([Parameter(Mandatory = $true)][string]$AppName)
    $inputStr = $AppName
    $crc = Get-Crc32 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($inputStr))
    return Get-SignedAbsInt32String -U32 $crc
}

function Read-SunshineAppsJson {
    param([string]$AppsPath)

    if (-not (Test-Path -LiteralPath $AppsPath)) {
        return [PSCustomObject]@{ env = @{}; apps = @() }
    }

    $raw = Get-Content -LiteralPath $AppsPath -Raw -Encoding UTF8 -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [PSCustomObject]@{ env = @{}; apps = @() }
    }

    $parsed = $raw | ConvertFrom-Json
    if ($null -eq $parsed) {
        return [PSCustomObject]@{ env = @{}; apps = @() }
    }

    if ($null -eq $parsed.apps) {
        $parsed | Add-Member -NotePropertyName apps -NotePropertyValue @() -Force
    }
    elseif ($parsed.apps -isnot [System.Array]) {
        $parsed.apps = @($parsed.apps)
    }

    $parsed.apps = @($parsed.apps | Where-Object { $null -ne $_ })
    return $parsed
}

function Test-PrepCmdUsesEventLogs {
    param($App)
    if (-not $App.'prep-cmd') { return $false }
    foreach ($prep in @($App.'prep-cmd')) {
        if ($prep.undo -like '*eventLogs.ps1*') { return $true }
    }
    return $false
}

function Get-PlayniteSunshineNameId {
    param($Game)
    if ($Game.SourceLabel -eq 'Desktop') {
        if (-not [string]::IsNullOrWhiteSpace($Game.NameId)) { return $Game.NameId.ToString() }
        return $null
    }
    if ($Game.SourceLabel -eq 'Steam') {
        if (-not [string]::IsNullOrWhiteSpace($Game.GameId)) { return $Game.GameId.ToString() }
        return $null
    }
    if ($Game.SourceLabel -eq 'Epic') {
        if (-not [string]::IsNullOrWhiteSpace($Game.InstallDirectory)) {
            $leaf = [System.IO.Path]::GetFileName($Game.InstallDirectory.TrimEnd('\', '/'))
            if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
        }
        if (-not [string]::IsNullOrWhiteSpace($Game.GameId)) { return $Game.GameId.ToString() }
        return $null
    }
    return $null
}

function Get-SteamEpicNameId {
    param($Game)
    return Get-PlayniteSunshineNameId -Game $Game
}

function New-SteamEpicSunshineApp {
    param(
        [string]$NameId,
        [string]$PlayniteId,
        [string]$KioskOutput
    )
    return [PSCustomObject]@{
        name                      = $NameId
        'playnite-id'             = $PlayniteId
        output                    = $KioskOutput
        'prep-cmd'                = @([PSCustomObject]@{
                do       = ""
                undo     = $script:SunshineEventLogsUndo
                elevated = $true
            })
        'auto-detach'             = $true
        'exclude-global-prep-cmd' = $false
        'exit-timeout'            = 5
        'image-path'              = ""
        elevated                  = $true
        'wait-all'                = $false
        'wait-exit'               = $false
    }
}

function Remove-PriorExportsForGame {
    param(
        [object]$Json,
        [string]$NameId,
        [string]$PlayniteId
    )
    $playniteIdLower = $PlayniteId.ToLowerInvariant()
    $filtered = New-Object System.Collections.Generic.List[object]
    foreach ($app in @($Json.apps)) {
        if ($null -eq $app) { continue }
        if ($app.name -eq $NameId -and (Test-PrepCmdUsesEventLogs -App $app)) { continue }
        if ($app.'playnite-id' -and ($app.'playnite-id'.ToString().ToLowerInvariant() -eq $playniteIdLower)) { continue }
        if ($app.'image-path' -match 'Apps\\' -and $app.'image-path' -match [regex]::Escape($PlayniteId)) { continue }
        [void]$filtered.Add($app)
    }
    [object[]]$Json.apps = $filtered.ToArray()
}

function Add-OrReplaceAppInJson {
    param(
        [object]$Json,
        [object]$NewApp
    )
    $replaced = $false
    $updated = New-Object System.Collections.Generic.List[object]
    foreach ($app in @($Json.apps)) {
        if ($null -eq $app) { continue }
        if ($app.name -eq $NewApp.name -and (Test-PrepCmdUsesEventLogs -App $app)) {
            $replaced = $true
            [void]$updated.Add($NewApp)
        }
        else {
            [void]$updated.Add($app)
        }
    }
    if (-not $replaced) {
        [void]$updated.Add($NewApp)
    }
    [object[]]$Json.apps = $updated.ToArray()
}

function ConvertTo-JsonSafe {
    param(
        $Object,
        [int]$Depth = 100
    )
    if ($null -eq $Object) {
        return '{}'
    }
    return ($Object | ConvertTo-Json -Depth $Depth)
}

function Write-SunshineExportWarn {
    param([string]$Message)
    if (Get-Command Write-ExportLog -ErrorAction SilentlyContinue) {
        Write-ExportLog $Message 'WARN'
    }
    else {
        Write-Host ("[WARN] {0}" -f $Message)
    }
}

function Resolve-SteamAppIdForExport {
    param($Game)

    $id = [string]$Game.GameId
    if ($id -match '^\d{1,10}$') {
        return $id
    }

    $installDir = [string]$Game.InstallDirectory
    if ([string]::IsNullOrWhiteSpace($installDir) -or -not (Test-Path -LiteralPath $installDir)) {
        return ''
    }

    $dir = $installDir.TrimEnd('\', '/')
    $steamapps = $null
    $leaf = Split-Path -LiteralPath $dir -Leaf
    $parent = Split-Path -LiteralPath $dir -Parent
    $grand = if ($parent) { Split-Path -LiteralPath $parent -Parent } else { $null }
    if ($parent -and $grand -and
        ((Split-Path -LiteralPath $parent -Leaf) -eq 'common') -and
        ((Split-Path -LiteralPath $grand -Leaf) -eq 'steamapps')) {
        $steamapps = $grand
    }

    if (-not $steamapps -or -not (Test-Path -LiteralPath $steamapps)) {
        return ''
    }

    foreach ($acf in Get-ChildItem -LiteralPath $steamapps -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue) {
        $raw = Get-Content -LiteralPath $acf.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $raw) { continue }
        if ($raw -notmatch '"installdir"\s+"([^"]+)"') { continue }
        if ($Matches[1] -ne $leaf) { continue }
        if ($acf.BaseName -match '^appmanifest_(\d+)$') {
            return $Matches[1]
        }
    }

    return ''
}

function Export-PlayniteLibraryToSunshine {
    param(
        [string]$PlayniteExe,
        [string]$AppsPath,
        [object[]]$Games
    )

    $counts = @{ Steam = 0; Epic = 0; Desktop = 0; Total = 0 }
    $resolvedAppIds = New-Object System.Collections.Generic.List[object]
    $appLaunchLinesSteam = New-Object System.Collections.Generic.List[string]
    $appLaunchLinesEpic = New-Object System.Collections.Generic.List[string]
    $appLaunchLinesDesktop = New-Object System.Collections.Generic.List[string]

    $json = Read-SunshineAppsJson -AppsPath $AppsPath
    $playniteCmdPrefix = "&`"$PlayniteExe`" --start "
    $steamExe = $null
    if (Get-Command Resolve-NextGpuSteamExePath -ErrorAction SilentlyContinue) {
        $steamExe = Resolve-NextGpuSteamExePath -PreferNearPath $PlayniteExe
    }

    foreach ($game in $Games) {
        $counts.Total++
        $nameId = Get-PlayniteSunshineNameId -Game $game
        if ([string]::IsNullOrWhiteSpace($nameId)) {
            continue
        }

        $isDesktop = ($game.SourceLabel -eq 'Desktop')
        $isSteam = ($game.SourceLabel -eq 'Steam')
        $desktopExe = ''
        $desktopArgs = ''
        $steamAppId = ''
        if ($isDesktop) {
            $desktopExe = [string]$game.PrimaryPlayPath
            if ([string]::IsNullOrWhiteSpace($desktopExe) -and $game.Exe -and $game.InstallDirectory) {
                $desktopExe = Join-Path $game.InstallDirectory $game.Exe
            }
            if ([string]::IsNullOrWhiteSpace($desktopExe)) {
                continue
            }
            $desktopArgs = if ($game.PrimaryPlayArgs) { [string]$game.PrimaryPlayArgs } else { '' }
        }
        elseif ($isSteam) {
            $steamAppId = Resolve-SteamAppIdForExport -Game $game
            if (-not $steamExe -or [string]::IsNullOrWhiteSpace($steamAppId)) {
                $why = if (-not $steamExe) { 'steam.exe not found' } else { "no numeric Steam AppID (GameId='$($game.GameId)')" }
                Write-SunshineExportWarn "Skipping Steam export for '$($game.Name)': $why. Will not fall back to Playnite --start."
                Remove-PriorExportsForGame -Json $json -NameId $nameId -PlayniteId $game.Id.ToString()
                continue
            }
        }

        Remove-PriorExportsForGame -Json $json -NameId $nameId -PlayniteId $game.Id.ToString()

        $kioskOutput = if ($game.SourceLabel -eq 'Epic') { "$($game.Id).kiosk.log" } else { "$nameId.kiosk.log" }
        $newApp = New-SteamEpicSunshineApp -NameId $nameId -PlayniteId $game.Id.ToString() -KioskOutput $kioskOutput
        Add-OrReplaceAppInJson -Json $json -NewApp $newApp

        $appId = Get-AppIdFromName -AppName $nameId

        $resolvedEntry = [PSCustomObject]@{
            Name             = $nameId
            AppID            = $appId
            Source           = $game.SourceLabel
            InstallDirectory = $game.InstallDirectory
            RunAsAdmin       = [bool]$game.SkipAclGrant
        }
        if ($isDesktop) {
            $resolvedEntry | Add-Member -NotePropertyName Exe -NotePropertyValue $desktopExe -Force
            $resolvedEntry | Add-Member -NotePropertyName Args -NotePropertyValue $desktopArgs -Force
        }
        elseif ($isSteam) {
            $resolvedEntry | Add-Member -NotePropertyName Exe -NotePropertyValue $steamExe -Force
            $resolvedEntry | Add-Member -NotePropertyName Args -NotePropertyValue ("-applaunch $steamAppId") -Force
            $resolvedEntry.RunAsAdmin = $true
        }
        [void]$resolvedAppIds.Add($resolvedEntry)

        if ($isDesktop) {
            $line = "${appId}: `"$desktopExe`""
            if (-not [string]::IsNullOrWhiteSpace($desktopArgs)) {
                $line = "$line $desktopArgs"
            }
        }
        elseif ($isSteam) {
            $line = "${appId}: &`"$steamExe`" -applaunch $steamAppId"
        }
        else {
            $line = "${appId}: ${playniteCmdPrefix}$($game.Id)"
        }
        if ($game.SourceLabel -eq 'Steam' -or $game.SourceLabel -eq 'Epic') {
            $line = "${line} @ADMIN"
        }
        elseif ([bool]$game.SkipAclGrant) {
            $line = "${line} @ADMIN"
        }
        if (-not [string]::IsNullOrWhiteSpace($game.InstallDirectory)) {
            $line = "${line} | $($game.InstallDirectory)"
        }
        if ($game.SourceLabel -eq 'Steam') {
            $appLaunchLinesSteam.Add($line)
            $counts.Steam++
        }
        elseif ($game.SourceLabel -eq 'Epic') {
            $appLaunchLinesEpic.Add($line)
            $counts.Epic++
        }
        elseif ($game.SourceLabel -eq 'Desktop') {
            $appLaunchLinesDesktop.Add($line)
            $counts.Desktop++
        }
    }

    $configDir = Split-Path $AppsPath -Parent
    if (-not (Test-Path -LiteralPath $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }

    $resolvedJsonPath = Join-Path $configDir "resolved-appids.json"
    $resolvedTxtPath = Join-Path $configDir "resolved-appids.txt"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $resolvedList = @($resolvedAppIds | Sort-Object Source, Name)
    $resolvedJson = if ($resolvedList.Count -eq 0) { '[]' } else { ConvertTo-JsonSafe -Object $resolvedList -Depth 5 }

    $txtLines = @(
        "Steam:"
        $(if ($appLaunchLinesSteam.Count -gt 0) { $appLaunchLinesSteam } else { "  (none)" })
        ""
        "Epic:"
        $(if ($appLaunchLinesEpic.Count -gt 0) { $appLaunchLinesEpic } else { "  (none)" })
        ""
        "Desktop:"
        $(if ($appLaunchLinesDesktop.Count -gt 0) { $appLaunchLinesDesktop } else { "  (none)" })
    )

    $appsJson = ConvertTo-JsonSafe -Object $json -Depth 100

    return [PSCustomObject]@{
        AppsPath         = $AppsPath
        ResolvedJsonPath = $resolvedJsonPath
        ResolvedTxtPath  = $resolvedTxtPath
        AppsJson         = $appsJson
        ResolvedJson     = $resolvedJson
        ResolvedTxtLines = $txtLines
        Counts           = $counts
    }
}

function Publish-SunshineExportArtifacts {
    param(
        [PSCustomObject]$ExportResult
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $tempRoot = Join-Path $env:TEMP ("PlayniteSunshineExport_{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

    $tempApps = Join-Path $tempRoot "apps.json"
    $tempResolvedJson = Join-Path $tempRoot "resolved-appids.json"
    $tempResolvedTxt = Join-Path $tempRoot "resolved-appids.txt"

    [System.IO.File]::WriteAllText($tempApps, $ExportResult.AppsJson, $utf8NoBom)
    [System.IO.File]::WriteAllText($tempResolvedJson, $ExportResult.ResolvedJson, $utf8NoBom)
    [System.IO.File]::WriteAllLines($tempResolvedTxt, $ExportResult.ResolvedTxtLines, $utf8NoBom)

    $targets = @(
        @{ Temp = $tempApps; Dest = $ExportResult.AppsPath }
        @{ Temp = $tempResolvedJson; Dest = $ExportResult.ResolvedJsonPath }
        @{ Temp = $tempResolvedTxt; Dest = $ExportResult.ResolvedTxtPath }
    )

    foreach ($item in $targets) {
        $destDir = Split-Path $item.Dest -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
    }

    $directCopyFailed = $false
    try {
        foreach ($item in $targets) {
            Copy-Item -LiteralPath $item.Temp -Destination $item.Dest -Force
        }
    }
    catch {
        $directCopyFailed = $true
    }

    if ($directCopyFailed) {
        if (Test-IsAdministrator) {
            throw "Failed to write Sunshine config files under $($targets[0].Dest). Check path permissions."
        }
        $copyScript = @(
            foreach ($item in $targets) {
                "Copy-Item -LiteralPath '$($item.Temp)' -Destination '$($item.Dest)' -Force"
            }
        ) -join "; "
        Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -WindowStyle Hidden `
            -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$copyScript`""
    }

    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    return $ExportResult
}
