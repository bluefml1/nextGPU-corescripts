#Requires -Version 5.1
<#
.SYNOPSIS
    Download or upload official NextGPU .zip/.7z releases on Cloudflare R2 via rclone.
.DESCRIPTION
    Download (default): lsjson list -> pick -> copyto -> 7z extract -> delete zip.
    Upload (-Push): pick local .zip/.7z -> copyto -> R2 bucket root (same path as official releases).
.PARAMETER Push
    Upload mode: push local archive(s) to the R2 origin instead of downloading.
.PARAMETER LocalFolder
    Folder to scan for .zip/.7z when -Push (optional; prompts if omitted).
.PARAMETER LocalZip
    One or more local archive paths to upload when -Push (skips picker when set).
.PARAMETER PushAllInFolder
    With -LocalFolder, upload every .zip/.7z in that folder without per-file selection.
.PARAMETER ForceOverwrite
    Overwrite existing objects at the same name on R2 without prompting.
#>
[CmdletBinding()]
param(
    [string]$RemoteName = 'r2games',
    [string]$Region = 'auto',
    [string]$DefaultRemotePath = 'next-gpu-storage-app',
    [string]$RcloneIdleTimeout = '24h',
    [switch]$InstallAllZips,
    [switch]$KeepZip,
    [switch]$AllowLegacyFolderSync,
    [switch]$NoGui,
    [switch]$Push,
    [string]$LocalFolder = '',
    [string[]]$LocalZip = @(),
    [switch]$PushAllInFolder,
    [switch]$ForceOverwrite
)

$ErrorActionPreference = 'Stop'
if (-not $NoGui.IsPresent) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName Microsoft.VisualBasic
}
$script:UseGui = -not $NoGui.IsPresent

# --- output helpers ---
function Write-Step([string]$Message) { Write-Host ''; Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) { Write-Host "[FAIL] $Message" -ForegroundColor Red }

function Format-FileSize {
    param([int64]$Bytes)
    if ($Bytes -lt 1KB) { return ("{0} B" -f $Bytes) }
    if ($Bytes -lt 1MB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    if ($Bytes -lt 1GB) { return ("{0:N2} MB" -f ($Bytes / 1MB)) }
    return ("{0:N2} GB" -f ($Bytes / 1GB))
}

function Format-GB([double]$Bytes) { '{0:N2}' -f ($Bytes / 1GB) }

# --- collections (PowerShell unwraps single-element arrays from functions) ---
function ConvertTo-ObjectArray {
    param([AllowNull()]$InputObject)
    if ($null -eq $InputObject) { return @() }
    if ($InputObject -is [System.Collections.Generic.List[object]]) {
        return [object[]]$InputObject.ToArray()
    }
    if ($InputObject.GetType().IsArray) { return [object[]]@($InputObject) }
    return @($InputObject)
}

function Get-ObjectCount {
    param([AllowNull()]$InputObject)
    return @(ConvertTo-ObjectArray $InputObject).Count
}

function To-RcloneLocalPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path).Replace('\', '/')
}

# Flatten nested arrays (PS 5.1 comma-return / @(fn) nests string[] as one element; [string]$nested joins flags).
function Add-FlattenedRcloneArgs {
    param(
        [AllowNull()]$Value,
        [System.Collections.Generic.List[string]]$List
    )
    if ($null -eq $Value) { return }
    if ($Value -is [string]) {
        [void]$List.Add($Value)
        return
    }
    if ($Value -is [System.Array]) {
        foreach ($el in $Value) { Add-FlattenedRcloneArgs -Value $el -List $List }
        return
    }
    [void]$List.Add([string]$Value)
}

function Join-RcloneArgs {
    param([object[]]$Parts)
    if ($null -eq $Parts) { return ,[string[]]@() }
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($part in @($Parts)) {
        Add-FlattenedRcloneArgs -Value $part -List $list
    }
    return ,[string[]]$list.ToArray()
}

# --- rclone (call operator = correct quoting on Windows) ---
function Invoke-Rclone {
    param(
        [Parameter(Mandatory)][string]$Rclone,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$LogFile = '',
        [switch]$Quiet
    )
    $argv = [string[]]@($ArgumentList)
    if ($LogFile) {
        $argv = $argv + [string[]]@('--log-file', ([System.IO.Path]::GetFullPath($LogFile)), '--log-level', 'NOTICE')
    }
    if (-not $Quiet) {
        $argv = $argv + [string[]]@('--stats', '5s', '--stats-one-line', '--progress')
    }
    if (-not $Quiet) {
        Write-Host ("  > rclone {0}" -f ($argv -join ' ')) -ForegroundColor DarkGray
        if ($LogFile) {
            Write-Host "  Live progress below (updates every 5s). Log: $LogFile" -ForegroundColor DarkGray
        }
        else {
            Write-Host '  Live progress below (updates every 5s).' -ForegroundColor DarkGray
        }
        # Do not capture stdout/stderr: 2>&1 buffers until exit, so multi-hour uploads look frozen.
        & $Rclone @argv
    }
    else {
        $null = & $Rclone @argv 2>&1 | Out-Null
    }
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = 1 }
    return [int]$exitCode
}

function Test-LocalZipReady {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int64]$ExpectedBytes = 0
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -lt 1KB) { return $false }
    if ($ExpectedBytes -gt 0) {
        $delta = [math]::Abs($len - $ExpectedBytes)
        return ($delta -le 4096) -or ($len -ge $ExpectedBytes)
    }
    return $true
}

function Get-RcloneJsonLines {
    param(
        [Parameter(Mandatory)][string]$Rclone,
        [Parameter(Mandatory)][object[]]$Args
    )
    $argv = Join-RcloneArgs -Parts @($Args, @(Get-RcloneR2ExtraArgs), @('--timeout', '2m', '--contimeout', '30s'))
    $text = & $Rclone @argv 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("rclone lsjson failed (exit $LASTEXITCODE):`n$text")
    }
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in @($text -split "`r?`n")) {
        $t = $line.Trim()
        if (-not $t -or $t[0] -ne '{') { continue }
        try { [void]$rows.Add(($t | ConvertFrom-Json)) } catch { }
    }
    return ,@(ConvertTo-ObjectArray $rows.ToArray())
}

function Get-RcloneR2ExtraArgs {
    # R2: use no_check_bucket = true in rclone.conf (Repair-RcloneR2RemoteConfig). CLI flag omitted for older rclone.
    return @()
}

