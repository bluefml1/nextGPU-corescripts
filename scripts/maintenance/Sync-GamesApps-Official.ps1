#Requires -Version 5.1
<#
.SYNOPSIS
    Download or upload official NextGPU .zip/.7z releases on Cloudflare R2 via rclone.
.DESCRIPTION
    Download (default): lsjson list -> pick -> copyto -> 7z extract into per-archive folder (e.g. Adobe\) -> flatten duplicate root (Adobe\Adobe -> Adobe\) -> delete zip -> append reusable manifest .txt (Steam appmanifest scan).
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
.PARAMETER DownloadMultiThreadStreams
    Parallel download streams for archives >= 64 MiB (default 8). Use -NoMultiThreadDownload to disable.
.PARAMETER NoMultiThreadDownload
    Force single-stream R2 downloads (slower; use if multi-thread fails on your bucket).
#>
[CmdletBinding()]
param(
    [string]$RemoteName = 'r2games',
    [string]$Region = 'auto',
    [string]$DefaultRemotePath = 'next-gpu-storage-app',
    [string]$RcloneIdleTimeout = '24h',
    [int]$DownloadMultiThreadStreams = 8,
    [switch]$NoMultiThreadDownload,
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

$script:GamesAppsManifestPath = Join-Path $PSScriptRoot 'GamesApps-Manifest.ps1'
if (-not (Test-Path -LiteralPath $script:GamesAppsManifestPath)) {
    throw @"
Required file missing: $script:GamesAppsManifestPath
Copy GamesApps-Manifest.ps1 from nextGPU-corescripts\scripts\maintenance\ into the same folder as Sync-GamesApps-Official.ps1.
"@
}
. $script:GamesAppsManifestPath

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

function Format-ProcessArgumentString {
    <#
        Build one command-line string for Start-Process. PS 5.1 splits string[] ArgumentList
        at spaces inside paths (e.g. C:\Program Files\...).
    #>
    param([Parameter(Mandatory)][string[]]$ArgumentTokens)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($token in @($ArgumentTokens)) {
        if ($null -eq $token) { continue }
        $t = [string]$token
        if ($t -match '[\s"]') {
            [void]$parts.Add('"' + ($t -replace '"', '\"') + '"')
        }
        else {
            [void]$parts.Add($t)
        }
    }
    return ($parts.ToArray() -join ' ')
}

# --- rclone progress (log tail + optional local file size; do not use --progress with --log-file) ---
$script:RcloneStatsInterval = '1s'

function Get-RcloneLogLineColor {
    param([string]$Line)
    if ($Line -match 'ERROR\s*:|Failed to') { return 'Yellow' }
    if ($Line -match 'WARN\s*:') { return 'Yellow' }
    return 'DarkGray'
}

function Write-RcloneProgressLines {
    param(
        [string]$LogPath,
        [ref]$LastReadPosition
    )
    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath)) { return }
    try {
        $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -le $LastReadPosition.Value) { return }
            $fs.Seek($LastReadPosition.Value, [System.IO.SeekOrigin]::Begin) | Out-Null
            $readLen = [int]($fs.Length - $LastReadPosition.Value)
            $buf = New-Object byte[] $readLen
            [void]$fs.Read($buf, 0, $readLen)
            $LastReadPosition.Value = $fs.Length
            $text = [System.Text.Encoding]::UTF8.GetString($buf)
            foreach ($line in @($text -split "`r?`n")) {
                $t = $line.Trim()
                if (-not $t) { continue }
                Write-Host "  [rclone] $t" -ForegroundColor (Get-RcloneLogLineColor -Line $t)
            }
        }
        finally {
            $fs.Dispose()
        }
    }
    catch {
        # Log may be locked briefly; skip this tick.
    }
}

function Get-LocalDownloadProgressBytes {
    param(
        [string]$ExpectedPath,
        [int64]$ExpectedBytes = 0
    )
    $best = [int64]0
    $label = ''
    if (-not [string]::IsNullOrWhiteSpace($ExpectedPath) -and (Test-Path -LiteralPath $ExpectedPath -PathType Leaf)) {
        $best = (Get-Item -LiteralPath $ExpectedPath).Length
        $label = [System.IO.Path]::GetFileName($ExpectedPath)
    }
    $dir = Split-Path -Parent $ExpectedPath
    $leaf = [System.IO.Path]::GetFileName($ExpectedPath)
    if ($dir -and $leaf -and (Test-Path -LiteralPath $dir)) {
        $partials = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like ($leaf + '.*.partial') })
        foreach ($p in $partials) {
            if ($p.Length -gt $best) {
                $best = [int64]$p.Length
                $label = $p.Name
            }
        }
    }
    return [pscustomobject]@{ Bytes = $best; DisplayName = $label }
}

