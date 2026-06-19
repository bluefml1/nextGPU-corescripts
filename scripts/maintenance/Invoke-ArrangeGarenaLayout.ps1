#Requires -Version 5.1
# Dot-sourced by Arrange-GamesApps.ps1 — deploy Garena client, gxx to ProgramData, patch user.dat install paths.

$script:GarenaInstallPathFileName = 'GarenaInstall.path'
$script:GarenaAppsPathsFileName = 'Garena-Apps.paths.json'

function Write-ArrangeGarenaLog {
    param([string]$LogPath, [string]$Message)
    $line = ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
}

function Write-ArrangeGarenaWarn {
    param([string]$LogPath, [string]$Message)
    Write-ArrangeGarenaLog -LogPath $LogPath -Message "WARN $Message"
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Get-GarenaInstallPathFile {
    return Join-Path $PSScriptRoot $script:GarenaInstallPathFileName
}

function Get-GarenaAppsPathsFile {
    return Join-Path $PSScriptRoot $script:GarenaAppsPathsFileName
}

function Read-SavedGarenaInstallRoot {
    $pathFile = Get-GarenaInstallPathFile
    if (-not (Test-Path -LiteralPath $pathFile)) { return $null }
    $line = (Get-Content -LiteralPath $pathFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($line)) { return $null }
    try {
        return [System.IO.Path]::GetFullPath($line.Trim().Trim('"'))
    }
    catch { return $null }
}

function Save-GarenaInstallRoot {
    param([Parameter(Mandatory)][string]$GarenaRoot)
    $pathFile = Get-GarenaInstallPathFile
    Set-Content -LiteralPath $pathFile -Value ([System.IO.Path]::GetFullPath($GarenaRoot.TrimEnd('\'))) -Encoding UTF8 -NoNewline
}

function Read-GarenaAppsPathsMap {
    $pathFile = Get-GarenaAppsPathsFile
    if (-not (Test-Path -LiteralPath $pathFile)) { return @{} }
    try {
        $doc = Get-Content -LiteralPath $pathFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $map = @{}
        if ($doc -and $doc.apps) {
            foreach ($prop in @($doc.apps.PSObject.Properties)) {
                $map[[string]$prop.Name] = [string]$prop.Value
            }
        }
        return $map
    }
    catch { return @{} }
}

function Save-GarenaAppsPathsMap {
    param([Parameter(Mandatory)][hashtable]$AppPaths)
    $pathFile = Get-GarenaAppsPathsFile
    $obj = [ordered]@{ apps = [ordered]@{} }
    foreach ($key in @($AppPaths.Keys | Sort-Object)) {
        $obj.apps[$key] = $AppPaths[$key]
    }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $pathFile -Encoding UTF8
}

function Get-GarenaAppsConfig {
    $configPath = Join-Path $PSScriptRoot 'Garena-Apps.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Garena apps config not found: $configPath"
    }
    return (Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Test-GarenaUserDatHasPlainInstallPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedFragment = '32837'
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    foreach ($encName in @('Unicode', 'UTF8', 'ASCII')) {
        $enc = [Text.Encoding]::$encName
        $needle = $enc.GetBytes($ExpectedFragment)
        if ($needle.Length -eq 0) { continue }
        for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
            $match = $true
            for ($j = 0; $j -lt $needle.Length; $j++) {
                if ($bytes[$i + $j] -ne $needle[$j]) { $match = $false; break }
            }
            if ($match) { return $true }
        }
    }
    return $false
}

function Test-GarenaGameFolderLooksValid {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    if (Get-ChildItem -LiteralPath $Path -Filter '*.gpipe' -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return $true
    }
    if (Get-ChildItem -LiteralPath $Path -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
        return $true
    }
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue)) {
        if (Get-ChildItem -LiteralPath $child.FullName -Filter '*.gpipe' -File -ErrorAction SilentlyContinue | Select-Object -First 1) {
            return $true
        }
    }
    return $false
}

function Resolve-GarenaAppInstallFolder {
    param(
        [Parameter(Mandatory)][string]$PickedPath,
        [Parameter(Mandatory)][string]$AppId,
        [object]$AppConfig,
        [string]$LogPath = ''
    )
    $picked = [System.IO.Path]::GetFullPath($PickedPath.TrimEnd('\'))
    $sub = if ($AppConfig -and $AppConfig.installSubfolder) { [string]$AppConfig.installSubfolder } else { $AppId }
    if ((Split-Path -Leaf $picked) -ieq $sub) {
        return $picked
    }
    $child = Join-Path $picked $sub
    if ((Test-Path -LiteralPath $child -PathType Container) -and (Test-GarenaGameFolderLooksValid -Path $child)) {
        if ($LogPath) {
            Write-ArrangeGarenaLog -LogPath $LogPath -Message "Resolved app $AppId install folder: $child (under $picked)"
        }
        return $child
    }
    if (Test-GarenaGameFolderLooksValid -Path $picked) {
        return $picked
    }
    return $picked
}

function Install-GarenaAppJunctionLayout {
    param(
        [Parameter(Mandatory)][string]$CanonicalPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$LogPath = ''
    )
    return (New-GarenaGameJunction -CanonicalPath $CanonicalPath -TargetPath $TargetPath -LogPath $LogPath)
}

function Test-GarenaPostDeployInstallLayout {
    param(
        [Parameter(Mandatory)][string]$GarenaRoot,
        [Parameter(Mandatory)][string]$AppId,
        [Parameter(Mandatory)][string]$ExpectedTargetPath,
        [string]$LogPath = ''
    )
    $canonical = Get-GarenaCanonicalGamePath -GarenaRoot $GarenaRoot -AppId $AppId
    $expected = [System.IO.Path]::GetFullPath((Resolve-ManifestExtractPathString -Path $ExpectedTargetPath).TrimEnd('\'))
    $ok = $true
    if (-not (Test-Path -LiteralPath $canonical)) {
        Write-ArrangeGarenaWarn -LogPath $LogPath -Message "Post-check: canonical path missing: $canonical"
        $ok = $false
    }
    elseif (Test-PathIsReparsePoint -Path $canonical) {
        try {
            $resolved = (Get-Item -LiteralPath $canonical).Target
            if ($resolved -and ($resolved.TrimEnd('\') -ine $expected)) {
                Write-ArrangeGarenaWarn -LogPath $LogPath -Message "Post-check: junction $canonical -> $resolved (expected target $expected)"
            }
            else {
                Write-ArrangeGarenaLog -LogPath $LogPath -Message "Post-check: junction OK $canonical -> $resolved"
            }
        }
        catch {
            Write-ArrangeGarenaWarn -LogPath $LogPath -Message "Post-check: could not read junction target for $canonical"
        }
    }
    else {
        Write-ArrangeGarenaWarn -LogPath $LogPath -Message "Post-check: $canonical exists but is not a junction"
        $ok = $false
    }
    return $ok
}

function Get-GarenaPathEncodingVariants {
    param([Parameter(Mandatory)][string]$Path)
    $normalized = Resolve-ManifestExtractPathString -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalized)) { return @() }
    $normalized = $normalized.TrimEnd('\')
    $variants = New-Object System.Collections.Generic.List[byte[]]
    $seen = @{}

    foreach ($p in @($normalized, ($normalized -replace '\\', '/'))) {
        foreach ($enc in @(
                [System.Text.Encoding]::Unicode,
                [System.Text.Encoding]::UTF8,
                [System.Text.Encoding]::ASCII
            )) {
            $bytes = $enc.GetBytes($p)
            $key = [Convert]::ToBase64String($bytes)
            if (-not $seen[$key]) {
                $seen[$key] = $true
                [void]$variants.Add($bytes)
            }
        }
    }
    return $variants.ToArray()
}

function Test-GarenaPathSameByteLength {
    param(
        [Parameter(Mandatory)][string]$OldPath,
        [Parameter(Mandatory)][string]$NewPath
    )
    $oldVariants = @(Get-GarenaPathEncodingVariants -Path $OldPath)
    $newVariants = @(Get-GarenaPathEncodingVariants -Path $NewPath)
    if ($oldVariants.Count -eq 0 -or $newVariants.Count -eq 0) { return $false }
    foreach ($o in $oldVariants) {
        foreach ($n in $newVariants) {
            if ($o.Length -eq $n.Length) { return $true }
        }
    }
    return $false
}

function Replace-GarenaBytesPattern {
    param(
        [byte[]]$Haystack,
        [byte[]]$Needle,
        [byte[]]$Replacement
    )
    if ($Needle.Length -eq 0 -or $Needle.Length -ne $Replacement.Length) { return ,@($Haystack, 0) }
    $count = 0
    $result = New-Object System.Collections.Generic.List[byte]
    $i = 0
    while ($i -le $Haystack.Length - $Needle.Length) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $match = $false
                break
            }
        }
        if ($match) {
            foreach ($b in $Replacement) { [void]$result.Add($b) }
            $count++
            $i += $Needle.Length
        }
        else {
            [void]$result.Add($Haystack[$i])
            $i++
        }
    }
    while ($i -lt $Haystack.Length) {
        [void]$result.Add($Haystack[$i])
        $i++
    }
    return ,@($result.ToArray(), $count)
}

function Update-GarenaPaddedUtf16PathsInFile {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$OldPath,
        [Parameter(Mandatory)][string]$NewPath,
        [string]$LogPath = ''
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "File not found: $FilePath"
    }
    $oldNorm = (Resolve-ManifestExtractPathString -Path $OldPath).TrimEnd('\')
    $newNorm = (Resolve-ManifestExtractPathString -Path $NewPath).TrimEnd('\')
    if ($oldNorm -ceq $newNorm) { return 0 }

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $total = 0
    $enc = [System.Text.Encoding]::Unicode

    foreach ($oldStr in @($oldNorm, ($oldNorm -replace '\\', '/'))) {
        $oldBytes = $enc.GetBytes($oldStr)
        $newBytes = $enc.GetBytes($newNorm)
        if ($newBytes.Length -gt $oldBytes.Length) { continue }

        $padded = New-Object byte[] $oldBytes.Length
        [Array]::Copy($newBytes, 0, $padded, 0, $newBytes.Length)

        $pair = Replace-GarenaBytesPattern -Haystack $bytes -Needle $oldBytes -Replacement $padded
        $bytes = $pair[0]
        $total += [int]$pair[1]
    }

    if ($total -gt 0) {
        Copy-Item -LiteralPath $FilePath -Destination ($FilePath + '.bak.arrange') -Force -ErrorAction SilentlyContinue
        [System.IO.File]::WriteAllBytes($FilePath, $bytes)
        if ($LogPath) {
            Write-ArrangeGarenaLog -LogPath $LogPath -Message "PADDED PATCH $FilePath : $oldNorm -> $newNorm ($total replacements)"
        }
    }
    return $total
}

function Update-GarenaBinaryPathsInFile {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$OldPath,
        [Parameter(Mandatory)][string]$NewPath,
        [string]$LogPath = ''
    )
    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        throw "File not found: $FilePath"
    }
    $oldNorm = (Resolve-ManifestExtractPathString -Path $OldPath).TrimEnd('\')
    $newNorm = (Resolve-ManifestExtractPathString -Path $NewPath).TrimEnd('\')
    if ($oldNorm -ceq $newNorm) { return 0 }

    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    $total = 0
    $oldVariants = @(Get-GarenaPathEncodingVariants -Path $oldNorm)
    $newVariants = @(Get-GarenaPathEncodingVariants -Path $newNorm)

    foreach ($oldBytes in $oldVariants) {
        $matchedNew = @($newVariants | Where-Object { $_.Length -eq $oldBytes.Length })
        foreach ($newBytes in $matchedNew) {
            $pair = Replace-GarenaBytesPattern -Haystack $bytes -Needle $oldBytes -Replacement $newBytes
            $bytes = $pair[0]
            $total += [int]$pair[1]
        }
    }

    if ($total -gt 0) {
        Copy-Item -LiteralPath $FilePath -Destination ($FilePath + '.bak.arrange') -Force -ErrorAction SilentlyContinue
        [System.IO.File]::WriteAllBytes($FilePath, $bytes)
        if ($LogPath) {
            Write-ArrangeGarenaLog -LogPath $LogPath -Message "PATCH $FilePath : $oldNorm -> $newNorm ($total replacements)"
        }
    }
    return $total
}

function Update-GarenaTemplateRoot {
    param(
        [Parameter(Mandatory)][string]$GxxDir,
        [Parameter(Mandatory)][string]$TemplateRoot,
        [Parameter(Mandatory)][string]$GarenaRoot,
        [Parameter(Mandatory)][string]$TemplateUserId,
        [string]$LogPath = ''
    )
    $templateRoot = (Resolve-ManifestExtractPathString -Path $TemplateRoot).TrimEnd('\')
    $garenaRoot = (Resolve-ManifestExtractPathString -Path $GarenaRoot).TrimEnd('\')
    if ($templateRoot -ceq $garenaRoot) { return 0 }

    if ($templateRoot.Length -ne $garenaRoot.Length) {
        Write-ArrangeGarenaWarn -LogPath $LogPath -Message "GarenaRoot length differs from template ($templateRoot). Binary patch may fail; prefer {drive}:\Garena."
    }

    $total = 0
    $gxxDat = Join-Path $GxxDir 'config\gxx.dat'
    if (Test-Path -LiteralPath $gxxDat) {
        $total += Update-GarenaBinaryPathsInFile -FilePath $gxxDat -OldPath $templateRoot -NewPath $garenaRoot -LogPath $LogPath
    }
    $userDat = Join-Path $GxxDir "user\$TemplateUserId\user.dat"
    if (Test-Path -LiteralPath $userDat) {
        $total += Update-GarenaBinaryPathsInFile -FilePath $userDat -OldPath $templateRoot -NewPath $garenaRoot -LogPath $LogPath
    }
    return $total
}

function Update-GarenaAppInstallPath {
    param(
        [Parameter(Mandatory)][string]$UserDatPath,
        [Parameter(Mandatory)][string]$TemplateInstallPath,
        [Parameter(Mandatory)][string]$NewInstallPath,
        [string]$LogPath = ''
    )
    $count = Update-GarenaBinaryPathsInFile -FilePath $UserDatPath -OldPath $TemplateInstallPath -NewPath $NewInstallPath -LogPath $LogPath
    if ($count -le 0) {
        $count = Update-GarenaPaddedUtf16PathsInFile -FilePath $UserDatPath -OldPath $TemplateInstallPath -NewPath $NewInstallPath -LogPath $LogPath
    }
    return $count
}

function Resolve-GarenaRootFolder {
    param([Parameter(Mandatory)][string]$PickedPath)
    $full = [System.IO.Path]::GetFullPath($PickedPath.Trim().TrimEnd('\'))
    $leaf = Split-Path -Leaf $full
    if ([string]::IsNullOrEmpty($leaf) -or $leaf -match '^[A-Za-z]:$') {
        return [System.IO.Path]::GetFullPath((Join-Path $full 'Garena'))
    }
    return $full
}

function Get-GarenaCanonicalGamePath {
    param(
        [Parameter(Mandatory)][string]$GarenaRoot,
        [Parameter(Mandatory)][string]$AppId
    )
    return [System.IO.Path]::GetFullPath((Join-Path (Join-Path $GarenaRoot 'Games') $AppId))
}

function Test-IsCurrentProcessAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PathIsReparsePoint {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    return (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function New-GarenaGameJunction {
    param(
        [Parameter(Mandatory)][string]$CanonicalPath,
        [Parameter(Mandatory)][string]$TargetPath,
        [string]$LogPath = ''
    )
    $canonical = [System.IO.Path]::GetFullPath((Resolve-ManifestExtractPathString -Path $CanonicalPath).TrimEnd('\'))
    $target = [System.IO.Path]::GetFullPath((Resolve-ManifestExtractPathString -Path $TargetPath).TrimEnd('\'))
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        throw "Junction target folder not found: $target"
    }

    if (Test-Path -LiteralPath $canonical) {
        if (Test-PathIsReparsePoint -Path $canonical) {
            Remove-Item -LiteralPath $canonical -Force
        }
        else {
            throw "Cannot create junction; path exists and is not a junction: $canonical"
        }
    }
    else {
        $parent = Split-Path -Parent $canonical
        if ($parent -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
    }

    $junctionErr = $null
    try {
        $null = New-Item -ItemType Junction -Path $canonical -Target $target -Force -ErrorAction Stop
    }
    catch {
        $junctionErr = $_.Exception.Message
        $null = cmd /c "mklink /J `"$canonical`" `"$target`""
        if ($LASTEXITCODE -ne 0) {
            $hint = if (-not (Test-IsCurrentProcessAdministrator)) {
                'Run Arrange as Administrator or enable Windows Developer Mode (Settings > System > For developers).'
            }
            else {
                'The canonical path may already exist as a real folder, or the target is on an unsupported volume.'
            }
            throw "Could not create junction: $canonical -> $target. $hint (exit $LASTEXITCODE; $junctionErr)"
        }
    }
    if ($LogPath) {
        Write-ArrangeGarenaLog -LogPath $LogPath -Message "JUNCTION $canonical -> $target"
    }
    return $canonical
}

function Test-GarenaAppInstallPath {
    param(
        [Parameter(Mandatory)][string]$UserDatPath,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [string]$TemplateInstallPath = ''
    )
    if (-not (Test-Path -LiteralPath $UserDatPath)) { return $false }
    $expected = (Resolve-ManifestExtractPathString -Path $ExpectedPath).TrimEnd('\')
    $variants = @(Get-GarenaPathEncodingVariants -Path $expected)
    $bytes = [System.IO.File]::ReadAllBytes($UserDatPath)
    foreach ($v in $variants) {
        if ($v.Length -eq 0) { continue }
        for ($i = 0; $i -le $bytes.Length - $v.Length; $i++) {
            $match = $true
            for ($j = 0; $j -lt $v.Length; $j++) {
                if ($bytes[$i + $j] -ne $v[$j]) { $match = $false; break }
            }
            if ($match) { return $true }
        }
    }
    if ($TemplateInstallPath -and (Test-Path -LiteralPath $TemplateInstallPath)) {
        if (Test-PathIsReparsePoint -Path $TemplateInstallPath) {
            try {
                $resolved = (Get-Item -LiteralPath $TemplateInstallPath).Target
                if ($resolved -and ($resolved.TrimEnd('\') -ieq $expected)) { return $true }
            }
            catch { }
        }
    }
    return $false
}

function Get-GarenaManifestGamePathMap {
    param([Parameter(Mandatory)][object[]]$Entries)
    $map = @{}
    foreach ($e in @(ConvertTo-ObjectArray $Entries)) {
        if (Get-Command Test-ManifestEntryIsSteamClient -ErrorAction SilentlyContinue) {
            if (Test-ManifestEntryIsSteamClient -Entry $e) { continue }
        }
        $type = Get-ManifestEntryType -Entry $e
        if ($type -ieq 'steam') { continue }
        if (Get-Command Test-GarenaBundleManifestLeaf -ErrorAction SilentlyContinue) {
            $extract = Get-ManifestEntryExtractPath -Entry $e
            if (-not [string]::IsNullOrWhiteSpace($extract)) {
                $leaf = [System.IO.Path]::GetFileName($extract.Trim().TrimEnd('\'))
                if (Test-GarenaBundleManifestLeaf -LeafName $leaf) { continue }
            }
        }
        if (Get-Command Test-LevelUpBundleManifestLeaf -ErrorAction SilentlyContinue) {
            $extract = Get-ManifestEntryExtractPath -Entry $e
            if (-not [string]::IsNullOrWhiteSpace($extract)) {
                $leaf = [System.IO.Path]::GetFileName($extract.Trim().TrimEnd('\'))
                if (Test-LevelUpBundleManifestLeaf -LeafName $leaf) { continue }
            }
        }
        $extract = Get-ManifestEntryExtractPath -Entry $e
        if ([string]::IsNullOrWhiteSpace($extract)) { continue }
        try {
            $full = [System.IO.Path]::GetFullPath($extract.TrimEnd('\'))
        }
        catch { continue }
        $full = Resolve-ManifestExtractPathString -Path $full
        if ([string]::IsNullOrWhiteSpace($full)) { continue }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        $leaf = [System.IO.Path]::GetFileName($full)
        $map[$leaf] = $full
    }
    return $map
}

function Resolve-GarenaAppDefaultPath {
    param(
        [Parameter(Mandatory)][string]$AppId,
        [object]$AppConfig,
        [hashtable]$ManifestGameMap,
        [hashtable]$SavedAppPaths
    )
    if ($SavedAppPaths.ContainsKey($AppId)) {
        $saved = Resolve-ManifestExtractPathString -Path $SavedAppPaths[$AppId]
        if ($saved -and (Test-Path -LiteralPath $saved -PathType Container)) { return $saved }
    }
    if ($AppConfig.manifestLeaves) {
        foreach ($leaf in @($AppConfig.manifestLeaves)) {
            if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
            foreach ($key in @($ManifestGameMap.Keys)) {
                if ($key -ieq $leaf) { return $ManifestGameMap[$key] }
            }
        }
    }
    foreach ($key in @($ManifestGameMap.Keys)) {
        if ($key -match $AppId) { return $ManifestGameMap[$key] }
    }
    $sub = if ($AppConfig -and $AppConfig.installSubfolder) { [string]$AppConfig.installSubfolder } else { $AppId }
    foreach ($key in @($ManifestGameMap.Keys)) {
        $candidate = Join-Path $ManifestGameMap[$key] $sub
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
    }
    return $null
}

function Pick-GarenaFolder {
    param(
        [string]$Description,
        [string]$InitialPath = '',
        [bool]$UseGui = $true
    )
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Description
        if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
            $dlg.SelectedPath = $InitialPath
        }
        elseif ($InitialPath) {
            $parent = Split-Path -Parent $InitialPath
            if ($parent -and (Test-Path -LiteralPath $parent -PathType Container)) {
                $dlg.SelectedPath = $parent
            }
        }
        if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace($dlg.SelectedPath)) {
            return $null
        }
        return [System.IO.Path]::GetFullPath($dlg.SelectedPath.Trim())
    }
    Write-Host $Description -ForegroundColor Cyan
    if ($InitialPath) { Write-Host "Suggested: $InitialPath" -ForegroundColor DarkGray }
    $raw = Read-Host 'Folder path (Enter for suggested, blank to cancel)'
    if ([string]::IsNullOrWhiteSpace($raw)) {
        if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) {
            return [System.IO.Path]::GetFullPath($InitialPath)
        }
        return $null
    }
    return [System.IO.Path]::GetFullPath($raw.Trim().Trim('"'))
}

function Confirm-GarenaDeploy {
    param([string]$Message, [bool]$UseGui = $true)
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
        return ([System.Windows.Forms.MessageBox]::Show($Message, 'Arrange Garena', 'YesNo', 'Question') -eq 'Yes')
    }
    $ans = Read-Host "$Message [y/N]"
    return ($ans -match '^(y|yes)$')
}

function Deploy-GarenaGxxToProgramData {
    param(
        [Parameter(Mandatory)][string]$SourceGxxDir,
        [Parameter(Mandatory)][string]$TemplateUserId,
        [Parameter(Mandatory)][string]$LogPath,
        [bool]$UseGui = $true
    )
    Stop-GarenaClientProcesses

    $dest = Get-GarenaProgramDataGxxPath
    if (-not $dest) { throw 'ProgramData is not set.' }

    $preservedUserDat = $null
    $existingUserDat = Join-Path $dest "user\$TemplateUserId\user.dat"
    if (Test-Path -LiteralPath $existingUserDat -PathType Leaf) {
        $preservedUserDat = Join-Path $env:TEMP ("garena-user-{0}-{1}.dat" -f $TemplateUserId, [Guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $existingUserDat -Destination $preservedUserDat -Force
        Write-ArrangeGarenaLog -LogPath $LogPath -Message 'Preserved existing user.dat from ProgramData'
    }

    if (Test-Path -LiteralPath $dest) {
        $msg = "Replace existing Garena gxx at:`n$dest`n`nWith:`n$SourceGxxDir`n`nContinue?"
        if (-not (Confirm-GarenaDeploy -Message $msg -UseGui:$UseGui)) {
            throw 'Garena gxx deploy cancelled.'
        }
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    $destParent = Split-Path -Parent $dest
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourceGxxDir -Destination $dest -Recurse -Force

    if ($preservedUserDat -and (Test-Path -LiteralPath $preservedUserDat -PathType Leaf)) {
        $destUserDat = Join-Path $dest "user\$TemplateUserId\user.dat"
        $destUserDir = Split-Path -Parent $destUserDat
        if ($destUserDir -and -not (Test-Path -LiteralPath $destUserDir)) {
            New-Item -ItemType Directory -Path $destUserDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $preservedUserDat -Destination $destUserDat -Force
        Write-ArrangeGarenaLog -LogPath $LogPath -Message "Restored preserved user.dat -> $destUserDat"
        Remove-Item -LiteralPath $preservedUserDat -Force -ErrorAction SilentlyContinue
    }

    Write-ArrangeGarenaLog -LogPath $LogPath -Message "DEPLOY gxx -> $dest"
    return $dest
}

function Deploy-GarenaClient {
    param(
        [Parameter(Mandatory)][string]$SourceClientDir,
        [Parameter(Mandatory)][string]$GarenaRoot,
        [Parameter(Mandatory)][string]$LogPath,
        [bool]$UseGui = $true
    )
    $dest = Join-Path $GarenaRoot 'Garena'
    $source = Resolve-ManifestExtractPathString -Path $SourceClientDir
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Garena client source not found: $source"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $source 'Garena.exe') -PathType Leaf)) {
        throw "Garena.exe not found under: $source"
    }
    try {
        $sourceKey = [System.IO.Path]::GetFullPath($source).TrimEnd('\').ToUpperInvariant()
        $destKey = [System.IO.Path]::GetFullPath($dest).TrimEnd('\').ToUpperInvariant()
    }
    catch {
        $sourceKey = $source
        $destKey = $dest
    }
    if ($sourceKey -eq $destKey) {
        Write-ArrangeGarenaLog -LogPath $LogPath -Message "Client left at sync location: $source"
        return $source
    }
    if (Test-Path -LiteralPath $dest) {
        $msg = "Move Garena client from sync location:`n$source`n`nto:`n$dest`n`nContinue? (Leave at sync location if No.)"
        if (-not (Confirm-GarenaDeploy -Message $msg -UseGui:$UseGui)) {
            Write-ArrangeGarenaLog -LogPath $LogPath -Message "Client left at sync location: $source"
            return $source
        }
        Remove-Item -LiteralPath $dest -Recurse -Force
    }
    $destParent = Split-Path -Parent $dest
    if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
        New-Item -ItemType Directory -Path $destParent -Force | Out-Null
    }
    Move-Item -LiteralPath $source -Destination $dest -Force
    Write-ArrangeGarenaLog -LogPath $LogPath -Message "MOVE client -> $dest"
    return $dest
}

function Start-GarenaClientAfterArrange {
    param(
        [Parameter(Mandatory)][string]$ClientDir,
        [string]$LogPath = ''
    )
    $clientDir = Resolve-ManifestExtractPathString -Path $ClientDir
    $exe = Join-Path $clientDir 'Garena.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Write-ArrangeGarenaWarn -LogPath $LogPath -Message "Cannot launch Garena - not found: $exe"
        return $false
    }

    Write-ArrangeGarenaLog -LogPath $LogPath -Message "Launching Garena.exe for manual game sync: $exe"
    Start-Process -FilePath $exe -WorkingDirectory $clientDir

    $serviceLink = Join-Path $clientDir 'Garena platform service.lnk'
    if (Test-Path -LiteralPath $serviceLink -PathType Leaf) {
        try {
            Unblock-File -LiteralPath $serviceLink -ErrorAction SilentlyContinue
            Start-Process -FilePath $serviceLink -WorkingDirectory $clientDir -WindowStyle Hidden -ErrorAction SilentlyContinue
        }
        catch {
            Write-ArrangeGarenaWarn -LogPath $LogPath -Message "Could not start Garena platform service: $($_.Exception.Message)"
        }
    }
    return $true
}

function Invoke-ArrangeGarenaLayout {
    param([switch]$NoGui)

    $UseGui = -not $NoGui.IsPresent
    if ($UseGui) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    $logPath = Get-ArrangeGamesAppsLogPath
    Write-ArrangeGarenaLog -LogPath $logPath -Message '=== Arrange Garena layout started ==='

    $manifestPath = Get-ResolvedDownloadManifestPath
    Write-ArrangeGarenaLog -LogPath $logPath -Message "Manifest: $manifestPath"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Manifest not found: $manifestPath. Run Sync Game/Apps Officially first."
    }

    $appsConfig = Get-GarenaAppsConfig
    $entries = ConvertTo-ObjectArray (Read-DownloadManifestEntries -ManifestPath $manifestPath)
    $extractPath = Resolve-ManifestExtractPathString -Path (Ensure-GarenaForArrange -Entries $entries -LogPath $logPath -UseGui:$UseGui)
    if ([string]::IsNullOrWhiteSpace($extractPath)) {
        throw 'Could not resolve Garena extract path from manifest or install.'
    }

    $bundleRoot = Find-GarenaBundleRootUnderExtract -ExtractPath $extractPath
    if (-not $bundleRoot) {
        throw "Garena bundle layout not found under: $extractPath"
    }
    Write-ArrangeGarenaLog -LogPath $logPath -Message "Bundle root: $bundleRoot"

    $gxxSource = Get-GarenaGxxSourcePath -BundleRoot $bundleRoot
    $clientSource = Get-GarenaClientSourcePath -BundleRoot $bundleRoot
    if (-not (Test-Path -LiteralPath $gxxSource -PathType Container)) {
        throw "Garena gxx source not found: $gxxSource"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $clientSource 'Garena.exe') -PathType Leaf)) {
        throw "Garena.exe not found under: $clientSource"
    }

    $templateRoot = [string]$appsConfig.templateInstallRoot
    $templateUserId = [string]$appsConfig.templateUserId
    $garenaRoot = Resolve-GarenaRootFolder -PickedPath $bundleRoot
    if ($env:NEXTGPU_GARENA_CUSTOM_ROOT -eq '1') {
        $savedRoot = Read-SavedGarenaInstallRoot
        $picked = Pick-GarenaFolder `
            -Description 'Select Garena root (advanced override; default is sync extract folder)' `
            -InitialPath $(if ($savedRoot) { $savedRoot } else { $garenaRoot }) `
            -UseGui:$UseGui
        if (-not $picked) {
            Write-ArrangeGarenaWarn -LogPath $logPath -Message 'Cancelled at Garena root picker.'
            return 0
        }
        $garenaRoot = Resolve-GarenaRootFolder -PickedPath $picked
    }
    Write-ArrangeGarenaLog -LogPath $logPath -Message "GarenaRoot: $garenaRoot"

    $userDatPath = Join-Path $gxxSource "user\$templateUserId\user.dat"
    if (-not (Test-Path -LiteralPath $userDatPath)) {
        throw "Golden user.dat not found: $userDatPath"
    }

    if ($templateRoot -cne $garenaRoot) {
        $null = Update-GarenaTemplateRoot -GxxDir $gxxSource -TemplateRoot $templateRoot -GarenaRoot $garenaRoot -TemplateUserId $templateUserId -LogPath $logPath
    }

    $manifestGameMap = Get-GarenaManifestGamePathMap -Entries $entries
    $savedAppPaths = Read-GarenaAppsPathsMap
    $newAppPaths = @{}
    $layoutChecks = @()

    foreach ($prop in @($appsConfig.apps.PSObject.Properties)) {
        $appId = [string]$prop.Name
        $appCfg = $prop.Value
        $displayName = if ($appCfg.displayName) { [string]$appCfg.displayName } else { $appId }
        $templateInstallPath = [string]$appCfg.templateInstallPath
        if ([string]::IsNullOrWhiteSpace($templateInstallPath)) {
            $templateInstallPath = Join-Path $templateRoot "Games\$appId"
        }

        $defaultPath = Resolve-GarenaAppDefaultPath -AppId $appId -AppConfig $appCfg -ManifestGameMap $manifestGameMap -SavedAppPaths $savedAppPaths
        $pickedRaw = Pick-GarenaFolder `
            -Description ('Select install folder for {0} (app {1}); parent OK if game is in a {1} subfolder' -f $displayName, $appId) `
            -InitialPath $defaultPath `
            -UseGui:$UseGui
        if (-not $pickedRaw) {
            Write-ArrangeGarenaWarn -LogPath $logPath -Message "Skipped app $appId (no folder selected)."
            continue
        }
        if (-not (Test-Path -LiteralPath $pickedRaw -PathType Container)) {
            throw "Selected folder does not exist: $pickedRaw"
        }

        $installPath = Resolve-GarenaAppInstallFolder -PickedPath $pickedRaw -AppId $appId -AppConfig $appCfg -LogPath $logPath
        if (-not (Test-GarenaGameFolderLooksValid -Path $installPath)) {
            Write-ArrangeGarenaWarn -LogPath $logPath -Message "Game folder may be incomplete (no .gpipe/.exe found): $installPath"
        }

        $canonicalPath = Get-GarenaCanonicalGamePath -GarenaRoot $garenaRoot -AppId $appId
        $gamesParent = Split-Path -Parent $canonicalPath
        if ($gamesParent -and -not (Test-Path -LiteralPath $gamesParent)) {
            New-Item -ItemType Directory -Path $gamesParent -Force | Out-Null
        }

        $null = Install-GarenaAppJunctionLayout -CanonicalPath $canonicalPath -TargetPath $installPath -LogPath $logPath

        if (Test-GarenaUserDatHasPlainInstallPath -Path $userDatPath -ExpectedFragment $appId) {
            $count = Update-GarenaAppInstallPath -UserDatPath $userDatPath -TemplateInstallPath $canonicalPath -NewInstallPath $installPath -LogPath $logPath
            if ($count -le 0) {
                $count = Update-GarenaAppInstallPath -UserDatPath $userDatPath -TemplateInstallPath $templateInstallPath -NewInstallPath $installPath -LogPath $logPath
            }
            if ($count -gt 0) {
                Write-ArrangeGarenaLog -LogPath $logPath -Message "user.dat path patched for app $appId"
            }
        }

        $newAppPaths[$appId] = $installPath
        $layoutChecks += [pscustomobject]@{ AppId = $appId; InstallPath = $installPath; CanonicalPath = $canonicalPath }
        Write-ArrangeGarenaLog -LogPath $logPath -Message "App $appId -> $installPath (canonical junction $canonicalPath)"
    }

    $null = Deploy-GarenaGxxToProgramData `
        -SourceGxxDir $gxxSource `
        -TemplateUserId $templateUserId `
        -LogPath $logPath `
        -UseGui:$UseGui
    $clientDir = Deploy-GarenaClient -SourceClientDir $clientSource -GarenaRoot $garenaRoot -LogPath $logPath -UseGui:$UseGui
    $clientRoot = Split-Path -Parent $clientDir

    foreach ($check in @($layoutChecks)) {
        $null = Test-GarenaPostDeployInstallLayout `
            -GarenaRoot $garenaRoot `
            -AppId $check.AppId `
            -ExpectedTargetPath $check.InstallPath `
            -LogPath $logPath
    }

    Save-GarenaInstallRoot -GarenaRoot $clientRoot
    if ($newAppPaths.Count -gt 0) {
        Save-GarenaAppsPathsMap -AppPaths $newAppPaths
    }

    $null = Start-GarenaClientAfterArrange -ClientDir $clientDir -LogPath $logPath

    Write-ArrangeGarenaLog -LogPath $logPath -Message '=== Arrange Garena layout finished ==='
    Write-Host ''
    Write-Host '[OK] Garena arranged and launched.' -ForegroundColor Green
    Write-Host "  Client: $(Join-Path $clientDir 'Garena.exe')" -ForegroundColor DarkGray
    Write-Host "  gxx:    $(Get-GarenaProgramDataGxxPath)" -ForegroundColor DarkGray
    Write-Host '  Sync FC Online in Garena after login.' -ForegroundColor DarkGray

    if ($UseGui) {
        $msg = 'Garena client and gxx deployed. Garena was launched - log in and sync games manually.' +
            [Environment]::NewLine + [Environment]::NewLine + 'Log: ' + $logPath
        [void][System.Windows.Forms.MessageBox]::Show($msg, 'Arrange Garena', 'OK', 'Information')
    }
    return 0
}