function Get-RcloneCopytoArgs {
    param(
        [int64]$SizeBytes = 0
    )
    $a = @(
        @(Get-RcloneR2ExtraArgs),
        @(
            '--retries', '5',
            '--low-level-retries', '10',
            '--contimeout', '60s',
            '--timeout', $RcloneIdleTimeout
        )
    )
    if ($SizeBytes -ge 64MB) {
        $a += @('--multi-thread-streams', '8', '--multi-thread-cutoff', '64M', '--s3-chunk-size', '64M')
    }
    return ,[string[]](Join-RcloneArgs -Parts $a)
}

function Repair-RcloneR2RemoteConfig {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Remote
    )
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return }
    $text = Get-Content -LiteralPath $ConfigPath -Raw
    $escaped = [regex]::Escape($Remote)
    if ($text -notmatch "(?m)^\[$escaped\]$") { return }
    if ($text -notmatch "(?ms)^\[$escaped\]\r?\n(.*?)(?=^\[|\z)") { return }
    $body = $Matches[1].TrimEnd()
    if ($body -match '(?m)^no_check_bucket\s*=\s*true') { return }
    if ($body -match '(?m)^no_check_bucket\s*=') {
        $body = [regex]::Replace($body, '(?m)^no_check_bucket\s*=.*$', 'no_check_bucket = true')
    }
    else {
        $body = $body + [Environment]::NewLine + 'no_check_bucket = true'
    }
    $patched = [regex]::Replace($text, "(?ms)^\[$escaped\]\r?\n.*?(?=^\[|\z)", "[$Remote]`r`n$body`r`n")
    Set-Content -LiteralPath $ConfigPath -Value $patched -Encoding ASCII
    Write-Ok "Patched rclone [$Remote]: no_check_bucket = true (Cloudflare R2)"
}