function Write-LocalFileProgressLine {
    param(
        [string]$Path,
        [int64]$ExpectedBytes = 0,
        [string]$Label = 'file'
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $prog = Get-LocalDownloadProgressBytes -ExpectedPath $Path -ExpectedBytes $ExpectedBytes
    if ($prog.Bytes -gt 0) {
        if ($ExpectedBytes -gt 0) {
            $pct = [math]::Min(100, [math]::Round(100.0 * $prog.Bytes / $ExpectedBytes, 1))
            Write-Host ('  [{0}] {1} / {2} ({3}%) on disk' -f $Label, (Format-FileSize $prog.Bytes), (Format-FileSize $ExpectedBytes), $pct) -ForegroundColor Cyan
        }
        else {
            Write-Host ('  [{0}] {1} on disk' -f $Label, (Format-FileSize $prog.Bytes)) -ForegroundColor Cyan
        }
        if ($prog.DisplayName -like '*.partial') {
            $finalName = [System.IO.Path]::GetFileName($Path)
            Write-Host ('  (rclone partial: {0}; will become {1} when done)' -f $prog.DisplayName, $finalName) -ForegroundColor DarkGray
        }
        return
    }

    # On-disk size only; rclone log tail prints all transfer/stats lines every second.
}

function Repair-RclonePartialDownloadFile {
    param(
        [Parameter(Mandatory)][string]$ExpectedPath,
        [int64]$ExpectedBytes = 0
    )
    if (Test-Path -LiteralPath $ExpectedPath -PathType Leaf) {
        return $true
    }
    $dir = Split-Path -Parent $ExpectedPath
    $leaf = [System.IO.Path]::GetFileName($ExpectedPath)
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $false }

    $partials = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like ($leaf + '.*.partial') })
    if ($partials.Count -eq 0) { return $false }

    if (Get-Process -Name rclone -ErrorAction SilentlyContinue) {
        Write-Warn 'rclone still running - partial file not renamed yet. Wait or check log.'
        return $false
    }

    $best = $partials | Sort-Object -Property Length -Descending | Select-Object -First 1
    if ($ExpectedBytes -gt 0) {
        $delta = [math]::Abs($best.Length - $ExpectedBytes)
        if ($delta -gt 4096 -and $best.Length -lt ($ExpectedBytes - 4096)) {
            Write-Warn ("Partial {0} is {1}, expected ~{2}. Download may be incomplete." -f $best.Name, (Format-FileSize $best.Length), (Format-FileSize $ExpectedBytes))
            return $false
        }
    }

    if (Test-Path -LiteralPath $ExpectedPath) {
        Remove-Item -LiteralPath $ExpectedPath -Force -ErrorAction SilentlyContinue
    }
    Rename-Item -LiteralPath $best.FullName -NewName $leaf -Force
    Write-Ok "Finalized: $($best.Name) -> $leaf ($(Format-FileSize (Get-Item -LiteralPath $ExpectedPath).Length))"
    return $true
}

