#Requires -Version 5.1
<#
.SYNOPSIS
    Shared Sunshine + Moonlight install/update/pairing used by checking-update and auto-repair.
.PARAMETER SunshineMode
    CheckUpdate: reinstall only when remote VERSION:... differs from local sunshine-version.txt.
    ForceReinstall: always reinstall Sunshine.
    Skip: do not touch Sunshine.
.PARAMETER MoonlightMode
    CheckUpdate: reinstall only when remote VERSION:... differs from moonlight-web\VERSION.txt.
    ForceReinstall: always reinstall Moonlight Web service.
    Skip: do not touch Moonlight.
.PARAMETER ForcePairing
    Always run Moonlight <-> Sunshine pairing at the end (auto-repair).
.PARAMETER SkipPairing
    Never pair, even after updates.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '',
    [string]$ComputerName = '',
    [ValidateSet('CheckUpdate', 'ForceReinstall', 'Skip')]
    [string]$SunshineMode = 'CheckUpdate',
    [ValidateSet('CheckUpdate', 'ForceReinstall', 'Skip')]
    [string]$MoonlightMode = 'CheckUpdate',
    [switch]$ForcePairing,
    [switch]$SkipPairing
)

$ErrorActionPreference = 'Stop'

$script:SunshineVersionUrl = 'https://raw.githubusercontent.com/bluefml1/nextGPU-sunshine/my-changes/VERSION'
$script:SunshineZipUrl = 'https://github.com/bluefml1/nextGPU-sunshine/releases/latest/download/sunshine.zip'
$script:MoonlightVersionUrl = 'https://raw.githubusercontent.com/bluefml1/nextGPU-moonlight/main/VERSION.txt'
$script:MoonlightZipUrl = 'https://github.com/bluefml1/nextGPU-moonlight/releases/latest/download/moonlight-theme.zip'
$script:MoonlightConfigUrl = 'https://github.com/Nguyenanvu202/bongsenvang-config/raw/refs/heads/main/config.json'
$script:MoonlightDataUrl = 'https://github.com/Nguyenanvu202/bongsenvang-data/raw/refs/heads/main/data.json'
$script:MoonlightService = 'moonlight-web'
$script:SunshineService = 'gpu-sunshine'
$script:PairingLogPath = $null

function Write-StackLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    switch ($Level) {
        'WARN' { Write-Host $Message -ForegroundColor Yellow }
        'ERROR' { Write-Host $Message -ForegroundColor Red }
        default { Write-Host $Message }
    }
}

function Initialize-PairingLog {
    param([string]$RepoRootPath)
    $logDir = Join-Path $RepoRootPath 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $script:PairingLogPath = Join-Path $logDir 'moonlight-pairing.log'
    Write-PairingLog '=== Moonlight pairing log session ==='
}

function Write-PairingLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    Write-StackLog -Message $Message -Level $Level
    if (-not $script:PairingLogPath) { return }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    for ($retry = 0; $retry -lt 5; $retry++) {
        try {
            $stream = [System.IO.File]::Open(
                $script:PairingLogPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite)
            try {
                $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding $false))
                $writer.WriteLine($line)
                $writer.Flush()
            }
            finally {
                if ($writer) { $writer.Dispose() }
                $stream.Dispose()
            }
            return
        }
        catch {
            if ($retry -ge 4) {
                Write-StackLog "Pairing log write failed: $($_.Exception.Message)" 'WARN'
            }
            else {
                Start-Sleep -Milliseconds (50 * ($retry + 1))
            }
        }
    }
}

function Test-TcpPortOpen {
    param(
        [string]$HostName = '127.0.0.1',
        [int]$Port = 8080,
        [int]$TimeoutMs = 2000
    )
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect($HostName, $Port, $null, $null)
        if ($async.AsyncWaitHandle.WaitOne($TimeoutMs) -and $tcp.Connected) {
            $tcp.Close()
            return $true
        }
        $tcp.Close()
    }
    catch { }
    return $false
}

function Get-PinResponseFileStatus {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return 'missing'
    }
    $item = Get-Item -LiteralPath $Path
    if ($item.Length -eq 0) {
        return 'empty'
    }
    $preview = (Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue).Trim()
    if ($preview.Length -gt 120) { $preview = $preview.Substring(0, 120) + '...' }
    return "size=$($item.Length) text=$preview"
}

function Write-PairingEnvironmentDiagnostics {
    param(
        [string]$DataPath,
        [string]$CookieJar,
        [string]$PinFile
    )
    Write-PairingLog "Context USERNAME=$env:USERNAME USERDOMAIN=$env:USERDOMAIN TEMP=$env:TEMP COMPUTERNAME=$env:COMPUTERNAME"
    $sunshineProc = @(Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue).Count
    $mlSvc = Get-Service -Name $script:MoonlightService -ErrorAction SilentlyContinue
    $mlState = if ($mlSvc) { $mlSvc.Status.ToString() } else { 'missing' }
    Write-PairingLog "Processes sunshine=$sunshineProc curl=$(@(Get-Process -Name 'curl' -ErrorAction SilentlyContinue).Count) service:$($script:MoonlightService)=$mlState"
    Write-PairingLog "Ports open 8080=$(Test-TcpPortOpen -Port 8080) 47989=$(Test-TcpPortOpen -Port 47989) 47990=$(Test-TcpPortOpen -Port 47990)"
    Write-PairingLog "Paths cookies=$CookieJar pinOut=$PinFile dataJson=$DataPath"
    if (Test-Path -LiteralPath $DataPath) {
        try {
            $data = Get-Content -Raw -LiteralPath $DataPath | ConvertFrom-Json
            $host0 = $data.hosts.'0'
            if ($host0) {
                Write-PairingLog "data.json host[0] address=$($host0.address) http_port=$($host0.http_port) pair_info=$($host0.pair_info)"
            }
        }
        catch {
            Write-PairingLog "data.json parse failed: $($_.Exception.Message)" 'WARN'
        }
    }
    else {
        Write-PairingLog "data.json missing at $DataPath" 'WARN'
    }
}