# --- prompts ---
function Confirm-YesNo {
    param(
        [string]$Title,
        [string]$Prompt,
        [bool]$DefaultYes = $true,
        [switch]$PreferConsole
    )
    if ($PreferConsole -or -not $script:UseGui) {
        Write-Host ''
        Write-Host $Prompt -ForegroundColor Cyan
        $defHint = if ($DefaultYes) { 'Y' } else { 'N' }
        $v = Read-Host "$Title (Y/N, Enter=$defHint)"
        if ([string]::IsNullOrWhiteSpace($v)) { return $DefaultYes }
        return $v.Trim().ToUpperInvariant() -eq 'Y'
    }
    Write-Host '[!] Confirm in the popup (check taskbar if you do not see it).' -ForegroundColor Yellow
    $r = [System.Windows.Forms.MessageBox]::Show($Prompt, $Title,
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return $r -eq [System.Windows.Forms.DialogResult]::Yes
}

function Prompt-YesNo([string]$Title, [string]$Prompt, [bool]$DefaultYes = $true) {
    return (Confirm-YesNo -Title $Title -Prompt $Prompt -DefaultYes $DefaultYes)
}

function Prompt-Text([string]$Title, [string]$Prompt, [string]$Default = '') {
    if (-not $script:UseGui) {
        $v = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
        return $v
    }
    return [Microsoft.VisualBasic.Interaction]::InputBox($Prompt, $Title, $Default)
}

function Prompt-Password([string]$Title, [string]$Prompt) {
    if (-not $script:UseGui) {
        $sec = Read-Host $Prompt -AsSecureString
        $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
    }
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title; $f.Width = 440; $f.Height = 170; $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Left = 12; $lbl.Top = 12; $lbl.Width = 395; $lbl.Text = $Prompt; $f.Controls.Add($lbl)
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Left = 12; $tb.Top = 40; $tb.Width = 395; $tb.UseSystemPasswordChar = $true; $f.Controls.Add($tb)
    $ok = New-Object System.Windows.Forms.Button; $ok.Text = 'OK'; $ok.Left = 250; $ok.Top = 76; $ok.Width = 75; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Controls.Add($ok)
    $ca = New-Object System.Windows.Forms.Button; $ca.Text = 'Cancel'; $ca.Left = 332; $ca.Top = 76; $ca.Width = 75; $ca.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $f.Controls.Add($ca)
    $f.AcceptButton = $ok; $f.CancelButton = $ca
    if ($f.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
    $tb.Text
}

# --- tools ---
function Test-RcloneInstalled { return $null -ne (Get-Command rclone -ErrorAction SilentlyContinue) }
function Test-SevenZipInstalled {
    return $null -ne (Get-SevenZipExe)
}

function Get-RcloneExe {
    $cmd = Get-Command rclone -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            "${env:ProgramFiles}\rclone\rclone.exe",
            "${env:ProgramFiles(x86)}\rclone\rclone.exe",
            (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links\rclone.exe')
        )) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Get-SevenZipExe {
    foreach ($p in @(
            (Join-Path ${env:ProgramFiles} '7-Zip\7z.exe'),
            (Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')
        )) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Ensure-WingetPackage([string]$PackageId, [string]$FriendlyName) {
    $ok = switch ($PackageId) {
        'Rclone.Rclone' { Test-RcloneInstalled }
        '7zip.7zip' { Test-SevenZipInstalled }
        default { $false }
    }
    if ($ok) { Write-Ok "$FriendlyName already installed."; return }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is required. Install App Installer from the Microsoft Store.'
    }
    Write-Warn "Installing $FriendlyName..."
    & winget install --id $PackageId --exact --accept-package-agreements --accept-source-agreements --silent --disable-interactivity --source winget
    if ($LASTEXITCODE -ne 0 -and -not (& { switch ($PackageId) { 'Rclone.Rclone' { Test-RcloneInstalled } '7zip.7zip' { Test-SevenZipInstalled } default { $false } } })) {
        throw "winget install failed for $PackageId (exit $LASTEXITCODE)"
    }
    Write-Ok "$FriendlyName installed."
}

function Update-SessionPath {
    $env:Path = [System.Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [System.Environment]::GetEnvironmentVariable('Path', 'User')
}

function Get-R2ApiEndpoint([string]$AccountIdOrEndpoint) {
    $raw = $AccountIdOrEndpoint.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($raw)) { throw 'Cloudflare Account ID is required for R2.' }
    if ($raw -match 'cdn\.next-gpu\.com') { throw 'Use Cloudflare Account ID, not the CDN hostname.' }
    if ($raw -match '^https?://') {
        if ($raw -notmatch 'r2\.cloudflarestorage\.com') { throw "Endpoint must be *.r2.cloudflarestorage.com (got $raw)" }
        return $raw
    }
    if ($raw -match '\.r2\.cloudflarestorage\.com') { return "https://$raw" }
    return "https://$raw.r2.cloudflarestorage.com"
}

function Ensure-RcloneConfig([string]$Remote, [string]$StorageRegion) {
    $configDir = Join-Path $env:USERPROFILE '.config\rclone'
    $configPath = Join-Path $configDir 'rclone.conf'
    if (-not (Test-Path -LiteralPath $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
    $existing = if (Test-Path -LiteralPath $configPath) { Get-Content -LiteralPath $configPath -Raw } else { '' }
    $hasRemote = $existing -match "(?m)^\[$([regex]::Escape($Remote))\]$"
    if ($hasRemote -and (Prompt-YesNo 'rclone config' "Reuse existing [$Remote] config?" $true)) {
        Repair-RcloneR2RemoteConfig -ConfigPath $configPath -Remote $Remote
        return $configPath
    }
    $accessKey = Prompt-Text 'NextGPU Sync (R2)' 'R2 access_key_id'
    if ([string]::IsNullOrWhiteSpace($accessKey)) { throw 'access_key_id is required.' }
    $secretKey = Prompt-Password 'NextGPU Sync (R2)' 'R2 secret_access_key'
    if ($null -eq $secretKey -or [string]::IsNullOrWhiteSpace($secretKey)) { throw 'secret_access_key is required.' }
    $accountId = Prompt-Text 'NextGPU Sync (R2)' 'Cloudflare Account ID (R2 S3 API)' ''
    $endpoint = Get-R2ApiEndpoint -AccountIdOrEndpoint $accountId
    Write-Ok "R2 endpoint: $endpoint"
    $block = @"
[$Remote]
type = s3
provider = Cloudflare
access_key_id = $accessKey
secret_access_key = $secretKey
region = $StorageRegion
endpoint = $endpoint
acl = private
no_check_bucket = true
"@
    if ([string]::IsNullOrWhiteSpace($existing)) {
        Set-Content -LiteralPath $configPath -Value $block -Encoding ASCII
    }
    elseif ($hasRemote) {
        $escaped = [regex]::Escape($Remote)
        $new = [regex]::Replace($existing, "(?ms)^\[$escaped\]\r?\n.*?(?=^\[|\z)", ($block + [Environment]::NewLine))
        Set-Content -LiteralPath $configPath -Value $new -Encoding ASCII
    }
    else {
        Set-Content -LiteralPath $configPath -Value ($existing.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $block) -Encoding ASCII
    }
    Write-Ok "Updated $configPath"
    Repair-RcloneR2RemoteConfig -ConfigPath $configPath -Remote $Remote
    return $configPath
}

# --- remote listing (one call) ---
function Test-IsArchiveName([string]$Name) {
    return [string]$Name -imatch '\.(zip|7z)$'
}

function Get-DefaultUploadBrowseDirectory {
    foreach ($d in @(
            'Y:\NextGPU-Sync',
            'Y:\',
            'Z:\',
            (Join-Path $env:USERPROFILE 'Downloads'),
            $env:USERPROFILE
        )) {
        if (-not [string]::IsNullOrWhiteSpace($d) -and (Test-Path -LiteralPath $d)) {
            return $d
        }
    }
    return $env:USERPROFILE
}

function Get-ReleaseArchives {
    param(
        [Parameter(Mandatory)][string]$Rclone,
        [Parameter(Mandatory)][string]$RemotePath
    )
    $rows = Get-RcloneJsonLines -Rclone $Rclone -Args @('lsjson', $RemotePath, '--max-depth', '1', '--files-only')
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) {
        if ($null -eq $row) { continue }
        $name = if ($row.Name) { [string]$row.Name } elseif ($row.Path) { [string]$row.Path } else { '' }
        $name = $name.Trim().TrimStart('/').Replace('\', '/')
        if (-not (Test-IsArchiveName -Name $name)) { continue }
        $size = [int64]0
        if ($null -ne $row.Size) { $size = [int64]$row.Size }
        elseif ($null -ne $row.size) { $size = [int64]$row.size }
        [void]$list.Add([pscustomobject]@{ Name = $name; SizeBytes = $size })
    }
    if ($list.Count -gt 0) { return ,@(ConvertTo-ObjectArray $list.ToArray()) }

    Write-Warn 'lsjson empty; trying lsf...'
    $names = & $Rclone @('lsf', $RemotePath, '--max-depth', '1', '--files-only') 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Cannot list $RemotePath`n$names" }
    foreach ($line in @($names -split "`r?`n")) {
        $n = $line.Trim().TrimEnd('/')
        if ($n -and (Test-IsArchiveName -Name $n)) {
            [void]$list.Add([pscustomobject]@{ Name = $n; SizeBytes = [int64]0 })
        }
    }
    return ,@(ConvertTo-ObjectArray $list.ToArray())
}

function Get-ArchiveSizeBytes {
    param(
        [string]$Rclone,
        [string]$RemoteZipPath,
        [int64]$ListedSize = 0
    )
    if ($ListedSize -gt 0) { return $ListedSize }
    $out = & $Rclone @('lsl', $RemoteZipPath, '--timeout', '1m') 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($out -split "`r?`n")) {
            if ($line -match '^\s*(-?\d+)\s') { return [int64]$Matches[1] }
        }
    }
    $parent = $RemoteZipPath -replace '/[^/]+$', ''
    $base = ($RemoteZipPath -split '/')[-1]
    if ($parent -and $base) {
        $out2 = & $Rclone @('lsl', $parent, '--timeout', '1m') 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $esc = [regex]::Escape($base)
            foreach ($line in @($out2 -split "`r?`n")) {
                if ($line -match $esc -and $line -match '^\s*(-?\d+)\s') { return [int64]$Matches[1] }
            }
        }
    }
    return [int64]0
}

# --- UI ---
function Select-TargetDrive {
    $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { -not $_.DisplayRoot } | Sort-Object Name)
    if ($drives.Count -eq 0) { throw 'No local drive found.' }
    if (-not $script:UseGui) {
        for ($i = 0; $i -lt $drives.Count; $i++) {
            Write-Host ("[{0}] {1}:\  {2} GB free" -f ($i + 1), $drives[$i].Name, (Format-GB $drives[$i].Free))
        }
        $n = 0
        [void][int]::TryParse((Read-Host 'Drive number'), [ref]$n)
        $idx = $n - 1
        if ($idx -lt 0 -or $idx -ge $drives.Count) { throw 'Invalid drive.' }
        return $drives[$idx]
    }
    $lines = ($drives | ForEach-Object { '{0}:\  {1} GB free' -f $_.Name, (Format-GB $_.Free) }) -join "`n"
    $pick = Prompt-Text 'Drive' ("$lines`n`nDrive letter (e.g. Y)") ''
    $name = $pick.Trim().TrimEnd(':').ToUpperInvariant()
    $sel = $drives | Where-Object { $_.Name.ToUpperInvariant() -eq $name } | Select-Object -First 1
    if (-not $sel) { throw "Invalid drive: $pick" }
    return $sel
}

function Resolve-TargetFolder([string]$TargetBase) {
    $default = Join-Path $TargetBase 'NextGPU-Sync'
    if (-not (Test-Path -LiteralPath $default)) { New-Item -ItemType Directory -Path $default -Force | Out-Null }
    if (Prompt-YesNo 'Folder' "Use default folder?`n`n$default" $true) { return $default }
    if (-not $script:UseGui) {
        $v = Read-Host "Folder path (default: $default)"
        if ([string]::IsNullOrWhiteSpace($v)) { return $default }
        return $v
    }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $default
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) { return $dlg.SelectedPath }
    return $default
}

function Select-ReleaseArchives {
    param([array]$Archives)
    $items = ConvertTo-ObjectArray $Archives
    if ((Get-ObjectCount $items) -eq 0) { return ,@() }
    if (-not $script:UseGui) {
        Write-Host 'Archives:' -ForegroundColor Yellow
        for ($i = 0; $i -lt (Get-ObjectCount $items); $i++) {
            $a = $items[$i]
            $sz = if ($a.SizeBytes -gt 0) { Format-FileSize $a.SizeBytes } else { 'size unknown' }
            Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $a.Name, $sz)
        }
        $raw = Read-Host 'Numbers to install (e.g. 1,2) or Enter to cancel'
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $picked = New-Object System.Collections.Generic.List[object]
        foreach ($part in $raw.Split(',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n)) {
                $idx = $n - 1
                if ($idx -ge 0 -and $idx -lt $items.Count) { [void]$picked.Add($items[$idx]) }
            }
        }
        return ,(ConvertTo-ObjectArray $picked.ToArray())
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Select release archives'
    $form.Width = 760; $form.Height = 560; $form.StartPosition = 'CenterScreen'
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Left = 12; $lbl.Top = 12; $lbl.Width = 720
    $lbl.Text = "Select .zip / .7z from R2 ($($items.Count) available):"
    $form.Controls.Add($lbl)
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Left = 12; $list.Top = 40; $list.Width = 720; $list.Height = 450
    $list.CheckOnClick = $true
    $rowList = New-Object System.Collections.Generic.List[object]
    foreach ($a in $items) {
        $sz = if ($a.SizeBytes -gt 0) { Format-FileSize $a.SizeBytes } else { '?' }
        [void]$list.Items.Add(('[{0}] {1}' -f $sz, $a.Name))
        [void]$rowList.Add($a)
    }
    $form.Controls.Add($list)
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'Select all'; $btnAll.Left = 12; $btnAll.Top = 498; $btnAll.Width = 90
    $btnAll.Add_Click({ for ($j = 0; $j -lt $list.Items.Count; $j++) { $list.SetItemChecked($j, $true) } })
    $form.Controls.Add($btnAll)
    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = 'Clear'; $btnNone.Left = 108; $btnNone.Top = 498; $btnNone.Width = 90
    $btnNone.Add_Click({ for ($j = 0; $j -lt $list.Items.Count; $j++) { $list.SetItemChecked($j, $false) } })
    $form.Controls.Add($btnNone)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'OK'; $ok.Left = 575; $ok.Top = 498; $ok.Width = 75; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Left = 657; $cancel.Top = 498; $cancel.Width = 75; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return ,@() }
    $picked = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $list.Items.Count; $i++) {
        if ($list.GetItemChecked($i)) { [void]$picked.Add($rowList[$i]) }
    }
    return ,(ConvertTo-ObjectArray $picked.ToArray())
}

function Select-LocalArchivesForUpload {
    param(
        [array]$Archives,
        [string]$SourceLabel
    )
    $items = ConvertTo-ObjectArray $Archives
    if ((Get-ObjectCount $items) -eq 0) { return ,@() }
    if (-not $script:UseGui) {
        Write-Host "Archives in $SourceLabel :" -ForegroundColor Yellow
        for ($i = 0; $i -lt (Get-ObjectCount $items); $i++) {
            $a = $items[$i]
            Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $a.Name, (Format-FileSize $a.SizeBytes))
        }
        $raw = Read-Host 'Numbers to upload (e.g. 1,2) or Enter to cancel'
        if ([string]::IsNullOrWhiteSpace($raw)) { return ,@() }
        $picked = New-Object System.Collections.Generic.List[object]
        foreach ($part in $raw.Split(',')) {
            $n = 0
            if ([int]::TryParse($part.Trim(), [ref]$n)) {
                $idx = $n - 1
                if ($idx -ge 0 -and $idx -lt $items.Count) { [void]$picked.Add($items[$idx]) }
            }
        }
        return ,(ConvertTo-ObjectArray $picked.ToArray())
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Select archives to upload'
    $form.Width = 820; $form.Height = 580; $form.StartPosition = 'CenterScreen'
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Left = 12; $lbl.Top = 12; $lbl.Width = 780
    $lbl.Text = "Check .zip / .7z to upload ($SourceLabel, $($items.Count) found):"
    $form.Controls.Add($lbl)
    $list = New-Object System.Windows.Forms.CheckedListBox
    $list.Left = 12; $list.Top = 40; $list.Width = 780; $list.Height = 450
    $list.CheckOnClick = $true
    $rowList = New-Object System.Collections.Generic.List[object]
    foreach ($a in $items) {
        $sz = Format-FileSize $a.SizeBytes
        [void]$list.Items.Add(('[{0}] {1}' -f $sz, $a.Name))
        [void]$rowList.Add($a)
    }
    $form.Controls.Add($list)
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = 'Select all'; $btnAll.Left = 12; $btnAll.Top = 502; $btnAll.Width = 90
    $btnAll.Add_Click({ for ($j = 0; $j -lt $list.Items.Count; $j++) { $list.SetItemChecked($j, $true) } })
    $form.Controls.Add($btnAll)
    $btnNone = New-Object System.Windows.Forms.Button
    $btnNone.Text = 'Clear'; $btnNone.Left = 108; $btnNone.Top = 502; $btnNone.Width = 90
    $btnNone.Add_Click({ for ($j = 0; $j -lt $list.Items.Count; $j++) { $list.SetItemChecked($j, $false) } })
    $form.Controls.Add($btnNone)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Upload'; $ok.Left = 615; $ok.Top = 502; $ok.Width = 85; $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancel'; $cancel.Left = 708; $cancel.Top = 502; $cancel.Width = 85; $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)
    $form.AcceptButton = $ok; $form.CancelButton = $cancel
    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return ,@() }
    $picked = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $list.Items.Count; $i++) {
        if ($list.GetItemChecked($i)) { [void]$picked.Add($rowList[$i]) }
    }
    return ,(ConvertTo-ObjectArray $picked.ToArray())
}

