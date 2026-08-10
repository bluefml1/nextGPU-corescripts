# Load assemblies (WinForms for dialogs; Playnite host already loads WPF for export logic)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework

$script:EventLogsUndo = 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Program Files\Sunshine\scripts\eventLogs.ps1"'
$script:ResolvedAppIds = New-Object System.Collections.Generic.List[object]

#region Hashing (same algorithm as Add-SteamGames.ps1 - do not modify)

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

function Get-Sha256HexFromBytes {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($Bytes)
        return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-AppIdFromName {
    param(
        [Parameter(Mandatory = $true)][string]$AppName,
        [string]$ImagePath,
        [string]$ImageBase64,
        [string]$ImageText,
        [int]$Index = -1
    )
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add($AppName)
    if (-not [string]::IsNullOrWhiteSpace($ImagePath)) {
        if (Test-Path -LiteralPath $ImagePath -PathType Leaf) {
            try { $parts.Add((Get-Sha256HexFromFile -Path $ImagePath)) }
            catch { $parts.Add($ImagePath) }
        }
        else { $parts.Add($ImagePath) }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ImageBase64)) {
        $imgBytes = [Convert]::FromBase64String($ImageBase64)
        $parts.Add((Get-Sha256HexFromBytes -Bytes $imgBytes))
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ImageText)) {
        $imgBytes = [System.Text.Encoding]::UTF8.GetBytes($ImageText)
        $parts.Add((Get-Sha256HexFromBytes -Bytes $imgBytes))
    }
    $inputStr = $parts -join ""
    if ($Index -ge 0) { $inputStr = $inputStr + $Index.ToString() }
    $crc = Get-Crc32 -Bytes ([System.Text.Encoding]::UTF8.GetBytes($inputStr))
    return Get-SignedAbsInt32String -U32 $crc
}

function Get-Sha256HexFromFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    return Get-Sha256HexFromBytes -Bytes $bytes
}

function Register-AppId {
    param(
        [string]$Name,
        [string]$Source,
        [string]$InstallDirectory = $null,
        [string]$ImagePath = "",
        [string]$PlayniteId = "",
        [bool]$SkipAclGrant = $false
    )
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $alreadyExists = $script:ResolvedAppIds | Where-Object { $_.Name -eq $Name -and $_.Source -eq $Source }
    if ($alreadyExists) { return }
    $appId = Get-AppIdFromName -AppName $Name
    $script:ResolvedAppIds.Add([PSCustomObject]@{
            Name             = $Name
            AppID            = $appId
            Source           = $Source
            InstallDirectory = $InstallDirectory
            PlayniteId       = $PlayniteId
            SkipAclGrant     = [bool]$SkipAclGrant
        }) | Out-Null
    $__logger.Info("NameID: $Name => AppID: $appId [$Source]")
}

#endregion

function GetMainMenuItems {
    param(
        $getMainMenuItemsArgs
    )

    $menuItem1 = New-Object Playnite.SDK.Plugins.ScriptMainMenuItem
    $menuItem1.Description = "Export all games"
    $menuItem1.FunctionName = "SunshineExport"
    $menuItem1.MenuSection = "@Sunshine App Export"

    return @($menuItem1)
}

function Get-DefaultSunshineAppsPath {
    return "$Env:ProgramW6432\Sunshine\config\apps.json"
}