function Invoke-CurlNative {
    <#
    .SYNOPSIS
        Run curl.exe without PowerShell treating stderr progress as a terminating error.
    .PARAMETER CurlArgs
        curl.exe argument list. Pass as an array so flags like -o/-H are not parsed as PowerShell parameters.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$CurlArgs,
        [switch]$CaptureOutput
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($CaptureOutput) {
            $out = & curl.exe @CurlArgs 2>$null
            return @{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        & curl.exe @CurlArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Stop-CurlProcessesQuietly {
    Get-Process -Name 'curl' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Get-MoonlightPairPinFromFile {
    param(
        [string]$Path,
        [ref]$ParseNote
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($ParseNote) { $ParseNote.Value = 'file missing' }
        return $null
    }
    $raw = $null
    try {
        $raw = Get-Content -Raw -LiteralPath $Path
        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($ParseNote) { $ParseNote.Value = 'file empty' }
            return $null
        }
        $json = $raw | ConvertFrom-Json
        if ($null -ne $json.Pin -and "$($json.Pin)" -ne '') {
            if ($ParseNote) { $ParseNote.Value = 'Pin field found' }
            return [string]$json.Pin
        }
        if ($null -ne $json.pin -and "$($json.pin)" -ne '') {
            if ($ParseNote) { $ParseNote.Value = 'pin field found' }
            return [string]$json.pin
        }
        if ($ParseNote) { $ParseNote.Value = "JSON ok but no Pin field: $raw" }
    }
    catch {
        if ($ParseNote) { $ParseNote.Value = "JSON parse error: $($_.Exception.Message); raw=$raw" }
    }
    return $null
}

function Write-MoonlightJsonBodyFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$JsonContent
    )
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, $JsonContent, $enc)
}

function Write-MoonlightLoginBodyFile {
    param([string]$Path)
    Write-MoonlightJsonBodyFile -Path $Path -JsonContent '{"name":"test","password":"test123"}'
}