function Pick-LocalArchivesOpenFileDialog {
    param([string]$InitialDirectory = '')
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = 'Select .zip / .7z files to upload to R2'
    $dlg.Filter = 'ZIP archive (*.zip)|*.zip|7-Zip archive (*.7z)|*.7z|All files (*.*)|*.*'
    $dlg.FilterIndex = 1
    $dlg.Multiselect = $true
    $dlg.CheckFileExists = $true
    $startDir = $InitialDirectory
    if ([string]::IsNullOrWhiteSpace($startDir)) {
        $startDir = Get-DefaultUploadBrowseDirectory
    }
    if (Test-Path -LiteralPath $startDir) {
        $dlg.InitialDirectory = $startDir
    }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return ,@()
    }
    $picked = New-Object System.Collections.Generic.List[object]
    foreach ($path in @($dlg.FileNames)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $leaf = [System.IO.Path]::GetFileName($path)
        if (-not (Test-IsArchiveName -Name $leaf)) { continue }
        $fi = Get-Item -LiteralPath $path
        [void]$picked.Add([pscustomobject]@{
                Name      = $leaf
                FullPath  = $fi.FullName
                SizeBytes = [int64]$fi.Length
            })
    }
    return ,(ConvertTo-ObjectArray $picked.ToArray())
}