function Invoke-Rclone {
    param(
        [Parameter(Mandatory)][string]$Rclone,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$LogFile = '',
        [string]$LocalMonitorPath = '',
        [int64]$ExpectedBytes = 0,
        [switch]$Quiet
    )
    $argv = [string[]]@($ArgumentList)
    $logPath = ''
    if ($LogFile) {
        $logPath = [System.IO.Path]::GetFullPath($LogFile)
        $logDir = Split-Path -Parent $logPath
        if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        # INFO + stats-log-level INFO: --progress would suppress stats in the log file.
        $argv = $argv + [string[]]@(
            '--log-file', $logPath,
            '--log-level', 'INFO',
            '--stats-log-level', 'INFO',
            '--stats', $script:RcloneStatsInterval,
            '--stats-one-line'
        )
    }
    elseif (-not $Quiet) {
        $argv = $argv + [string[]]@('--stats', $script:RcloneStatsInterval, '--stats-one-line', '--progress')
    }

    if ($Quiet) {
        $null = & $Rclone @argv 2>&1 | Out-Null
        $exitCode = $LASTEXITCODE
        if ($null -eq $exitCode) { $exitCode = 1 }
        return [int]$exitCode
    }

    Write-Host ("  > rclone {0}" -f (Format-ProcessArgumentString -ArgumentTokens $argv)) -ForegroundColor DarkGray
    if ($logPath) {
        Write-Host ("  Stats every {0}; full rclone log echoed below. Log: {1}" -f $script:RcloneStatsInterval, $logPath) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("  Live progress every {0}." -f $script:RcloneStatsInterval) -ForegroundColor DarkGray
    }

    $monitorPath = ''
    if (-not [string]::IsNullOrWhiteSpace($LocalMonitorPath)) {
        $monitorPath = [System.IO.Path]::GetFullPath($LocalMonitorPath)
    }

    $logPos = 0L
    $argLine = Format-ProcessArgumentString -ArgumentTokens $argv
    $proc = Start-Process -FilePath $Rclone -ArgumentList $argLine -NoNewWindow -PassThru
    if (-not $proc) {
        throw "Failed to start rclone: $Rclone"
    }

    while (-not $proc.HasExited) {
        Write-RcloneProgressLines -LogPath $logPath -LastReadPosition ([ref]$logPos)
        if ($monitorPath) {
            Write-LocalFileProgressLine -Path $monitorPath -ExpectedBytes $ExpectedBytes -Label 'download'
        }
        Start-Sleep -Seconds 1
    }

    Write-RcloneProgressLines -LogPath $logPath -LastReadPosition ([ref]$logPos)
    if ($monitorPath) {
        Write-LocalFileProgressLine -Path $monitorPath -ExpectedBytes $ExpectedBytes -Label 'download'
    }

    $exitCode = $proc.ExitCode
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
    $argv = Join-RcloneArgs -Parts @($Args, @(Get-RcloneR2ExtraArgs -Purpose 'Listing'), @('--timeout', '2m', '--contimeout', '30s'))
    $text = & $Rclone @argv 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw ("rclone lsjson failed (exit $LASTEXITCODE):`n$text")
    }
    $rows = New-Object System.Collections.Generic.List[object]

    # Prefer full JSON parsing (lsjson usually returns a JSON array).
    $trimmed = $text.Trim()
    if ($trimmed) {
        try {
            $parsed = ConvertFrom-Json -InputObject $trimmed
            foreach ($item in @(ConvertTo-ObjectArray $parsed)) {
                if ($null -ne $item) { [void]$rows.Add($item) }
            }
        }
        catch {
            # Fallback for mixed output: parse JSON object lines and ignore commas between array items.
            foreach ($line in @($text -split "`r?`n")) {
                $t = $line.Trim().TrimEnd(',')
                if (-not $t -or -not $t.StartsWith('{') -or -not $t.EndsWith('}')) { continue }
                try { [void]$rows.Add((ConvertFrom-Json -InputObject $t)) } catch { }
            }
        }
    }
    return ,@(ConvertTo-ObjectArray $rows.ToArray())
}

function Get-RcloneR2ExtraArgs {
    param(
        [ValidateSet('Listing', 'Download', 'Upload')]
        [string]$Purpose = 'Listing'
    )
    # no_check_bucket is set in rclone.conf (Repair-RcloneR2RemoteConfig).
    # Do not use --s3-no-head / --s3-no-head-object on downloads: rclone may see 0 B and skip transfer.
    # Uploads: skip post-PUT HEAD (R2 can return misleading errors on large multi-part uploads).
    switch ($Purpose) {
        'Upload' { return @('--s3-no-head') }
        default { return @() }
    }
}

function Get-RcloneCopytoArgs {
    param(
        [int64]$SizeBytes = 0,
        [switch]$LocalDestination,
        [switch]$SingleThread
    )
    $r2Purpose = if ($LocalDestination) { 'Download' } else { 'Upload' }
    $a = @(
        @(Get-RcloneR2ExtraArgs -Purpose $r2Purpose),
        @(
            '--retries', '5',
            '--low-level-retries', '10',
            '--contimeout', '60s',
            '--timeout', $RcloneIdleTimeout
        )
    )
    if ($LocalDestination) {
        # Avoid Adobe.zip.<hash>.partial stuck when rename/checksum hangs after 100%.
        $a += @('--inplace', '--ignore-times')
        if ($SizeBytes -ge 1GB) {
            $a += @('--ignore-checksum')
        }
    }
    $mtStreams = [Math]::Max(1, [Math]::Min(32, $DownloadMultiThreadStreams))
    $useMultiThread = ($SizeBytes -ge 64MB) -and -not $SingleThread -and -not $NoMultiThreadDownload
    if ($useMultiThread) {
        $a += @(
            '--multi-thread-streams', [string]$mtStreams,
            '--multi-thread-cutoff', '64M',
            '--s3-chunk-size', '64M'
        )
    }
    elseif ($SizeBytes -ge 64MB) {
        $a += @('--s3-chunk-size', '64M')
        if ($SingleThread -or $NoMultiThreadDownload) {
            $a += @('--multi-thread-streams', '0')
        }
    }
    return ,[string[]](Join-RcloneArgs -Parts $a)
}