function Start-MoonlightPairPoll {
    <#
    .SYNOPSIS
        Start Moonlight /api/pair long-poll in a child PowerShell process.
        Start-Process curl.exe mangles --data-binary @file on Windows (Moonlight returns "Content type error");
        & curl.exe in a child PS matches Invoke-CurlNative / manual CMD pairing.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$CookieJar,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$HostId = 0
    )
    $pairBodyFile = Join-Path $env:TEMP 'moonlight_pair_body.json'
    $pairJson = "{`"host_id`":$HostId}"
    Write-MoonlightJsonBodyFile -Path $pairBodyFile -JsonContent $pairJson

    $wrapperScript = Join-Path $env:TEMP 'moonlight_pair_poll.ps1'
    $escapedCookieJar = $CookieJar -replace "'", "''"
    $escapedOutFile = $OutFile -replace "'", "''"
    $escapedPairBodyFile = $pairBodyFile -replace "'", "''"
    $wrapperContent = @"
`$ErrorActionPreference = 'Continue'
& curl.exe -N -b '$escapedCookieJar' -X POST 'http://127.0.0.1:8080/api/pair' -H 'Content-Type: application/json' --data-binary '@$escapedPairBodyFile' -o '$escapedOutFile' -s
exit `$LASTEXITCODE
"@
    $enc = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($wrapperScript, $wrapperContent, $enc)

    $manualCmd = 'start /b cmd /c "curl.exe -N -b "' + $CookieJar + '" -X POST "http://127.0.0.1:8080/api/pair" -H "Content-Type: application/json" -d \"{\"host_id\":' + $HostId + '}\" -o "' + $OutFile + '" -s"'
    Write-PairingLog 'Manual-equivalent CMD (RegisterMachine_Beta.bat):'
    Write-PairingLog $manualCmd
    Write-PairingLog "Pair poll wrapper: $wrapperScript"
    Write-PairingLog "Pair body file: $pairBodyFile content=$pairJson"

    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden', '-File', $wrapperScript
    ) -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500
    if ($proc.HasExited) {
        Write-PairingLog "Pair poll wrapper exited immediately code=$($proc.ExitCode) pinFile=$(Get-PinResponseFileStatus -Path $OutFile)" 'WARN'
    }
    else {
        Write-PairingLog "Pair poll running wrapper PID=$($proc.Id)"
    }
    return $proc
}

function Test-MoonlightSessionCookie {
    param([string]$CookieJarPath)
    if (-not (Test-Path -LiteralPath $CookieJarPath)) { return $false }
    $raw = Get-Content -Raw -LiteralPath $CookieJarPath -ErrorAction SilentlyContinue
    return ($raw -and $raw -match 'mlSession')
}

function Resolve-RepoRootPath {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override.TrimEnd('\') }
    if ($env:NEXTGPU_REPO_ROOT) { return $env:NEXTGPU_REPO_ROOT.TrimEnd('\') }
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Test-HttpErrorBody {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $t = $Text.Trim()
    return ($t -match '(?i)^(429|403|404|502|503)\b|Too Many Requests|rate.?limit|Not Found|Access Denied|^<(!DOCTYPE|html)')
}

function Get-FilePreview {
    param(
        [string]$Path,
        [int]$MaxChars = 80
    )
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $raw = (Get-Content -Raw -LiteralPath $Path -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    $t = $raw.Trim()
    if ($t.Length -le $MaxChars) { return $t }
    return $t.Substring(0, $MaxChars) + '...'
}

function Assert-DownloadedJsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (-not (Test-Path -LiteralPath $Path) -or (Get-Item -LiteralPath $Path).Length -lt 2) {
        throw "$Label is missing or empty: $Path"
    }
    $raw = Get-Content -Raw -LiteralPath $Path
    $preview = Get-FilePreview -Path $Path
    if (Test-HttpErrorBody -Text $raw) {
        throw "$Label download is not JSON (HTTP/rate-limit page). Close extra GitHub downloads and retry later. Preview: $preview"
    }
    try {
        $null = $raw | ConvertFrom-Json
    }
    catch {
        throw "$Label is not valid JSON: $($_.Exception.Message). Preview: $preview"
    }
}

function Invoke-DownloadFile {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $destDir = Split-Path $Destination -Parent
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        $dlExit = Invoke-CurlNative @(
            '-L', '--fail', '--retry', '3', '--retry-delay', '2',
            '--max-time', '90', '-o', $Destination, '--progress-bar', $Url
        )
        if ($dlExit -eq 0 -and (Test-Path -LiteralPath $Destination) -and (Get-Item -LiteralPath $Destination).Length -gt 0) {
            if (Test-HttpErrorBody -Text (Get-FilePreview -Path $Destination -MaxChars 200)) {
                throw "Download from $Url returned an HTTP error page. GitHub may be rate-limiting (429). Retry later."
            }
            return
        }
        if ($dlExit -eq 22) {
            throw "Download failed HTTP error for $Url (curl --fail). GitHub may be rate-limiting (429). Retry later."
        }
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
    }
    catch {
        throw "Download failed for $Url : $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $Destination) -or (Get-Item -LiteralPath $Destination).Length -eq 0) {
        throw "Download produced an empty file for $Url"
    }
    if (Test-HttpErrorBody -Text (Get-FilePreview -Path $Destination -MaxChars 200)) {
        throw "Download from $Url returned an HTTP error page. GitHub may be rate-limiting (429). Retry later."
    }
}

function Get-RemoteTextLine {
    param([string]$Url)
    $temp = Join-Path $env:TEMP ("nextgpu_remote_{0}.txt" -f [Guid]::NewGuid().ToString('N'))
    try {
        Invoke-DownloadFile -Url $Url -Destination $temp
        $line = (Get-Content -LiteralPath $temp -TotalCount 1 -ErrorAction Stop | Select-Object -First 1)
        if ($null -eq $line) { return $null }
        return $line.Trim()
    }
    catch {
        Write-StackLog "Remote version fetch failed ($Url): $($_.Exception.Message)" 'WARN'
        return $null
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Test-VersionLineValid {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    $t = $Line.Trim()
    # Canonical remote/local stamp is VERSION:<value> (e.g. VERSION:Beta3.4).
    # HTTP errors like "429: Too Many Requests" must not trigger an update.
    if ($t.Length -gt 80) { return $false }
    if (Test-HttpErrorBody -Text $t) { return $false }
    return ($t -match '^VERSION:\S')
}

function Stop-SunshineProcessesAndService {
    $svc = Get-Service -Name $script:SunshineService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service -Name $script:SunshineService -Force -ErrorAction SilentlyContinue
    }
    Get-Process -Name 'Sunshine' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Remove-InstalledSunshine {
    Stop-SunshineProcessesAndService
    $uninstaller = 'C:\Program Files\Sunshine\uninstall.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait -WindowStyle Hidden
        for ($i = 0; $i -lt 30; $i++) {
            if (-not (Test-Path -LiteralPath $uninstaller)) { break }
            Start-Sleep -Seconds 1
        }
    }
    $installDir = 'C:\Program Files\Sunshine'
    if (Test-Path -LiteralPath $installDir) {
        Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $installDir) {
            throw "Failed to remove $installDir"
        }
    }
}

function Start-InstalledSunshine {
    param([string]$RepoRootPath)
    $sunshineExe = 'C:\Program Files\Sunshine\sunshine.exe'
    if (-not (Test-Path -LiteralPath $sunshineExe)) {
        throw "Sunshine executable not found: $sunshineExe"
    }
    Write-StackLog '[*] Setting Sunshine API credentials (RegisterMachine order: --creds, stop, start)...'
    & $sunshineExe --creds bluefml1 letmeinpls 2>&1 | Out-Null
    $credsPath = 'C:\Program Files\Sunshine\config\credentials'
    if (Test-Path -LiteralPath $credsPath) {
        Write-StackLog '[*] Sunshine config\credentials created.'
    }
    else {
        Write-StackLog '[WARN] Sunshine config\credentials missing after --creds; Web UI onboarding may block /api/pin and /api/restart.' 'WARN'
    }
    Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $sessionPs1 = Join-Path $RepoRootPath 'scripts\provisioning\Start-Sunshine-InSession.ps1'
    if (Test-Path -LiteralPath $sessionPs1) {
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $sessionPs1 -Quiet | Out-Null
    }
    else {
        Start-Process -FilePath $sunshineExe | Out-Null
    }
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name 'sunshine' -ErrorAction SilentlyContinue)) {
        throw 'Sunshine failed to start after install.'
    }
}

function Invoke-SunshineReinstall {
    param(
        [string]$RepoRootPath,
        [string]$RemoteVersion
    )
    $sunshineDir = Join-Path $RepoRootPath 'sunshine'
    $sunshineZip = Join-Path $RepoRootPath 'sunshine.zip'

    Write-StackLog '=== Sunshine reinstall ==='
    Remove-InstalledSunshine

    if (Test-Path -LiteralPath $sunshineDir) {
        Remove-Item -LiteralPath $sunshineDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $sunshineZip) {
        Remove-Item -LiteralPath $sunshineZip -Force -ErrorAction SilentlyContinue
    }

    Write-StackLog '[*] Downloading Sunshine...'
    Invoke-DownloadFile -Url $script:SunshineZipUrl -Destination $sunshineZip
    New-Item -ItemType Directory -Path $sunshineDir -Force | Out-Null
    Expand-Archive -Path $sunshineZip -DestinationPath $sunshineDir -Force
    $installer = Join-Path $sunshineDir 'Sunshine.exe'
    if (-not (Test-Path -LiteralPath $installer)) {
        throw 'Sunshine.exe missing after extract.'
    }
    Remove-Item -LiteralPath $sunshineZip -Force -ErrorAction SilentlyContinue

    Write-StackLog '[*] Installing Sunshine...'
    Start-Process -FilePath $installer -ArgumentList '/S' -Wait -WindowStyle Hidden
    Start-Sleep -Seconds 5
    if (-not (Test-Path -LiteralPath 'C:\Program Files\Sunshine\sunshine.exe')) {
        throw 'Sunshine did not install to Program Files.'
    }

    Start-InstalledSunshine -RepoRootPath $RepoRootPath

    $postSetup = Join-Path $RepoRootPath 'scripts\provisioning\Invoke-PostSunshineSetup.ps1'
    if (-not (Test-Path -LiteralPath $postSetup)) {
        throw "Invoke-PostSunshineSetup.ps1 not found: $postSetup"
    }
    Write-StackLog '[*] Running post-Sunshine setup...'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $postSetup
    if ($LASTEXITCODE -ne 0) { throw "Invoke-PostSunshineSetup.ps1 failed with exit code $LASTEXITCODE" }

    if (-not [string]::IsNullOrWhiteSpace($RemoteVersion)) {
        Set-Content -LiteralPath (Join-Path $sunshineDir 'sunshine-version.txt') -Value $RemoteVersion -Encoding ascii
        Write-StackLog "[*] Sunshine updated to: $RemoteVersion"
    }
}

function Test-SunshineUpdateNeeded {
    param(
        [string]$RepoRootPath,
        [string]$Mode
    )
    if ($Mode -eq 'Skip') { return @{ Needed = $false; Remote = $null } }
    if ($Mode -eq 'ForceReinstall') {
        try {
            $remote = Get-RemoteTextLine -Url $script:SunshineVersionUrl
            if (-not (Test-VersionLineValid -Line $remote)) { $remote = $null }
        }
        catch { $remote = $null }
        return @{ Needed = $true; Remote = $remote }
    }

    $remote = Get-RemoteTextLine -Url $script:SunshineVersionUrl
    if (-not (Test-VersionLineValid -Line $remote)) {
        $shown = if ([string]::IsNullOrWhiteSpace($remote)) { '(empty)' } else { $remote }
        Write-StackLog "Remote Sunshine version is not VERSION:... ($shown); skipping until next checking-update." 'WARN'
        return @{ Needed = $false; Remote = $null }
    }

    $localFile = Join-Path $RepoRootPath 'sunshine\sunshine-version.txt'
    if (-not (Test-Path -LiteralPath $localFile)) {
        Write-StackLog 'No local sunshine-version.txt; skipping Sunshine update (first install uses RegisterMachine).' 'WARN'
        return @{ Needed = $false; Remote = $remote }
    }

    $local = (Get-Content -LiteralPath $localFile -TotalCount 1 | Select-Object -First 1).Trim()
    Write-StackLog "Remote Sunshine version: $remote"
    Write-StackLog "Local Sunshine version: $local"
    return @{ Needed = ($local -ne $remote); Remote = $remote }
}

function Set-MoonlightConfigJson {
    param(
        [string]$MoonlightDir,
        [string]$MachineName
    )
    $configPath = Join-Path $MoonlightDir 'server\config.json'
    $serverDir = Split-Path $configPath -Parent
    if (-not (Test-Path -LiteralPath $serverDir)) {
        New-Item -ItemType Directory -Path $serverDir -Force | Out-Null
    }
    if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
    }

    Write-StackLog '[*] Downloading Moonlight config.json...'
    Invoke-DownloadFile -Url $script:MoonlightConfigUrl -Destination $configPath

    if (-not [string]::IsNullOrWhiteSpace($MachineName)) {
        $normalized = $MachineName.Trim().ToLowerInvariant()
        $content = [System.IO.File]::ReadAllText($configPath)
        if ($content -match '\{\{computer_name\}\}') {
            $content = $content -replace '\{\{computer_name\}\}', $normalized
            [System.IO.File]::WriteAllText($configPath, $content, [Text.UTF8Encoding]::new($false))
            Write-StackLog "[+] config.json substitution: computer_name=$normalized"
        }
    }

    if ([System.IO.File]::ReadAllText($configPath) -match '\{\{computer_name\}\}') {
        throw 'config.json still contains {{computer_name}} placeholder.'
    }
    Assert-DownloadedJsonFile -Path $configPath -Label 'Moonlight config.json'
}

function Install-MoonlightService {
    param(
        [string]$RepoRootPath,
        [string]$MoonlightDir,
        [string]$MachineName,
        [string]$RemoteVersion
    )
    $nssm = Join-Path $RepoRootPath 'nssm\nssm-2.24\win64\nssm.exe'
    if (-not (Test-Path -LiteralPath $nssm)) {
        throw "NSSM not found: $nssm"
    }
    $logDir = Join-Path $RepoRootPath 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $svc = Get-Service -Name $script:MoonlightService -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq 'Running') { Stop-Service -Name $script:MoonlightService -Force -ErrorAction SilentlyContinue }
        & $nssm remove $script:MoonlightService confirm | Out-Null
        Start-Sleep -Seconds 2
    }

    Set-MoonlightConfigJson -MoonlightDir $MoonlightDir -MachineName $MachineName

    $webServer = Join-Path $MoonlightDir 'web-server.exe'
    if (-not (Test-Path -LiteralPath $webServer)) {
        throw "web-server.exe not found: $webServer"
    }

    & $nssm install $script:MoonlightService $webServer
    if ($LASTEXITCODE -ne 0) { throw 'NSSM install failed for Moonlight service.' }
    & $nssm set $script:MoonlightService AppDirectory $MoonlightDir | Out-Null
    & $nssm set $script:MoonlightService Start SERVICE_AUTO_START | Out-Null
    & $nssm set $script:MoonlightService AppStdout (Join-Path $logDir 'moonlight-web.log') | Out-Null
    & $nssm set $script:MoonlightService AppStderr (Join-Path $logDir 'moonlight-web-error.log') | Out-Null
    & $nssm set $script:MoonlightService DisplayName 'Moonlight Web Stream' | Out-Null
    & $nssm set $script:MoonlightService Description 'Moonlight Web streaming server for remote GPU access' | Out-Null
    Start-Service -Name $script:MoonlightService -ErrorAction Stop
    Start-Sleep -Seconds 3

    if (-not [string]::IsNullOrWhiteSpace($RemoteVersion)) {
        Set-Content -LiteralPath (Join-Path $MoonlightDir 'VERSION.txt') -Value $RemoteVersion -Encoding ascii
        Write-StackLog "[*] Moonlight updated to: $RemoteVersion"
    }
}

function Expand-MoonlightThemeZip {
    param(
        [string]$ZipPath,
        [string]$DestinationDir
    )
    $extractTo = Join-Path $env:TEMP ("moonlight_extract_{0}" -f [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $extractTo -Force | Out-Null
    try {
        tar -xf $ZipPath -C $extractTo
        if ($LASTEXITCODE -ne 0) { throw 'tar extract failed.' }

        if (Test-Path -LiteralPath (Join-Path $extractTo 'moonlight-web')) {
            Copy-Item -Path (Join-Path $extractTo 'moonlight-web\*') -Destination $DestinationDir -Recurse -Force
            return
        }
        if (Test-Path -LiteralPath (Join-Path $extractTo 'static')) {
            Copy-Item -Path (Join-Path $extractTo '*') -Destination $DestinationDir -Recurse -Force
            return
        }
        foreach ($dir in Get-ChildItem -LiteralPath $extractTo -Directory) {
            if (Test-Path -LiteralPath (Join-Path $dir.FullName 'static')) {
                Copy-Item -Path (Join-Path $dir.FullName '*') -Destination $DestinationDir -Recurse -Force
                return
            }
        }
        throw 'Could not locate moonlight-web folder in ZIP.'
    }
    finally {
        Remove-Item -LiteralPath $extractTo -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-MoonlightReinstall {
    param(
        [string]$RepoRootPath,
        [string]$MachineName,
        [string]$RemoteVersion
    )
    $moonlightDir = Join-Path $RepoRootPath 'moonlight-web'
    $moonlightZip = Join-Path $RepoRootPath 'moonlight-theme.zip'

    Write-StackLog '=== Moonlight reinstall ==='

    $svc = Get-Service -Name $script:MoonlightService -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Stop-Service -Name $script:MoonlightService -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path -LiteralPath $moonlightDir) {
        Remove-Item -LiteralPath $moonlightDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $moonlightDir -Force | Out-Null

    Write-StackLog '[*] Downloading Moonlight Web...'
    Invoke-DownloadFile -Url $script:MoonlightZipUrl -Destination $moonlightZip
    Expand-MoonlightThemeZip -ZipPath $moonlightZip -DestinationDir $moonlightDir
    Remove-Item -LiteralPath $moonlightZip -Force -ErrorAction SilentlyContinue

    Install-MoonlightService -RepoRootPath $RepoRootPath -MoonlightDir $moonlightDir -MachineName $MachineName -RemoteVersion $RemoteVersion
    Write-StackLog '[*] Moonlight reinstalled and service started.'
}

function Test-MoonlightUpdateNeeded {
    param(
        [string]$RepoRootPath,
        [string]$Mode
    )
    if ($Mode -eq 'Skip') { return @{ Needed = $false; Remote = $null } }
    if ($Mode -eq 'ForceReinstall') {
        try {
            $remote = Get-RemoteTextLine -Url $script:MoonlightVersionUrl
            if (-not (Test-VersionLineValid -Line $remote)) { $remote = $null }
        }
        catch { $remote = $null }
        return @{ Needed = $true; Remote = $remote }
    }

    $remote = Get-RemoteTextLine -Url $script:MoonlightVersionUrl
    if (-not (Test-VersionLineValid -Line $remote)) {
        $shown = if ([string]::IsNullOrWhiteSpace($remote)) { '(empty)' } else { $remote }
        Write-StackLog "Remote Moonlight version is not VERSION:... ($shown); skipping until next checking-update." 'WARN'
        return @{ Needed = $false; Remote = $null }
    }

    $localFile = Join-Path $RepoRootPath 'moonlight-web\VERSION.txt'
    if (-not (Test-Path -LiteralPath $localFile)) {
        Write-StackLog 'No local Moonlight VERSION.txt; skipping Moonlight update.' 'WARN'
        return @{ Needed = $false; Remote = $remote }
    }

    $local = (Get-Content -LiteralPath $localFile -TotalCount 1 | Select-Object -First 1).Trim()
    Write-StackLog "Remote Moonlight version: $remote"
    Write-StackLog "Local Moonlight version: $local"
    return @{ Needed = ($local -ne $remote); Remote = $remote }
}

function Wait-ServiceStatus {
    param(
        [string]$Name,
        [ValidateSet('Running', 'Stopped')]
        [string]$Status,
        [int]$TimeoutSec = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq $Status) { return }
        Start-Sleep -Seconds 1
    }
    throw "Service $Name did not reach status $Status within ${TimeoutSec}s."
}

function Wait-HttpStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$ExpectedCode = '200',
        [int]$TimeoutSec = 60
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $resp = Invoke-CurlNative -CaptureOutput @('-o', 'NUL', '-s', '-w', '%{http_code}', '--max-time', '5', $Url)
        if ($resp.Output -eq $ExpectedCode) { return $true }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Wait-SunshineHttpsReady {
    param([int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect('127.0.0.1', 47990, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(2000) -and $tcp.Connected) {
                $tcp.Close()
                return $true
            }
            $tcp.Close()
        }
        catch { }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Wait-SunshineGameStreamReady {
    param([int]$TimeoutSec = 90)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $async = $tcp.BeginConnect('127.0.0.1', 47989, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(2000) -and $tcp.Connected) {
                $tcp.Close()
                return $true
            }
            $tcp.Close()
        }
        catch { }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Invoke-MoonlightSunshinePairing {
    param(
        [string]$RepoRootPath,
        [switch]$Strict
    )

    Initialize-PairingLog -RepoRootPath $RepoRootPath
    Write-PairingLog '=== Moonlight <-> Sunshine pairing ==='
    $moonlightDir = Join-Path $RepoRootPath 'moonlight-web'
    $dataPath = Join-Path $moonlightDir 'server\data.json'
    $hostName = $env:COMPUTERNAME
    $maxRetries = 10
    $pinWaitSeconds = 30
    $cookies = Join-Path $env:TEMP 'moonlight_cookies.txt'
    $loginOut = Join-Path $env:TEMP 'moonlight_login.json'
    $loginBody = Join-Path $env:TEMP 'moonlight_login_body.json'
    $pinFile = Join-Path $env:TEMP 'moonlight_pin_response.json'

    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if (-not $curl) { throw 'curl.exe is required for Moonlight pairing.' }

    Write-PairingEnvironmentDiagnostics -DataPath $dataPath -CookieJar $cookies -PinFile $pinFile

    if (-not (Wait-SunshineHttpsReady -TimeoutSec 90)) {
        Write-PairingLog 'Sunshine HTTPS port 47990 not ready before pairing restart.' 'WARN'
    }
    else {
        Write-PairingLog 'Sunshine HTTPS port 47990 ready.'
    }
    Write-PairingLog 'POST https://localhost:47990/api/restart'
    $restartExit = Invoke-CurlNative @(
        '-u', 'bluefml1:letmeinpls',
        '-H', 'Content-Type: application/json',
        '-X', 'POST',
        '-k',
        'https://localhost:47990/api/restart'
    )
    Write-PairingLog "Sunshine restart curl exit=$restartExit"
    if ($restartExit -ne 0 -and $restartExit -ne 56 -and $restartExit -ne 52) {
        Write-PairingLog "Sunshine restart API returned curl exit $restartExit (continuing)." 'WARN'
    }
    Start-Sleep -Seconds 3
    if (-not (Wait-SunshineGameStreamReady -TimeoutSec 90)) {
        Write-PairingLog 'Sunshine GameStream port 47989 not ready before Moonlight pairing.' 'WARN'
    }
    else {
        Write-PairingLog 'Sunshine GameStream port 47989 ready.'
    }

    Write-PairingLog "Stopping service $($script:MoonlightService) and refreshing data.json"
    Stop-Service -Name $script:MoonlightService -Force -ErrorAction SilentlyContinue
    Wait-ServiceStatus -Name $script:MoonlightService -Status 'Stopped'

    if (Test-Path -LiteralPath $dataPath) { Remove-Item -LiteralPath $dataPath -Force }
    Invoke-DownloadFile -Url $script:MoonlightDataUrl -Destination $dataPath
    Assert-DownloadedJsonFile -Path $dataPath -Label 'Moonlight data.json'
    Write-PairingLog "Downloaded data.json -> $dataPath"

    Start-Service -Name $script:MoonlightService -ErrorAction Stop
    Wait-ServiceStatus -Name $script:MoonlightService -Status 'Running'
    Write-PairingLog "Service $($script:MoonlightService) running."
    if (-not (Wait-HttpStatus -Url 'http://127.0.0.1:8080' -TimeoutSec 60)) {
        $msg = 'Moonlight Web HTTP endpoint not ready on http://127.0.0.1:8080.'
        Write-PairingLog $msg 'ERROR'
        if ($Strict) { throw $msg }
        Write-PairingLog "$msg Skipping pairing." 'WARN'
        return
    }
    Write-PairingLog 'Moonlight Web http://127.0.0.1:8080 returns HTTP 200.'

    if (Test-Path -LiteralPath $cookies) { Remove-Item -LiteralPath $cookies -Force -ErrorAction SilentlyContinue }
    Write-MoonlightLoginBodyFile -Path $loginBody
    Write-PairingLog "POST http://127.0.0.1:8080/api/login bodyFile=$loginBody"
    $loginExit = Invoke-CurlNative @(
        '-c', $cookies,
        '-X', 'POST',
        'http://127.0.0.1:8080/api/login',
        '-H', 'Content-Type: application/json',
        '--data-binary', "@$loginBody",
        '-o', $loginOut,
        '-s'
    )
    $hasSession = Test-MoonlightSessionCookie -CookieJarPath $cookies
    Write-PairingLog "Login curl exit=$loginExit mlSessionCookie=$hasSession loginOut=$(Get-PinResponseFileStatus -Path $loginOut)"
    if ($loginExit -ne 0 -or -not $hasSession) {
        $msg = 'Moonlight login failed (curl exit or missing mlSession cookie).'
        Write-PairingLog $msg 'ERROR'
        if ($Strict) { throw $msg }
        Write-PairingLog "$msg Skipping pairing." 'WARN'
        return
    }

    Write-PairingLog "[*] Using pre-configured host: ID=0 Name=$hostName"
    Write-PairingEnvironmentDiagnostics -DataPath $dataPath -CookieJar $cookies -PinFile $pinFile
    Start-Sleep -Seconds 2

    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        Write-PairingLog "--- Pairing attempt $attempt/$maxRetries ---"
        Stop-CurlProcessesQuietly
        if (Test-Path -LiteralPath $pinFile) { Remove-Item -LiteralPath $pinFile -Force }

        $pairProc = Start-MoonlightPairPoll -CookieJar $cookies -OutFile $pinFile -HostId 0

        $pin = $null
        $parseNote = ''
        for ($i = 1; $i -le $pinWaitSeconds; $i++) {
            Start-Sleep -Seconds 1
            $pin = Get-MoonlightPairPinFromFile -Path $pinFile -ParseNote ([ref]$parseNote)
            if ($pin) {
                Write-PairingLog "PIN received after ${i}s: $pin ($parseNote)"
                break
            }
            if ($i % 5 -eq 0) {
                $curlRunning = -not $pairProc.HasExited
                $curlExit = if ($pairProc.HasExited) { $pairProc.ExitCode } else { 'running' }
                Write-PairingLog "Wait ${i}/${pinWaitSeconds}s curlExit=$curlExit pinFile=$(Get-PinResponseFileStatus -Path $pinFile) parse=$parseNote port47989=$(Test-TcpPortOpen -Port 47989)"
            }
        }

        if (-not $pin) {
            if (-not $pairProc.HasExited) {
                Write-PairingLog 'Stopping pair poll wrapper after timeout.' 'WARN'
                Stop-Process -Id $pairProc.Id -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-PairingLog "Pair poll wrapper ended exit=$($pairProc.ExitCode)" 'WARN'
            }
            Write-PairingLog "Pair poll final pinFile=$(Get-PinResponseFileStatus -Path $pinFile) parse=$parseNote" 'WARN'
            Write-PairingLog "Pairing attempt ${attempt}: no PIN within ${pinWaitSeconds}s." 'WARN'
            Start-Sleep -Seconds 2
            continue
        }

        Write-PairingLog "[*] Pairing attempt ${attempt}: sending PIN to Sunshine..."
        $completeFile = Join-Path $env:TEMP 'moonlight_pair_complete.json'
        $sunshinePinBodyFile = Join-Path $env:TEMP 'moonlight_sunshine_pin_body.json'
        $pinBody = "{`"pin`":`"$pin`",`"name`":`"$hostName`"}"
        Write-MoonlightJsonBodyFile -Path $sunshinePinBodyFile -JsonContent $pinBody
        Write-PairingLog "POST https://localhost:47990/api/pin bodyFile=$sunshinePinBodyFile content=$pinBody"
        $pinHeadersFile = Join-Path $env:TEMP 'moonlight_sunshine_pin_headers.txt'
        if (Test-Path -LiteralPath $pinHeadersFile) { Remove-Item -LiteralPath $pinHeadersFile -Force -ErrorAction SilentlyContinue }
        $pinExit = Invoke-CurlNative @(
            '-u', 'bluefml1:letmeinpls',
            '-H', 'Content-Type: application/json',
            '-X', 'POST',
            '-k',
            'https://localhost:47990/api/pin',
            '--data-binary', "@$sunshinePinBodyFile",
            '-D', $pinHeadersFile,
            '-o', $completeFile,
            '-s', '--max-time', '30'
        )
        $pinHttp = 'unknown'
        if (Test-Path -LiteralPath $pinHeadersFile) {
            $headerText = Get-Content -Raw -LiteralPath $pinHeadersFile -ErrorAction SilentlyContinue
            if ($headerText -match 'HTTP/[\d.]+\s+(\d{3})') { $pinHttp = $Matches[1] }
        }
        Write-PairingLog "Sunshine pin API curl exit=$pinExit http=$pinHttp response=$(Get-PinResponseFileStatus -Path $completeFile)"

        $status = $null
        try { $status = (Get-Content -Raw -LiteralPath $completeFile | ConvertFrom-Json).status } catch { }
        if ($status -eq $true -or $status -eq 'True') {
            Start-Sleep -Seconds 3
            $pairText = Get-Content -Raw -LiteralPath $pinFile -ErrorAction SilentlyContinue
            Write-PairingLog "Moonlight pair response=$(Get-PinResponseFileStatus -Path $pinFile)"
            if ($pairText -match 'Paired') {
                Write-PairingLog '[*] Pairing successful.'
                Stop-CurlProcessesQuietly
                foreach ($tempFile in @($loginOut, $loginBody, (Join-Path $env:TEMP 'moonlight_pair_body.json'), (Join-Path $env:TEMP 'moonlight_pair_poll.ps1'), (Join-Path $env:TEMP 'moonlight_sunshine_pin_body.json'), $pinFile, $completeFile, $cookies)) {
                    if (Test-Path -LiteralPath $tempFile) { Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue }
                }
                return
            }
            Write-PairingLog 'Sunshine accepted PIN but Moonlight did not report Paired.' 'WARN'
        }
        else {
            Write-PairingLog 'Sunshine pin API did not return status True.' 'WARN'
        }
        Start-Sleep -Seconds 2
    }

    Stop-CurlProcessesQuietly
    Write-PairingLog "Pairing failed after $maxRetries attempts." 'ERROR'
    Write-PairingLog "Debug files kept: cookies=$cookies pairBody=$(Join-Path $env:TEMP 'moonlight_pair_body.json') pairPoll=$(Join-Path $env:TEMP 'moonlight_pair_poll.ps1') sunshinePinBody=$(Join-Path $env:TEMP 'moonlight_sunshine_pin_body.json') pinFile=$pinFile loginOut=$loginOut complete=$(Join-Path $env:TEMP 'moonlight_pair_complete.json')" 'WARN'
    Write-PairingLog "Full log: $script:PairingLogPath"

    $failMsg = "Pairing failed after $maxRetries attempts."
    if ($Strict) { throw $failMsg }
    Write-PairingLog "$failMsg Sunshine/Moonlight updates were applied; pairing can be retried on next repair cycle." 'WARN'
}