function Show-UploadPickerChoice {
    # Returns: Files | Folder | Cancel
    if (-not $script:UseGui) { return 'Files' }
    $r = [System.Windows.Forms.MessageBox]::Show(
        "How do you want to choose archives to upload?`n`nYes = pick .zip / .7z files`nNo = pick a folder (then choose from a list)`nCancel = abort",
        'NextGPU Upload',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    switch ($r) {
        ([System.Windows.Forms.DialogResult]::Yes) { return 'Files' }
        ([System.Windows.Forms.DialogResult]::No) { return 'Folder' }
        default { return 'Cancel' }
    }
}

# --- install one archive ---
function Expand-Archive7z {
    param(
        [Parameter(Mandatory)][string]$SevenZip,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
    $destArg = $DestinationPath.TrimEnd('\', '/').Replace('\', '/') + '/'
    & $SevenZip x $ArchivePath "-o$destArg" -y -bb1 | Out-Host
    if ($LASTEXITCODE -ge 2) { throw "7-Zip failed (exit $LASTEXITCODE)" }
}

function Install-ReleaseArchive {
    param(
        [Parameter(Mandatory)][string]$Rclone,
        [Parameter(Mandatory)][string]$SevenZip,
        [Parameter(Mandatory)][string]$RemoteZip,
        [Parameter(Mandatory)][string]$LocalDir,
        [Parameter(Mandatory)][string]$ZipName,
        [Parameter(Mandatory)][string]$LogFile,
        [int64]$ListedSize = 0,
        [switch]$KeepArchive
    )
    if (-not (Test-Path -LiteralPath $LocalDir)) {
        New-Item -ItemType Directory -Path $LocalDir -Force | Out-Null
    }
    $localZip = [System.IO.Path]::GetFullPath((Join-Path $LocalDir $ZipName))
    $localRclone = To-RcloneLocalPath -Path $localZip
    $size = Get-ArchiveSizeBytes -Rclone $Rclone -RemoteZipPath $RemoteZip -ListedSize $ListedSize
    if ($size -gt 0) {
        Write-Ok ("Size: {0}" -f (Format-FileSize $size))
    }

    Write-Step "Downloading $ZipName ..."
    $copyArgs = Join-RcloneArgs -Parts @(
        @('copyto', $RemoteZip, $localRclone),
        @(Get-RcloneCopytoArgs -SizeBytes $size)
    )
    $exitCode = Invoke-Rclone -Rclone $Rclone -ArgumentList $copyArgs -LogFile $LogFile
    if (-not (Test-LocalZipReady -Path $localZip -ExpectedBytes $size)) {
        if ($exitCode -eq 0) { $exitCode = 1 }
    }
    else {
        $exitCode = 0
    }
    if ($exitCode -ne 0) {
        Write-Warn "copyto failed (exit $exitCode); trying rclone copy into destination folder..."
        if (Test-Path -LiteralPath $localZip) {
            $partial = (Get-Item -LiteralPath $localZip).Length
            if ($size -gt 0 -and $partial -lt ($size - 4096)) {
                Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue
            }
        }
        $localDirR = (To-RcloneLocalPath -Path $LocalDir).TrimEnd('/') + '/'
        $copyArgs2 = Join-RcloneArgs -Parts @(
            @('copy', $RemoteZip, $localDirR),
            @(Get-RcloneCopytoArgs -SizeBytes $size)
        )
        $exitCode = Invoke-Rclone -Rclone $Rclone -ArgumentList $copyArgs2 -LogFile $LogFile
        if (Test-LocalZipReady -Path $localZip -ExpectedBytes $size) { $exitCode = 0 }
    }
    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $localZip) { Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue }
        Write-Fail "rclone download failed (exit $exitCode). See log: $LogFile"
        return [int]$exitCode
    }
    if (-not (Test-Path -LiteralPath $localZip)) {
        Write-Fail "Download finished but file missing: $localZip"
        return 1
    }
    Write-Ok ("Downloaded {0}" -f (Format-FileSize (Get-Item -LiteralPath $localZip).Length))

    Write-Step "Extracting $ZipName ..."
    try {
        Expand-Archive7z -SevenZip $SevenZip -ArchivePath $localZip -DestinationPath $LocalDir
    }
    catch {
        Write-Fail $_.Exception.Message
        return 1
    }
    Write-Ok "Extracted to $LocalDir"

    if (-not $KeepArchive) {
        $freed = (Get-Item -LiteralPath $localZip).Length
        Remove-Item -LiteralPath $localZip -Force
        Write-Ok ("Removed zip (freed {0})" -f (Format-FileSize $freed))
    }
    return 0
}

function Install-LegacyFolder {
    param(
        [string]$Rclone,
        [string]$RemotePath,
        [string]$LocalDir,
        [string]$LogFile
    )
    Write-Step "Copying folder $RemotePath ..."
    $copyArgs = Join-RcloneArgs -Parts @(
        @(
            'copy', $RemotePath, (To-RcloneLocalPath -Path $LocalDir).TrimEnd('/') + '/',
            '--transfers', '32', '--checkers', '64',
            '--retries', '5', '--contimeout', '60s', '--timeout', $RcloneIdleTimeout,
            '--s3-chunk-size', '64M', '--multi-thread-streams', '8', '--multi-thread-cutoff', '64M'
        )
    )
    return (Invoke-Rclone -Rclone $Rclone -ArgumentList $copyArgs -LogFile $LogFile)
}

function Invoke-DiskPrepIfRequested {
    if (-not (Prompt-YesNo 'Disk prep' 'Run CHKDSK / partition prep first?' $false)) { return }
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Run-ChkDsk-Repair.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'CHKDSK prep failed.' }
    if (Prompt-YesNo 'Disk prep' 'Run partition step?' $false) {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Create-Z-Partition.ps1')
        if ($LASTEXITCODE -ne 0) { throw 'Partition prep failed.' }
    }
}