function Test-RcloneLogShowsMultiThreadObjectNotFound {
    param([Parameter(Mandatory)][string]$LogFile)
    if (-not (Test-Path -LiteralPath $LogFile)) { return $false }
    $tail = Get-Content -LiteralPath $LogFile -Tail 80 -ErrorAction SilentlyContinue
    if (-not $tail) { return $false }
    $pattern = 'failed to find object after copy|multi-thread copy:.*object not found'
    return [bool]($tail | Where-Object { $_ -match $pattern } | Select-Object -First 1)
}

function Test-RcloneLogShowsNothingToTransfer {
    param([Parameter(Mandatory)][string]$LogFile)
    if (-not (Test-Path -LiteralPath $LogFile)) { return $false }
    $tail = Get-Content -LiteralPath $LogFile -Tail 80 -ErrorAction SilentlyContinue
    if (-not $tail) { return $false }
    return [bool]($tail | Where-Object { $_ -match 'There was nothing to transfer' } | Select-Object -First 1)
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
        $v = Read-Host ('{0} (Y/N, Enter={1})' -f $Title, $defHint)
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
function Test-RcloneInstalled { return $null -ne (Get-RcloneExe) }
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
    $wingetPackages = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
    if (Test-Path -LiteralPath $wingetPackages) {
        $found = Get-ChildItem -LiteralPath $wingetPackages -Filter 'rclone.exe' -Recurse -Depth 5 -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($found) { return $found.FullName }
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

function Test-WingetPackageReady([string]$PackageId) {
    Update-SessionPath
    switch ($PackageId) {
        'Rclone.Rclone' { return $null -ne (Get-RcloneExe) }
        '7zip.7zip' { return $null -ne (Get-SevenZipExe) }
        default { return $false }
    }
}

function Ensure-WingetPackage([string]$PackageId, [string]$FriendlyName) {
    if (Test-WingetPackageReady -PackageId $PackageId) {
        Write-Ok "$FriendlyName already installed."
        return
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'winget is required. Install App Installer from the Microsoft Store.'
    }
    Write-Warn "Installing $FriendlyName..."
    & winget install --id $PackageId --exact --accept-package-agreements --accept-source-agreements --silent --disable-interactivity --source winget
    $wingetExit = $LASTEXITCODE
    if (Test-WingetPackageReady -PackageId $PackageId) {
        if ($wingetExit -ne 0) {
            Write-Warn "winget exited $wingetExit but $FriendlyName is available; continuing."
        }
        Write-Ok "$FriendlyName installed."
        return
    }
    throw "winget install failed for $PackageId (exit $wingetExit)"
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
    $roots = @(Get-PreferredFilesystemBrowseRoots)
    if ($roots.Count -gt 0) { return $roots[0] }
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
    $lsfArgv = Join-RcloneArgs -Parts @(
        @('lsf', $RemotePath, '--max-depth', '1', '--files-only'),
        @(Get-RcloneR2ExtraArgs -Purpose 'Listing'),
        @('--timeout', '60s')
    )
    $names = & $Rclone @lsfArgv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("Cannot reach or list $RemotePath. Check rclone config (R2 API endpoint, not CDN).`n$names")
    }
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

    # Prefer size (one object) over lsl; never lsl the whole bucket folder (slow with many keys).
    $sizeArgv = Join-RcloneArgs -Parts @(
        @('size', $RemoteZipPath, '--json'),
        @(Get-RcloneR2ExtraArgs -Purpose 'Listing'),
        @('--timeout', '30s')
    )
    $sizeOut = & $Rclone @sizeArgv 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        $trim = $sizeOut.Trim()
        if ($trim) {
            try {
                $j = ConvertFrom-Json -InputObject $trim
                if ($null -ne $j.bytes) { return [int64]$j.bytes }
            }
            catch {
                if ($trim -match '"bytes"\s*:\s*(\d+)') { return [int64]$Matches[1] }
            }
        }
    }

    $lslArgv = Join-RcloneArgs -Parts @(
        @('lsl', $RemoteZipPath),
        @(Get-RcloneR2ExtraArgs -Purpose 'Listing'),
        @('--timeout', '30s')
    )
    $out = & $Rclone @lslArgv 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in @($out -split "`r?`n")) {
            if ($line -match '^\s*(-?\d+)\s') { return [int64]$Matches[1] }
        }
    }
    return [int64]0
}