function Get-AllPlayniteGames {
    $games = $PlayniteApi.Database.Games
    if ($null -eq $games) {
        return @()
    }
    return @($games | Where-Object { $null -ne $_ })
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

function Select-SunshineAppsPath {
    param([string]$DefaultPath)

    $gameCount = (Get-AllPlayniteGames).Count
    $parentDir = Split-Path $DefaultPath -Parent

    $prompt = @"
Export your entire Playnite library to Sunshine ($gameCount games).
No games need to be selected in the grid.

Default apps.json:
$DefaultPath

Yes = export to default path
No = choose another apps.json file
Cancel = abort
"@

    $choice = $PlayniteApi.Dialogs.ShowMessage(
        $prompt,
        "Sunshine App Export",
        [System.Windows.MessageBoxButton]::YesNoCancel
    )

    if ($choice -eq [System.Windows.MessageBoxResult]::Cancel) {
        return $null
    }

    if ($choice -eq [System.Windows.MessageBoxResult]::No) {
        $picked = $PlayniteApi.Dialogs.SelectFile("JSON file|*.json", $parentDir)
        if ([string]::IsNullOrWhiteSpace($picked)) {
            return $null
        }
        return $picked.Trim()
    }

    return $DefaultPath.Trim()
}

function SunshineExport {
    param(
        $scriptMainMenuItemActionArgs
    )

    # Playnite CreateWindow().ShowDialog() fails from the main menu in PowerShell with:
    # "Cannot bind argument to parameter 'InputObject' because it is null."
    # WinForms dialogs work reliably here (same pattern as WatcherUI.ps1).

    try {
        $defaultPath = Get-DefaultSunshineAppsPath
        $appsPath = Select-SunshineAppsPath -DefaultPath $defaultPath
        if ([string]::IsNullOrWhiteSpace($appsPath)) {
            $__logger.Info("Sunshine App Export cancelled by user.")
            return
        }

        $__logger.Info("Sunshine App Export starting for: $appsPath")
        $exportResult = DoWork($appsPath)

        $summary = (
            "Exported all library games to Sunshine.`n`n" +
            "Steam entries: {0}`nEpic entries: {1}`nLegacy (cover) entries: {2}`nGames processed: {3}`n`nConfig: {4}" -f
            $exportResult.Steam,
            $exportResult.Epic,
            $exportResult.Legacy,
            $exportResult.Total,
            $appsPath
        )

        [void]$PlayniteApi.Dialogs.ShowMessage(
            $summary,
            "Sunshine App Export",
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
    }
    catch {
        $__logger.Error("Sunshine App Export failed: $($_.Exception.Message)")
        [void]$PlayniteApi.Dialogs.ShowErrorMessage(
            "Export failed: $($_.Exception.Message)",
            "Sunshine App Export"
        )
    }
}

function Get-GameIdFromCmd([string]$cmd) {
    $parts = $cmd -split " --start "
    if ($parts.Count -gt 1) {
        return ($parts[1] -split " ")[0]
    }
    return ""
}

function Test-PrepCmdUsesEventLogs {
    param($App)
    if (-not $App.'prep-cmd') { return $false }
    foreach ($prep in @($App.'prep-cmd')) {
        if ($prep.undo -like '*eventLogs.ps1*') { return $true }
    }
    return $false
}

function Test-IsSteamOrEpicGame {
    param($Game)
    $sourceName = $null
    if ($null -ne $Game.Source) {
        $sourceName = $Game.Source.ToString()
    }
    if ($sourceName -eq 'Steam') { return 'Steam' }
    if ($sourceName -eq 'Epic') { return 'Epic' }
    return $null
}

function Get-SteamEpicNameId {
    param($Game, [string]$SourceLabel)
    if ($SourceLabel -eq 'Steam') {
        if (-not [string]::IsNullOrWhiteSpace($Game.GameId)) { return $Game.GameId.ToString() }
        return $null
    }
    if ($SourceLabel -eq 'Epic') {
        if (-not [string]::IsNullOrWhiteSpace($Game.InstallDirectory)) {
            $leaf = [System.IO.Path]::GetFileName($Game.InstallDirectory.TrimEnd('\', '/'))
            if (-not [string]::IsNullOrWhiteSpace($leaf)) { return $leaf }
        }
        if (-not [string]::IsNullOrWhiteSpace($Game.GameId)) { return $Game.GameId.ToString() }
        return $null
    }
    return $null
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
                undo     = $script:EventLogsUndo
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
        if ($app.detached) {
            $gid = Get-GameIdFromCmd($app.detached[0])
            if ($gid -eq $PlayniteId) { continue }
        }
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

function Export-LegacyCoverApp {
    param(
        [object]$Json,
        [object]$Game,
        [string]$PlayniteExecutablePath,
        [string]$AppAssetsPath,
        $AppLaunchLinesPlaynite
    )
    $gameLaunchCmd = "&`"$PlayniteExecutablePath`" --start $($Game.Id)"
    $sunshineGameCoverPath = [System.IO.Path]::Combine($AppAssetsPath, $Game.Id, "box-art.png")
    $coverDir = Split-Path $sunshineGameCoverPath -Parent
    if (!(Test-Path $coverDir -PathType Container)) {
        New-Item -ItemType Directory -Path $coverDir -Force | Out-Null
    }
    if (!(Test-Path $sunshineGameCoverPath -PathType Leaf)) {
        New-Item -ItemType File -Path $sunshineGameCoverPath -Force | Out-Null
    }

    if ($null -eq $Game.CoverImage) { return $false }

    $sourceCover = $PlayniteApi.Database.GetFullFilePath($Game.CoverImage)
    if (($Game.CoverImage -match "^http") -or -not (Test-Path $sourceCover -PathType Leaf)) {
        return $false
    }

    if ([System.IO.Path]::GetExtension($Game.CoverImage) -eq ".png") {
        Copy-Item $sourceCover $sunshineGameCoverPath -Force
    }
    else {
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.UriSource = New-Object System.Uri($sourceCover, [System.UriKind]::Absolute)
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.EndInit()

            $encoder = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap)
            $encoder.Frames.Add($frame)

            $fileStream = New-Object System.IO.FileStream($sunshineGameCoverPath, [System.IO.FileMode]::Create)
            $encoder.Save($fileStream)
            $fileStream.Close()
        }
        catch {
            $errorMessage = $_.Exception.Message
            $__logger.Info("Error converting cover image of `"$($Game.Name)`". Error: $errorMessage")
            return $false
        }
    }

    $ids = @()
    foreach ($app in $Json.apps) {
        if ($app.id) { $ids += $app.id }
    }
    $id = Get-Random
    while ($ids.Contains($id.ToString())) { $id = Get-Random }

    $newApp = [PSCustomObject]@{
        name       = $Game.Name
        detached   = @($gameLaunchCmd)
        'image-path' = $sunshineGameCoverPath
        id         = $id.ToString()
    }

    $updatedApps = New-Object System.Collections.Generic.List[object]
    $hasGame = $false
    foreach ($app in @($Json.apps)) {
        if ($null -eq $app) { continue }
        if ($app.detached) {
            $gameId = Get-GameIdFromCmd($app.detached[0])
            if ($gameId -eq $Game.Id) {
                $hasGame = $true
                [void]$updatedApps.Add($newApp)
                continue
            }
        }
        [void]$updatedApps.Add($app)
    }
    if (-not $hasGame) {
        [void]$updatedApps.Add($newApp)
    }
    [object[]]$Json.apps = $updatedApps.ToArray()

    Register-AppId -Name $Game.Name -Source "Playnite" -InstallDirectory $Game.InstallDirectory -PlayniteId $Game.Id.ToString() -SkipAclGrant $Game.SkipAclGrant
    $entry = $script:ResolvedAppIds | Where-Object { $_.Name -eq $Game.Name -and $_.Source -eq "Playnite" } | Select-Object -Last 1
    if ($entry) {
        $entryLine = "$($entry.AppID): $gameLaunchCmd"
        if (-not [string]::IsNullOrWhiteSpace($Game.InstallDirectory)) {
            $entryLine = "${entryLine} | $($Game.InstallDirectory)"
        }
        if ([bool]$Game.SkipAclGrant) {
            $entryLine = "${entryLine} @ADMIN"
        }
        [void]$AppLaunchLinesPlaynite.Add($entryLine)
    }
    return $true
}

function Write-ResolvedAppIdReports {
    param(
        [string]$ConfigDir,
        [string[]]$AppLaunchLinesSteam,
        [string[]]$AppLaunchLinesEpic,
        [string[]]$AppLaunchLinesPlaynite
    )
    $resolvedJson = Join-Path $ConfigDir "resolved-appids.json"
    $resolvedTxt = Join-Path $ConfigDir "resolved-appids.txt"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    $resolvedList = @($script:ResolvedAppIds | Sort-Object Source, Name)
    if ($resolvedList.Count -eq 0) {
        $appIdJson = '[]'
    }
    else {
        $appIdJson = ConvertTo-JsonSafe -Object $resolvedList -Depth 5
    }
    [System.IO.File]::WriteAllLines("$env:TEMP\resolved-appids.json", $appIdJson, $utf8NoBom)

    $lines = @()
    $lines += "Steam:"
    if ($AppLaunchLinesSteam.Count -gt 0) { $lines += $AppLaunchLinesSteam } else { $lines += "  (none)" }
    $lines += ""
    $lines += "Epic:"
    if ($AppLaunchLinesEpic.Count -gt 0) { $lines += $AppLaunchLinesEpic } else { $lines += "  (none)" }
    $lines += ""
    $lines += "Playnite:"
    if ($AppLaunchLinesPlaynite.Count -gt 0) { $lines += $AppLaunchLinesPlaynite } else { $lines += "  (none)" }
    [System.IO.File]::WriteAllLines("$env:TEMP\resolved-appids.txt", $lines, $utf8NoBom)

    return @{ Json = $resolvedJson; Txt = $resolvedTxt }
}

function DoWork([string]$appsPath) {
    Add-Type -AssemblyName System.Drawing

    $script:ResolvedAppIds = New-Object System.Collections.Generic.List[object]
    $counts = @{ Steam = 0; Epic = 0; Legacy = 0; Total = 0 }

    $playniteExecutablePath = Join-Path -Path $PlayniteApi.Paths.ApplicationPath -ChildPath "Playnite.DesktopApp.exe"
    $appAssetsPath = Join-Path -Path $env:LocalAppData -ChildPath "Sunshine Playnite App Export\Apps"
    if (!(Test-Path $appAssetsPath -PathType Container)) {
        New-Item -ItemType Container -Path $appAssetsPath -Force | Out-Null
    }

    $configDir = Split-Path $appsPath -Parent
    $AppLaunchLines_Steam = [System.Collections.Generic.List[string]]::new()
    $AppLaunchLines_Epic = [System.Collections.Generic.List[string]]::new()
    $AppLaunchLines_Playnite = [System.Collections.Generic.List[string]]::new()

    $json = Read-SunshineAppsJson -AppsPath $appsPath

    foreach ($game in (Get-AllPlayniteGames)) {
        $counts.Total++
        $sourceLabel = Test-IsSteamOrEpicGame -Game $game
        $playniteCmd = "&`"$playniteExecutablePath`" --start $($game.Id)"

        if ($sourceLabel) {
            $nameId = Get-SteamEpicNameId -Game $game -SourceLabel $sourceLabel
            if ([string]::IsNullOrWhiteSpace($nameId)) {
                $__logger.Info("Skipping $($game.Name): no NameID for $sourceLabel")
                continue
            }

            Remove-PriorExportsForGame -Json $json -NameId $nameId -PlayniteId $game.Id.ToString()

            $kioskOutput = if ($sourceLabel -eq 'Steam') { "$nameId.kiosk.log" } else { "$($game.Id).kiosk.log" }
            $newApp = New-SteamEpicSunshineApp -NameId $nameId -PlayniteId $game.Id.ToString() -KioskOutput $kioskOutput
            Add-OrReplaceAppInJson -Json $json -NewApp $newApp

            Register-AppId -Name $nameId -Source $sourceLabel -InstallDirectory $game.InstallDirectory -PlayniteId $game.Id.ToString() -SkipAclGrant $false
            $entry = $script:ResolvedAppIds | Where-Object { $_.Name -eq $nameId -and $_.Source -eq $sourceLabel } | Select-Object -Last 1
            if ($entry) {
                $line = "$($entry.AppID): $playniteCmd @ADMIN"
                if (-not [string]::IsNullOrWhiteSpace($game.InstallDirectory)) {
                    $line = "${line} | $($game.InstallDirectory)"
                }
                if ($sourceLabel -eq 'Steam') {
                    $AppLaunchLines_Steam.Add($line)
                    $counts.Steam++
                }
                else {
                    $AppLaunchLines_Epic.Add($line)
                    $counts.Epic++
                }
            }
        }
        else {
            if (Export-LegacyCoverApp -Json $json -Game $game -PlayniteExecutablePath $playniteExecutablePath -AppAssetsPath $appAssetsPath -AppLaunchLinesPlaynite $AppLaunchLines_Playnite) {
                $counts.Legacy++
            }
        }
    }

    $reportPaths = Write-ResolvedAppIdReports -ConfigDir $configDir -AppLaunchLinesSteam $AppLaunchLines_Steam -AppLaunchLinesEpic $AppLaunchLines_Epic -AppLaunchLinesPlaynite $AppLaunchLines_Playnite

    $jsonObj = ConvertTo-JsonSafe -Object $json -Depth 100
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText("$env:TEMP\apps.json", $jsonObj, $utf8NoBom)

    $result = $PlayniteApi.Dialogs.ShowMessage(
        "You will be prompted for administrator rights to copy apps.json and resolved-appids reports into Sunshine config.",
        "Administrator Required",
        [System.Windows.MessageBoxButton]::OKCancel,
        [System.Windows.MessageBoxImage]::Information
    )
    if ($result -eq [System.Windows.MessageBoxResult]::Cancel) {
        return [PSCustomObject]$counts
    }

    $copyApps = "Copy-Item -LiteralPath '$env:TEMP\apps.json' -Destination '$appsPath' -Force"
    $copyJson = "Copy-Item -LiteralPath '$env:TEMP\resolved-appids.json' -Destination '$($reportPaths.Json)' -Force"
    $copyTxt = "Copy-Item -LiteralPath '$env:TEMP\resolved-appids.txt' -Destination '$($reportPaths.Txt)' -Force"
    $elevatedCmd = "$copyApps; $copyJson; $copyTxt"
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -Command `"$elevatedCmd`"" -WindowStyle Hidden

    return [PSCustomObject]$counts
}