function Show-LogTail([string]$LogFile) {
    if (-not (Test-Path -LiteralPath $LogFile)) { return }
    Write-Host '  Log (last 12 lines):' -ForegroundColor DarkRed
    Get-Content -LiteralPath $LogFile -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "    $_" -ForegroundColor DarkRed
    }
}

# --- upload to R2 ---
function Get-LocalReleaseArchives {
    param([Parameter(Mandatory)][string]$Folder)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "Folder not found: $Folder"
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($f in Get-ChildItem -LiteralPath $Folder -File | Sort-Object Name) {
        if (-not (Test-IsArchiveName -Name $f.Name)) { continue }
        [void]$list.Add([pscustomobject]@{
                Name       = $f.Name
                FullPath   = $f.FullName
                SizeBytes  = [int64]$f.Length
            })
    }
    return ,@(ConvertTo-ObjectArray $list.ToArray())
}

function Resolve-LocalZipInputs {
    param(
        [string[]]$ZipPaths,
        [string]$Folder = '',
        [switch]$AllInFolder
    )
    $resolved = New-Object System.Collections.Generic.List[object]

    foreach ($p in @($ZipPaths)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $full = [System.IO.Path]::GetFullPath($p.Trim().Trim('"'))
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "File not found: $full"
        }
        $leaf = [System.IO.Path]::GetFileName($full)
        if (-not (Test-IsArchiveName -Name $leaf)) {
            throw "Not a .zip or .7z file: $leaf"
        }
        $fi = Get-Item -LiteralPath $full
        [void]$resolved.Add([pscustomobject]@{
                Name      = $leaf
                FullPath  = $fi.FullName
                SizeBytes = [int64]$fi.Length
            })
    }
    if ($resolved.Count -gt 0) {
        return ,(ConvertTo-ObjectArray $resolved.ToArray())
    }

    if ($script:UseGui -and [string]::IsNullOrWhiteSpace($Folder) -and -not $AllInFolder) {
        $choice = Show-UploadPickerChoice
        if ($choice -eq 'Cancel') { return ,@() }
        if ($choice -eq 'Files') {
            return ,(Pick-LocalArchivesOpenFileDialog -InitialDirectory (Get-DefaultUploadBrowseDirectory))
        }
    }

    $scanDir = $Folder
    if ([string]::IsNullOrWhiteSpace($scanDir)) {
        if (-not $script:UseGui) {
            $scanDir = Read-Host 'Folder containing .zip / .7z to upload'
        }
        else {
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = 'Select folder with .zip / .7z files to upload'
            $dlg.SelectedPath = Get-DefaultUploadBrowseDirectory
            if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK -or -not $dlg.SelectedPath) {
                return ,@()
            }
            $scanDir = $dlg.SelectedPath
        }
    }
    if ([string]::IsNullOrWhiteSpace($scanDir)) { return ,@() }

    $scanDir = [System.IO.Path]::GetFullPath($scanDir.Trim().Trim('"'))
    $found = ConvertTo-ObjectArray (Get-LocalReleaseArchives -Folder $scanDir)
    if ((Get-ObjectCount $found) -eq 0) {
        throw "No .zip or .7z files in: $scanDir (checked file names, case-insensitive)"
    }
    if ($AllInFolder) { return ,$found }

    return ,(Select-LocalArchivesForUpload -Archives $found -SourceLabel $scanDir)
}

function Test-RemoteArchiveExists {
    param(
        [Parameter(Mandatory)][string]$Rclone,
        [Parameter(Mandatory)][string]$RemoteZipPath
    )
    $argv = Join-RcloneArgs -Parts @(@('lsf', $RemoteZipPath, '--files-only'), @(Get-RcloneR2ExtraArgs), @('--timeout', '45s'))
    $out = & $Rclone @argv 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($out.Trim())) {
        return $true
    }
    return $false
}