# --- UI ---
function Select-TargetDrive {
    $drives = @(Get-PSDrive -PSProvider FileSystem | Where-Object { -not $_.DisplayRoot } | Sort-Object Name)
    if ($drives.Count -eq 0) { throw 'No local drive found.' }

    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_SYNC_DRIVE)) {
        $preferred = $env:NEXTGPU_SYNC_DRIVE.Trim().TrimEnd(':').ToUpperInvariant()
        $match = $drives | Where-Object { $_.Name.ToUpperInvariant() -eq $preferred } | Select-Object -First 1
        if ($match) { return $match }
    }

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
    $defaultDrive = if ($env:NEXTGPU_SYNC_DRIVE) { $env:NEXTGPU_SYNC_DRIVE.Trim().TrimEnd(':') } else { '' }
    $pick = Prompt-Text 'Drive' ("$lines`n`nDrive letter") $defaultDrive
    $name = $pick.Trim().TrimEnd(':').ToUpperInvariant()
    $sel = $drives | Where-Object { $_.Name.ToUpperInvariant() -eq $name } | Select-Object -First 1
    if (-not $sel) { throw "Invalid drive: $pick" }
    return $sel
}

function Resolve-TargetFolder([string]$TargetBase) {
    $default = [System.IO.Path]::GetFullPath($TargetBase.Trim().TrimEnd('\'))
    if (-not (Test-Path -LiteralPath $default)) {
        New-Item -ItemType Directory -Path $default -Force | Out-Null
    }
    if (Prompt-YesNo 'Folder' "Install to selected drive?`n`n$default" $true) { return $default }
    if (-not $script:UseGui) {
        $v = Read-Host "Folder path (Enter = $default)"
        if ([string]::IsNullOrWhiteSpace($v)) { return $default }
        return [System.IO.Path]::GetFullPath($v.Trim().Trim('"'))
    }
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $default
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $dlg.SelectedPath) {
        return [System.IO.Path]::GetFullPath($dlg.SelectedPath)
    }
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
    $lbl.Text = ('Select .zip / .7z from R2 ({0} available):' -f $items.Count)
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
    $lbl.Text = ('Check .zip / .7z to upload ({0}, {1} found):' -f $SourceLabel, $items.Count)
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
function Get-ArchiveExtractFolderName {
    param([Parameter(Mandatory)][string]$ZipName)
    $base = [System.IO.Path]::GetFileNameWithoutExtension($ZipName.Trim())
    if ([string]::IsNullOrWhiteSpace($base)) {
        throw "Cannot determine extract folder name from: $ZipName"
    }
    return $base
}

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

function Repair-DuplicateRootExtractFolder {
    <#
        Archives like Adobe.zip often contain a top-level Adobe\ folder. We extract into
        LocalDir\Adobe\, which yields LocalDir\Adobe\Adobe\... — flatten one or more
        duplicate name levels (Adobe\Adobe\Adobe) when the only child matches the zip base name.
    #>
    param(
        [Parameter(Mandatory)][string]$ExtractDir,
        [Parameter(Mandatory)][string]$ExpectedFolderName
    )

    if (-not (Test-Path -LiteralPath $ExtractDir -PathType Container)) {
        return
    }

    $maxPasses = 8
    for ($pass = 0; $pass -lt $maxPasses; $pass++) {
        $children = @(Get-ChildItem -LiteralPath $ExtractDir -Force -ErrorAction SilentlyContinue)
        if ($children.Count -ne 1) {
            break
        }

        $only = $children[0]
        if (-not $only.PSIsContainer) {
            break
        }
        if ($only.Name -ine $ExpectedFolderName) {
            break
        }

        $nested = $only.FullName
        Write-Step "Flattening duplicate root folder: $($only.Name)\ -> $ExtractDir"
        foreach ($item in @(Get-ChildItem -LiteralPath $nested -Force)) {
            $dest = Join-Path $ExtractDir $item.Name
            if (Test-Path -LiteralPath $dest) {
                Write-Warn "Cannot flatten (already exists): $dest"
                return
            }
            Move-Item -LiteralPath $item.FullName -Destination $ExtractDir -Force
        }
        Remove-Item -LiteralPath $nested -Recurse -Force -ErrorAction Stop
    }
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
    if (Test-Path -LiteralPath $localZip -PathType Leaf) {
        $existingLen = (Get-Item -LiteralPath $localZip).Length
        if ($existingLen -ge 1KB) {
            Write-Warn ("Local file already exists ({0}): {1}" -f (Format-FileSize $existingLen), $localZip)
        }
        else {
            Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue
        }
    }

    if ($ListedSize -gt 0) {
        $size = $ListedSize
    }
    else {
        Write-Step "Checking remote $ZipName ..."
        if (-not (Test-RemoteArchiveExists -Rclone $Rclone -RemoteZipPath $RemoteZip)) {
            Write-Fail "Remote object not found: $RemoteZip"
            Write-Host '  Confirm the archive name in R2 matches the picker (case-sensitive key).' -ForegroundColor Yellow
            return 1
        }
        $size = Get-ArchiveSizeBytes -Rclone $Rclone -RemoteZipPath $RemoteZip -ListedSize 0
    }
    if ($size -le 0) {
        Write-Fail "Remote size is 0 or unknown for: $RemoteZip"
        Write-Host '  Re-upload the archive to R2, or check the bucket path in rclone config.' -ForegroundColor Yellow
        return 1
    }
    Write-Ok ("Remote size: {0}" -f (Format-FileSize $size))

    if (Test-LocalZipReady -Path $localZip -ExpectedBytes $size) {
        Write-Ok "Local archive already complete; skipping download."
    }
    else {
        if (Test-Path -LiteralPath $localZip -PathType Leaf) {
            Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem -LiteralPath $LocalDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like ($ZipName + '.*.partial') } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    Write-Step "Downloading $ZipName ..."
    if ($size -ge 64MB -and -not $NoMultiThreadDownload) {
        Write-Host ("  Multi-thread download ({0} streams, 64M chunks); single-thread retry if R2 errors." -f $DownloadMultiThreadStreams) -ForegroundColor DarkGray
    }
    elseif ($NoMultiThreadDownload) {
        Write-Host '  Single-stream download (-NoMultiThreadDownload).' -ForegroundColor DarkGray
    }
    else {
        Write-Host '  Single-stream download (archive under 64 MiB).' -ForegroundColor DarkGray
    }
    Write-Host '  First bytes on disk can take 1-2 min while rclone connects to R2.' -ForegroundColor DarkGray
    $copyArgs = Join-RcloneArgs -Parts @(
        @('copyto', $RemoteZip, $localRclone),
        @(Get-RcloneCopytoArgs -SizeBytes $size -LocalDestination)
    )
    $exitCode = Invoke-Rclone -Rclone $Rclone -ArgumentList $copyArgs -LogFile $LogFile `
        -LocalMonitorPath $localZip -ExpectedBytes $size
    $null = Repair-RclonePartialDownloadFile -ExpectedPath $localZip -ExpectedBytes $size
    if (-not (Test-LocalZipReady -Path $localZip -ExpectedBytes $size)) {
        if ($exitCode -eq 0) { $exitCode = 1 }
    }
    else {
        $exitCode = 0
    }
    if ($exitCode -ne 0 -and (Test-RcloneLogShowsMultiThreadObjectNotFound -LogFile $LogFile)) {
        Write-Warn 'R2 multi-thread verify failed; retrying download single-thread...'
        if (Test-Path -LiteralPath $localZip) {
            Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue
        }
        Get-ChildItem -LiteralPath $LocalDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like ($ZipName + '.*.partial') } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        $retryArgs = Join-RcloneArgs -Parts @(
            @('copyto', $RemoteZip, $localRclone),
            @(Get-RcloneCopytoArgs -SizeBytes $size -LocalDestination -SingleThread)
        )
        $exitCode = Invoke-Rclone -Rclone $Rclone -ArgumentList $retryArgs -LogFile $LogFile `
            -LocalMonitorPath $localZip -ExpectedBytes $size
        $null = Repair-RclonePartialDownloadFile -ExpectedPath $localZip -ExpectedBytes $size
        if (Test-LocalZipReady -Path $localZip -ExpectedBytes $size) { $exitCode = 0 }
    }
    if ($exitCode -ne 0) {
        Write-Warn "copyto failed (exit $exitCode); trying rclone copy into destination folder..."
        if (Test-Path -LiteralPath $localZip) {
            $partial = (Get-Item -LiteralPath $localZip).Length
            if ($size -gt 0 -and $partial -lt ($size - 4096)) {
                Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue
            }
        }
        Get-ChildItem -LiteralPath $LocalDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like ($ZipName + '.*.partial') } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        $localDirR = (To-RcloneLocalPath -Path $LocalDir).TrimEnd('/') + '/'
        $copyArgs2 = Join-RcloneArgs -Parts @(
            @('copy', $RemoteZip, $localDirR),
            @(Get-RcloneCopytoArgs -SizeBytes $size -LocalDestination -SingleThread)
        )
        $exitCode = Invoke-Rclone -Rclone $Rclone -ArgumentList $copyArgs2 -LogFile $LogFile `
            -LocalMonitorPath $localZip -ExpectedBytes $size
        $null = Repair-RclonePartialDownloadFile -ExpectedPath $localZip -ExpectedBytes $size
        if (Test-LocalZipReady -Path $localZip -ExpectedBytes $size) { $exitCode = 0 }
    }
    if ($exitCode -ne 0) {
        if (Test-Path -LiteralPath $localZip) { Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue }
        Write-Fail "rclone download failed (exit $exitCode). See log: $LogFile"
        if (Test-RcloneLogShowsNothingToTransfer -LogFile $LogFile) {
            Write-Host '  rclone logged "nothing to transfer" (remote missing, 0-byte object, or stale local file).' -ForegroundColor Yellow
        }
        return [int]$exitCode
    }
    if (-not (Test-Path -LiteralPath $localZip)) {
        Write-Fail "Download finished but file missing: $localZip"
        return 1
    }
    Write-Ok ("Downloaded {0}" -f (Format-FileSize (Get-Item -LiteralPath $localZip).Length))
    }

    $extractFolderName = Get-ArchiveExtractFolderName -ZipName $ZipName
    $extractDir = [System.IO.Path]::GetFullPath((Join-Path $LocalDir $extractFolderName))
    if (-not (Test-Path -LiteralPath $extractDir)) {
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
    }

    Write-Step "Extracting $ZipName -> $extractFolderName\ ..."
    try {
        Expand-Archive7z -SevenZip $SevenZip -ArchivePath $localZip -DestinationPath $extractDir
        Repair-DuplicateRootExtractFolder -ExtractDir $extractDir -ExpectedFolderName $extractFolderName
    }
    catch {
        Write-Fail $_.Exception.Message
        return 1
    }
    Write-Ok "Extracted to $extractDir"

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
    $errs = @(Get-Content -LiteralPath $LogFile -ErrorAction SilentlyContinue |
        Where-Object { $_ -match 'ERROR|Failed to|not found' } | Select-Object -Last 6)
    if ($errs.Count -gt 0) {
        Write-Host '  Log errors:' -ForegroundColor DarkRed
        $errs | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
    }
    Write-Host '  Log (last 20 lines):' -ForegroundColor DarkRed
    Get-Content -LiteralPath $LogFile -Tail 20 -ErrorAction SilentlyContinue | ForEach-Object {
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
    $argv = Join-RcloneArgs -Parts @(@('lsf', $RemoteZipPath, '--files-only'), @(Get-RcloneR2ExtraArgs -Purpose 'Listing'), @('--timeout', '15s'))
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
        $remoteSize = Get-ArchiveSizeBytes -Rclone $Rclone -RemoteZipPath $remoteZip -ListedSize $size
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
    Write-Host '  Script: 2026-06-03l (multi-thread R2 download + single-thread fallback)'
    Write-Host '==============================================='

    Ensure-WingetPackage -PackageId 'Rclone.Rclone' -FriendlyName 'rclone'
    Update-SessionPath

    $rclone = Get-RcloneExe
    if (-not $rclone) { throw 'rclone not found.' }
    Write-Ok "rclone: $rclone"

    $null = Ensure-RcloneConfig -Remote $RemoteName -StorageRegion $Region
    $remoteRoot = "${RemoteName}:$($DefaultRemotePath.Trim().TrimEnd('/'))"

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
        Write-Warn 'Large file(s) selected - confirmation will use this console (not a popup).'
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
Write-Host '  Script: 2026-06-03l (multi-thread R2 download + single-thread fallback)'
Write-Host '  Flow: lsjson list -> pick -> copyto -> 7z into <name> folder -> delete zip'
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
    $legacyManifest = Get-DownloadManifestFilePath
    $legacySteam = Find-SteamAppManifests -ExtractPath $targetFolder
    if ($legacySteam.IsSteamGame) { Write-SteamDetectToSyncLog -LogFile $logFile -ArchiveName '(legacy folder)' -ExtractPath $targetFolder -SteamInfo $legacySteam }
    $null = Update-DownloadManifest -ManifestPath $legacyManifest -RcloneLogFile $logFile `
        -Status 'Complete (legacy folder copy)' -Entries @(
        [pscustomobject]@{
            Name                 = '(entire remote folder)'
            RemotePath           = $remoteRoot
            ExtractPath          = $targetFolder
            SizeBytes            = [int64]0
            KeepZip              = $false
            IsSteamGame          = $legacySteam.IsSteamGame
            SteamManifestPaths   = $legacySteam.ManifestPaths
            SteamManifestNames   = $legacySteam.ManifestNames
            Type                 = (Resolve-DownloadEntryType -ArchiveName '(entire remote folder)' -HasSteamManifest:$legacySteam.IsSteamGame)
        }
    )
    Write-Ok "Legacy copy done -> $targetFolder"
    if ($legacyManifest) { Write-Ok "Download manifest: $legacyManifest" }
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

$configuredSyncTarget = Get-ConfiguredSyncTargetPath
if ($configuredSyncTarget) {
    Write-Ok ("Install target from NEXTGPU_SYNC_TARGET: $configuredSyncTarget")
    $targetFolder = $configuredSyncTarget
}
else {
    $drive = Select-TargetDrive
    Write-Ok ("Drive {0}: {1} GB free" -f $drive.Name, (Format-GB $drive.Free))
    $targetFolder = Resolve-TargetFolder -TargetBase "$($drive.Name):\"
}

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
$failedArchive = ''
$downloaded = New-Object System.Collections.Generic.List[object]
$manifestPath = Get-DownloadManifestFilePath
$written = $null
$knownExtracts = @(Get-DownloadManifestExtractPaths -ManifestPath $manifestPath)
if ((Get-ObjectCount $knownExtracts) -gt 0) {
    Write-Ok ("Reusing manifest ({0} prior extract(s) on record): {1}" -f (Get-ObjectCount $knownExtracts), $manifestPath)
}
else {
    Write-Ok ("Download manifest: {0}" -f $manifestPath)
}

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
        $failedArchive = $name
        break
    }
    $extractRoot = Join-Path $targetFolder ([System.IO.Path]::GetFileNameWithoutExtension($name))
    Write-Host '  Scanning extract folder for Steam appmanifest...' -ForegroundColor DarkGray
    $steamInfo = Find-SteamAppManifests -ExtractPath $extractRoot
    $entryType = Resolve-DownloadEntryType -ArchiveName $name -ExtractPath $extractRoot -HasSteamManifest:$steamInfo.IsSteamGame
    if ($entryType -eq 'Steam app') {
        if (-not (Test-IsSteamClientPath -Path $extractRoot)) {
            $nestedClient = Find-SteamClientPathUnderDirectory -Root $extractRoot
            if ($nestedClient) {
                $extractRoot = $nestedClient
                Write-Ok ("Steam client detected (nested): $extractRoot")
            }
            else {
                Write-Ok 'Steam app (Steam client archive; verify steam.exe after extract).'
            }
        }
        else {
            Write-Ok 'Steam app (Steam client detected).'
        }
    }
    elseif ($steamInfo.IsSteamGame) {
        Write-Ok ("Steam game (appmanifest found): {0}" -f (($steamInfo.ManifestNames | Select-Object -First 3) -join ', '))
        Write-SteamDetectToSyncLog -LogFile $logFile -ArchiveName $name -ExtractPath $extractRoot -SteamInfo $steamInfo
    }
    else {
        Write-Host '  No appmanifest*.txt/.acf found (generic app).' -ForegroundColor DarkGray
    }
    [void]$downloaded.Add([pscustomobject]@{
        Name               = $name
        RemotePath         = "$remoteRoot/$name"
        ExtractPath        = $extractRoot
        SizeBytes          = $listed
        KeepZip            = $KeepZip.IsPresent
        IsSteamGame        = $steamInfo.IsSteamGame
        SteamManifestPaths = $steamInfo.ManifestPaths
        SteamManifestNames = $steamInfo.ManifestNames
        Type               = $entryType
    })
}

$manifestStatus = if ($exitCode -eq 0) { 'Complete' } else { 'Incomplete' }
if ((Get-ObjectCount $downloaded) -gt 0) {
    $written = Update-DownloadManifest -ManifestPath $manifestPath -RcloneLogFile $logFile `
        -Entries @(ConvertTo-ObjectArray $downloaded.ToArray()) `
        -Status $manifestStatus -FailedArchive $failedArchive
    if ($written) { Write-Ok "Manifest updated (appended session): $written" }
}

Write-Host ''
if ($exitCode -eq 0) {
    Write-Ok 'All releases installed.'
    Write-Host "Output: $targetFolder" -ForegroundColor Green
    if ($script:UseGui) {
        $guiMsg = "Done.`n$targetFolder`n`nLog: $logFile"
        if ($written) { $guiMsg += "`n`nManifest: $written" }
        [void][System.Windows.Forms.MessageBox]::Show($guiMsg, 'NextGPU Sync', 'OK', 'Information')
    }
    exit 0
}

Write-Fail "Stopped with error (exit $exitCode)."
if ($script:UseGui) {
    $guiMsg = "Failed.`nLog: $logFile"
    if ($written) { $guiMsg += "`n`nManifest (completed before failure): $written" }
    [void][System.Windows.Forms.MessageBox]::Show($guiMsg, 'NextGPU Sync', 'OK', 'Error')
}
exit $exitCode