$repo = Resolve-RepoRootPath -Override $RepoRoot
$updatedSunshine = $false
$updatedMoonlight = $false

Write-StackLog '=== Update-NextGpuStreamingStack started ==='
Write-StackLog "Repo root: $repo"
Write-StackLog "SunshineMode=$SunshineMode MoonlightMode=$MoonlightMode"

$sunshineCheck = Test-SunshineUpdateNeeded -RepoRootPath $repo -Mode $SunshineMode
if ($sunshineCheck.Needed) {
    Invoke-SunshineReinstall -RepoRootPath $repo -RemoteVersion $sunshineCheck.Remote
    $updatedSunshine = $true
}
elseif ($SunshineMode -eq 'CheckUpdate') {
    Write-StackLog '[*] Sunshine up to date or skipped.'
}

$moonlightCheck = Test-MoonlightUpdateNeeded -RepoRootPath $repo -Mode $MoonlightMode
if ($moonlightCheck.Needed) {
    Invoke-MoonlightReinstall -RepoRootPath $repo -MachineName $ComputerName -RemoteVersion $moonlightCheck.Remote
    $updatedMoonlight = $true
}
elseif ($MoonlightMode -eq 'CheckUpdate') {
    Write-StackLog '[*] Moonlight up to date or skipped.'
}

$shouldPair = $false
if ($ForcePairing) { $shouldPair = $true }
elseif (-not $SkipPairing -and ($updatedSunshine -or $updatedMoonlight)) { $shouldPair = $true }

if ($shouldPair) {
    Invoke-MoonlightSunshinePairing -RepoRootPath $repo -Strict:$ForcePairing
}
else {
    Write-StackLog '[*] Skipping Moonlight pairing (no stack updates or SkipPairing).'
}

Write-StackLog '=== Update-NextGpuStreamingStack finished ==='