function Push-ArchiveToR2 {
    param(
        [Parameter(Mandatory)][string]$Rclone,
        [Parameter(Mandatory)][string]$RemoteRoot,
        [Parameter(Mandatory)][string]$LocalZipPath,
        [Parameter(Mandatory)][string]$LogFile,
        [string]$RemoteFileName = '',
        [switch]$Overwrite
    )
    if (-not (Test-Path -LiteralPath $LocalZipPath -PathType Leaf)) {
        Write-Fail "Local file missing: $LocalZipPath"
        return 1
    }

    $leaf = if ($RemoteFileName) { $RemoteFileName.Trim() } else { [System.IO.Path]::GetFileName($LocalZipPath) }
    if (-not (Test-IsArchiveName -Name $leaf)) {
        Write-Fail "Remote name must end with .zip or .7z: $leaf"
        return 1
    }

    $remoteZip = "$RemoteRoot/$leaf"
    $localRclone = To-RcloneLocalPath -Path $LocalZipPath
    $size = (Get-Item -LiteralPath $LocalZipPath).Length
    $sizeLabel = Format-FileSize $size
    $preferConsole = ($size -ge 1GB)

    Write-Host "  Local: $localRclone ($sizeLabel)" -ForegroundColor DarkGray
    Write-Host '  Checking if object already exists on R2...' -ForegroundColor DarkGray

    if (Test-RemoteArchiveExists -Rclone $Rclone -RemoteZipPath $remoteZip) {
        Write-Warn "Remote already has: $leaf"
        if (-not $Overwrite) {
            $ans = Confirm-YesNo -Title 'Overwrite?' `
                -Prompt "Remote already has $leaf. Replace it on R2?" `
                -DefaultYes $false -PreferConsole:$preferConsole
            if (-not $ans) {
                Write-Warn "Skipped (exists on R2): $leaf"
                return 2
            }
        }
        else {
            Write-Warn "Overwriting existing remote object: $leaf"
        }
    }
    else {
        Write-Host '  Not on R2 yet (new upload).' -ForegroundColor DarkGray
    }

    if ($size -ge 1GB) {
        Write-Warn "Large upload ($sizeLabel). This can take hours. rclone progress will appear below."
    }

    Write-Step "Uploading $leaf ($sizeLabel) -> $remoteZip ..."
    $copyArgs = Join-RcloneArgs -Parts @(
        @('copyto', $localRclone, $remoteZip),
        @(Get-RcloneCopytoArgs -SizeBytes $size)
    )
    $exitCode = Invoke-Rclone -Rclone $Rclone -ArgumentList $copyArgs -LogFile $LogFile

    if ($exitCode -eq 0) {
        Write-Host '  Verifying remote size...' -ForegroundColor DarkGray
        $remoteSize = Get-ArchiveSizeBytes -Rclone $Rclone -RemoteZipPath $remoteZip -ListedSize 0
        if ($remoteSize -gt 0 -and [math]::Abs($remoteSize - $size) -gt 4096) {
            Write-Warn "Upload finished but remote size differs (local $sizeLabel, remote $(Format-FileSize $remoteSize))."
            $exitCode = 1
        }
    }
    else {
        $remoteSize = [int64]0
    }

    if ($exitCode -ne 0) {
        Write-Fail "Upload failed (exit $exitCode): $leaf"
        if (Test-Path -LiteralPath $LogFile) {
            $tail = Get-Content -LiteralPath $LogFile -Tail 5 -ErrorAction SilentlyContinue | Out-String
            if ($tail -match 'CreateBucket' -and $tail -match 'AccessDenied') {
                Write-Warn 'R2 rejected CreateBucket. Re-run push (script patches no_check_bucket) or add no_check_bucket = true under [r2games] in %USERPROFILE%\.config\rclone\rclone.conf'
            }
        }
        return [int]$exitCode
    }

    $shown = if ($remoteSize -gt 0) { Format-FileSize $remoteSize } else { $sizeLabel }
    Write-Ok ("Uploaded {0} to R2 ({1})" -f $leaf, $shown)
    return 0
}

function Invoke-PushToR2Flow {
    Write-Host '==============================================='
    Write-Host ' NextGPU R2 upload (push .zip / .7z to origin)'
    Write-Host '  Script: 2026-06-02f (live rclone progress; R2 no_check_bucket in rclone.conf)'
    Write-Host '==============================================='

    Ensure-WingetPackage -PackageId 'Rclone.Rclone' -FriendlyName 'rclone'
    Update-SessionPath

    $rclone = Get-RcloneExe
    if (-not $rclone) { throw 'rclone not found.' }
    Write-Ok "rclone: $rclone"

    $null = Ensure-RcloneConfig -Remote $RemoteName -StorageRegion $Region
    $remoteRoot = "${RemoteName}:$($DefaultRemotePath.Trim().TrimEnd('/'))"

    Write-Step "Checking remote $remoteRoot ..."
    $pfArgv = Join-RcloneArgs -Parts @(@('lsf', $remoteRoot, '--max-depth', '1'), @(Get-RcloneR2ExtraArgs))
    $pf = & $rclone @pfArgv 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("Cannot reach $remoteRoot. Check rclone config (R2 API endpoint, not CDN).`n$pf")
    }

    $toUpload = ConvertTo-ObjectArray (Resolve-LocalZipInputs -ZipPaths $LocalZip -Folder $LocalFolder -AllInFolder:$PushAllInFolder.IsPresent)
    if ((Get-ObjectCount $toUpload) -eq 0) { throw 'No local archive selected for upload.' }

    Write-Ok ("{0} file(s) selected for upload." -f (Get-ObjectCount $toUpload))
    foreach ($a in $toUpload) {
        Write-Host ("  - {0}  {1}" -f $a.Name, (Format-FileSize $a.SizeBytes)) -ForegroundColor DarkGray
        Write-Host ("      {0}" -f $a.FullPath) -ForegroundColor DarkGray
    }

    $maxBytes = [int64]0
    foreach ($a in $toUpload) {
        if ([int64]$a.SizeBytes -gt $maxBytes) { $maxBytes = [int64]$a.SizeBytes }
    }
    $confirmConsole = ($maxBytes -ge 1GB)
    if ($confirmConsole) {
        Write-Warn 'Large file(s) selected — confirmation will use this console (not a popup).'
    }
    if (-not (Confirm-YesNo -Title 'Upload' -Prompt "Upload to $remoteRoot ?" -DefaultYes $true -PreferConsole:$confirmConsole)) {
        exit 0
    }

    $logDir = Join-Path $env:ProgramData 'nextGPU\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir ("push-games-apps-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Write-Host "Log: $logFile" -ForegroundColor Cyan

    $exitCode = 0
    $index = 0
    $uploadCount = Get-ObjectCount $toUpload
    foreach ($a in $toUpload) {
        $index++
        Write-Host ''
        Write-Host "=== [$index/$uploadCount] $($a.Name) ===" -ForegroundColor Cyan
        Write-Host '  Starting upload step (see messages below)...' -ForegroundColor DarkGray
        $code = Push-ArchiveToR2 -Rclone $rclone -RemoteRoot $remoteRoot `
            -LocalZipPath $a.FullPath -LogFile $logFile -Overwrite:$ForceOverwrite.IsPresent
        if ($code -eq 2) { continue }
        if ($code -ne 0) {
            Show-LogTail -LogFile $logFile
            $exitCode = [int]$code
            break
        }
    }

    Write-Host ''
    if ($exitCode -eq 0) {
        Write-Ok 'Upload complete.'
        Write-Host "Remote: $remoteRoot" -ForegroundColor Green
        if ($script:UseGui) {
            [void][System.Windows.Forms.MessageBox]::Show("Upload done.`n$remoteRoot`n`nLog: $logFile", 'NextGPU Upload', 'OK', 'Information')
        }
        exit 0
    }

    Write-Fail "Upload stopped (exit $exitCode)."
    if ($script:UseGui) {
        [void][System.Windows.Forms.MessageBox]::Show("Upload failed.`nLog: $logFile", 'NextGPU Upload', 'OK', 'Error')
    }
    exit $exitCode
}

# ========== main ==========
if ($Push.IsPresent) {
    Invoke-PushToR2Flow
    exit $LASTEXITCODE
}

Write-Host '==============================================='
Write-Host ' NextGPU official release sync (rclone + 7-Zip)'
Write-Host '  Script: 2026-06-02f (download + -Push upload to R2)'
Write-Host '  Flow: lsjson list -> pick -> copyto -> 7z -> delete zip'
Write-Host '==============================================='

Invoke-DiskPrepIfRequested

Ensure-WingetPackage -PackageId 'Rclone.Rclone' -FriendlyName 'rclone'
Ensure-WingetPackage -PackageId '7zip.7zip' -FriendlyName '7-Zip'
Update-SessionPath

$rclone = Get-RcloneExe
if (-not $rclone) { throw 'rclone not found.' }
$sevenZip = Get-SevenZipExe
if (-not $sevenZip) { throw '7-Zip not found.' }
Write-Ok "rclone: $rclone"
Write-Ok "7-Zip: $sevenZip"

$null = Ensure-RcloneConfig -Remote $RemoteName -StorageRegion $Region
$remoteRoot = "${RemoteName}:$($DefaultRemotePath.Trim().TrimEnd('/'))"

Write-Step "Checking remote $remoteRoot ..."
$pfArgv = Join-RcloneArgs -Parts @(@('lsf', $remoteRoot, '--max-depth', '1'), @(Get-RcloneR2ExtraArgs))
$pf = & $rclone @pfArgv 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw ("Cannot reach $remoteRoot. Check rclone config (R2 API endpoint, not CDN).`n$pf")
}

Write-Step "Listing archives at $remoteRoot ..."
$archives = ConvertTo-ObjectArray (Get-ReleaseArchives -Rclone $rclone -RemotePath $remoteRoot)
if ((Get-ObjectCount $archives) -eq 0) {
    if (-not $AllowLegacyFolderSync) {
        throw "No .zip/.7z at $remoteRoot. Upload release zips to R2, or use -AllowLegacyFolderSync."
    }
    $drive = Select-TargetDrive
    $targetFolder = Resolve-TargetFolder -TargetBase "$($drive.Name):\"
    if (-not (Prompt-YesNo 'Legacy sync' "Copy entire remote folder to:`n$targetFolder ?" $false)) { exit 0 }
    $logDir = Join-Path $env:ProgramData 'nextGPU\logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $logFile = Join-Path $logDir ("sync-games-apps-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $code = Install-LegacyFolder -Rclone $rclone -RemotePath $remoteRoot -LocalDir $targetFolder -LogFile $logFile
    if ($code -ne 0) { Show-LogTail -LogFile $logFile; exit $code }
    Write-Ok "Legacy copy done -> $targetFolder"
    exit 0
}

Write-Ok ("Found {0} archive(s)." -f (Get-ObjectCount $archives))

if ($InstallAllZips) {
    $picked = $archives
}
else {
    $picked = ConvertTo-ObjectArray (Select-ReleaseArchives -Archives $archives)
    if ((Get-ObjectCount $picked) -eq 0) { throw 'No archive selected.' }
}
$picked = ConvertTo-ObjectArray $picked
$pickCount = Get-ObjectCount $picked

$drive = Select-TargetDrive
Write-Ok ("Drive {0}: {1} GB free" -f $drive.Name, (Format-GB $drive.Free))
$targetFolder = Resolve-TargetFolder -TargetBase "$($drive.Name):\"

$totalBytes = [int64]0
$largest = [int64]0
$sizeByName = @{}
foreach ($a in $picked) {
    $sz = [int64]$a.SizeBytes
    if ($sz -le 0) {
        $sz = Get-ArchiveSizeBytes -Rclone $rclone -RemoteZipPath "$remoteRoot/$($a.Name)" -ListedSize 0
    }
    $sizeByName[[string]$a.Name] = $sz
    if ($sz -gt 0) {
        $totalBytes += $sz
        if ($sz -gt $largest) { $largest = $sz }
    }
    Write-Host ("  - {0}  {1}" -f $a.Name, $(if ($sz -gt 0) { Format-FileSize $sz } else { 'size unknown' })) -ForegroundColor DarkGray
}

if ($KeepZip) {
    $needDisk = [int64]([math]::Ceiling($totalBytes * 2.1))
}
elseif ($largest -gt 0) {
    $needDisk = [int64]([math]::Ceiling($largest * 2.1))
}
else {
    $needDisk = [int64]0
}
if ($needDisk -gt 0 -and $drive.Free -lt $needDisk) {
    Write-Warn ("Recommend {0} GB free; you have {1} GB." -f (Format-GB $needDisk), (Format-GB $drive.Free))
    if (-not (Prompt-YesNo 'Space' 'Continue anyway?' $false)) { throw 'Aborted.' }
}

if (-not (Prompt-YesNo 'NextGPU Sync' 'Proceed?' $true)) { exit 0 }

$logDir = Join-Path $env:ProgramData 'nextGPU\logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir ("sync-games-apps-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-Host "Log: $logFile" -ForegroundColor Cyan

$exitCode = 0
$index = 0
foreach ($a in $picked) {
    $index++
    $name = [string]$a.Name
    Write-Host ''; Write-Host "=== [$index/$pickCount] $name ===" -ForegroundColor Cyan
    $listed = if ($sizeByName.ContainsKey($name)) { [int64]$sizeByName[$name] } else { [int64]0 }
    $stepExit = Install-ReleaseArchive -Rclone $rclone -SevenZip $sevenZip `
        -RemoteZip "$remoteRoot/$name" -LocalDir $targetFolder -ZipName $name `
        -LogFile $logFile -ListedSize $listed -KeepArchive:$KeepZip.IsPresent
    if ($stepExit -ne 0) {
        Show-LogTail -LogFile $logFile
        $exitCode = [int]$stepExit
        break
    }
}

Write-Host ''
if ($exitCode -eq 0) {
    Write-Ok 'All releases installed.'
    Write-Host "Output: $targetFolder" -ForegroundColor Green
    if ($script:UseGui) {
        [void][System.Windows.Forms.MessageBox]::Show("Done.`n$targetFolder`n`nLog: $logFile", 'NextGPU Sync', 'OK', 'Information')
    }
    exit 0
}

Write-Fail "Stopped with error (exit $exitCode)."
if ($script:UseGui) {
    [void][System.Windows.Forms.MessageBox]::Show("Failed.`nLog: $logFile", 'NextGPU Sync', 'OK', 'Error')
}
exit $exitCode
