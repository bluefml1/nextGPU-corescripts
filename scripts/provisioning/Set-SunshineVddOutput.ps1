#Requires -Version 5.1
<#
.SYNOPSIS
    Resolve VDD device_id and write output_name to sunshine.conf (update path).
.DESCRIPTION
    Retries up to 6 times with Sunshine restart between attempts. Display-path ID from
    Get-DisplayDeviceId.ps1; sunshine.log ID from Get-SunshineDeviceIdFromLog.ps1 overrides
    when a usable complete entry exists (scored by display_name / info); otherwise display paths.
    Exit 0 when output_name is written; exit 1 when not resolved (non-fatal for callers).
#>
[CmdletBinding()]
param(
    [string]$ConfPath = 'C:\Program Files\Sunshine\config\sunshine.conf',
    [int]$MaxAttempts = 6,
    [int]$WaitBetweenAttemptsSec = 8,
    [string]$RepoRoot = '',
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$script:VddLogPath = $null

function Write-VddMessage {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    if (-not ($Quiet -and $Level -eq 'INFO')) {
        switch ($Level) {
            'WARN' { Write-Host $Message -ForegroundColor Yellow }
            'ERROR' { Write-Host $Message -ForegroundColor Red }
            default { Write-Host $Message }
        }
    }

    if (-not $script:VddLogPath) { return }
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    for ($retry = 0; $retry -lt 5; $retry++) {
        try {
            $stream = [System.IO.File]::Open(
                $script:VddLogPath,
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
                Write-Host "VDD log write failed: $($_.Exception.Message)" -ForegroundColor Yellow
            }
            else {
                Start-Sleep -Milliseconds (50 * ($retry + 1))
            }
        }
    }
}

function Resolve-RepoRootPath {
    param([string]$Override)
    if (-not [string]::IsNullOrWhiteSpace($Override)) { return $Override.TrimEnd('\') }
    if ($env:NEXTGPU_REPO_ROOT) { return $env:NEXTGPU_REPO_ROOT.TrimEnd('\') }
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Initialize-VddLog {
    param([string]$RepoRootPath)
    $logDir = Join-Path $RepoRootPath 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    $script:VddLogPath = Join-Path $logDir 'sunshine-vdd-setup.log'
    Write-VddMessage '=== Sunshine VDD output_name setup ==='
    Write-VddMessage "Context USERNAME=$env:USERNAME USERDOMAIN=$env:USERDOMAIN COMPUTERNAME=$env:COMPUTERNAME"
    Write-VddMessage "ConfPath=$ConfPath MaxAttempts=$MaxAttempts WaitBetweenAttemptsSec=$WaitBetweenAttemptsSec"
}

function Test-DeviceIdLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) { return $false }
    return ($Line.Trim() -match '^\{[0-9a-fA-F-]{36}\}$')
}

function Invoke-ProvisioningScriptStdout {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$ArgumentList = @()
    )
    if (-not (Test-Path -LiteralPath $ScriptPath)) { return $null }
    try {
        $lines = @(& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $ScriptPath @ArgumentList 2>$null)
        foreach ($line in $lines) {
            if (Test-DeviceIdLine -Line $line) {
                return $line.Trim()
            }
        }
    }
    catch { }
    return $null
}

function Get-VddDeviceIdFromDisplayPaths {
    $scriptPath = Join-Path $PSScriptRoot 'Get-DisplayDeviceId.ps1'
    foreach ($argSet in @(@(), @('-IncludeInactive'))) {
        $id = Invoke-ProvisioningScriptStdout -ScriptPath $scriptPath -ArgumentList $argSet
        if ($id) { return $id }
    }
    return $null
}

function Get-VddDeviceIdFromSunshineLog {
    $scriptPath = Join-Path $PSScriptRoot 'Get-SunshineDeviceIdFromLog.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        return [PSCustomObject]@{ DeviceId = $null; IncompleteCandidates = 0 }
    }

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $null = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
            '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath
        ) -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile

        $deviceId = $null
        if (Test-Path -LiteralPath $outFile) {
            foreach ($line in Get-Content -LiteralPath $outFile -ErrorAction SilentlyContinue) {
                if (Test-DeviceIdLine -Line $line) {
                    $deviceId = $line.Trim()
                    break
                }
            }
        }

        $incompleteCount = 0
        if (Test-Path -LiteralPath $errFile) {
            foreach ($line in Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue) {
                if ($line -match '(\d+) incomplete candidate') {
                    $incompleteCount = [int]$Matches[1]
                }
            }
        }

        return [PSCustomObject]@{
            DeviceId              = $deviceId
            IncompleteCandidates  = $incompleteCount
        }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Resolve-VddDeviceId {
    $displayId = Get-VddDeviceIdFromDisplayPaths
    $logInfo = Get-VddDeviceIdFromSunshineLog

    if ($logInfo.DeviceId) {
        return [PSCustomObject]@{
            DeviceId                 = $logInfo.DeviceId
            Source                   = 'sunshine.log'
            DisplayPathId            = $displayId
            LogIncompleteCandidates  = 0
        }
    }
    if ($displayId) {
        return [PSCustomObject]@{
            DeviceId                 = $displayId
            Source                   = 'display-path'
            DisplayPathId            = $displayId
            LogIncompleteCandidates  = $logInfo.IncompleteCandidates
        }
    }
    return $null
}

function Get-SunshineConfOutputName {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*output_name\s*=\s*(.+?)(?:\s+#.*)?$') {
            $value = $Matches[1].Trim()
            if (Test-DeviceIdLine -Line $value) {
                return $value
            }
            return $null
        }
    }
    return $null
}

function Set-SunshineConfLine {
    param(
        [string]$Content,
        [string]$Name,
        [string]$Value
    )
    if ($Content -match ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=')) {
        return ($Content -replace ('(?m)^\s*' + [regex]::Escape($Name) + '\s*=.*'), ($Name + ' = ' + $Value))
    }
    return ($Content.TrimEnd() + "`r`n" + $Name + ' = ' + $Value + "`r`n")
}

function Set-SunshineConfOutputName {
    param(
        [string]$Path,
        [string]$DeviceId
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "sunshine.conf not found: $Path"
    }
    $content = Get-Content -Raw -LiteralPath $Path
    $content = Set-SunshineConfLine -Content $content -Name 'output_name' -Value $DeviceId
    [System.IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
}

function Invoke-VddSunshineRestartForRetry {
    param([string]$RepoRootPath)
    $restartPs1 = Join-Path $PSScriptRoot 'Invoke-SunshineApiRestart.ps1'
    if (-not (Test-Path -LiteralPath $restartPs1)) {
        Write-VddMessage "Invoke-SunshineApiRestart.ps1 not found: $restartPs1" 'WARN'
        return $false
    }
    Write-VddMessage 'Calling Invoke-SunshineApiRestart.ps1 -LoopUntilVdd -MaxAttempts 1 (retry probe)...'
    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $restartPs1 `
        -LoopUntilVdd -MaxAttempts 1 -IntervalSeconds 1 `
        -WaitAfterSec 5 -AfterRestartProbeSeconds 15 `
        -ResetWaitHttp200TimeoutSec 20 -ResetPollSeconds 1 | Out-Null
    $exitCode = $LASTEXITCODE
    Write-VddMessage "Restart helper exit=$exitCode"
    return ($exitCode -eq 0)
}

function Invoke-FinalSunshineRestart {
    param([string]$RepoRootPath)
    $restartPs1 = Join-Path $PSScriptRoot 'Invoke-SunshineApiRestart.ps1'
    if (Test-Path -LiteralPath $restartPs1) {
        Write-VddMessage 'Final Sunshine restart after output_name write...'
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $restartPs1 -WaitAfterSec 5 | Out-Null
        Write-VddMessage "Final restart exit=$LASTEXITCODE"
    }

    if ($RepoRootPath) {
        $sessionPs1 = Join-Path $RepoRootPath 'scripts\provisioning\Start-Sunshine-InSession.ps1'
        if (Test-Path -LiteralPath $sessionPs1) {
            Write-VddMessage "Running Start-Sunshine-InSession.ps1..."
            & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $sessionPs1 -Quiet | Out-Null
        }
    }
}

$repo = Resolve-RepoRootPath -Override $RepoRoot
Initialize-VddLog -RepoRootPath $repo

if (-not (Test-Path -LiteralPath $ConfPath)) {
    Write-VddMessage "sunshine.conf not found: $ConfPath" 'ERROR'
    exit 1
}

Write-VddMessage '=== Resolving VDD device_id ==='

$resolved = Resolve-VddDeviceId
if ($resolved) {
    $existing = Get-SunshineConfOutputName -Path $ConfPath
    if ($existing -eq $resolved.DeviceId) {
        Write-VddMessage "output_name already set to $($resolved.DeviceId) (source=$($resolved.Source)); skipping retry loop."
        exit 0
    }
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-VddMessage "--- Attempt $attempt / $MaxAttempts ---"
    $resolved = Resolve-VddDeviceId

    if ($resolved) {
        if ($resolved.Source -eq 'display-path' -and $resolved.LogIncompleteCandidates -gt 0) {
            Write-VddMessage "Resolved device_id=$($resolved.DeviceId) source=display-path (log had $($resolved.LogIncompleteCandidates) VDD entries but none usable)"
        }
        elseif ($resolved.DisplayPathId -and $resolved.Source -eq 'sunshine.log' -and $resolved.DisplayPathId -ne $resolved.DeviceId) {
            Write-VddMessage "Using sunshine.log device_id=$($resolved.DeviceId) (display-path had $($resolved.DisplayPathId))"
        }
        elseif ($resolved.Source -eq 'sunshine.log') {
            Write-VddMessage "Resolved device_id=$($resolved.DeviceId) source=sunshine.log (scored complete entry)"
        }
        else {
            Write-VddMessage "Resolved device_id=$($resolved.DeviceId) source=$($resolved.Source)"
        }

        Set-SunshineConfOutputName -Path $ConfPath -DeviceId $resolved.DeviceId
        Write-VddMessage "OK output_name = $($resolved.DeviceId) written to $ConfPath"
        Invoke-FinalSunshineRestart -RepoRootPath $repo
        Write-VddMessage '=== VDD output_name setup finished (success) ==='
        exit 0
    }

    Write-VddMessage "Attempt ${attempt}: no VDD device_id (display-path or sunshine.log)" 'WARN'

    if ($attempt -lt $MaxAttempts) {
        Invoke-VddSunshineRestartForRetry -RepoRootPath $repo | Out-Null
        Write-VddMessage "Waiting ${WaitBetweenAttemptsSec}s before next attempt..."
        Start-Sleep -Seconds $WaitBetweenAttemptsSec
    }
}

Write-VddMessage "VDD device_id not resolved after $MaxAttempts attempts." 'WARN'
Write-VddMessage 'Hints: reboot after VDD install; log in via RDP/console so Sunshine runs in user session; run Get-DisplayDeviceId.ps1 -ListAll -IncludeInactive' 'WARN'
Write-VddMessage "Full log: $script:VddLogPath"
Write-VddMessage '=== VDD output_name setup finished (not resolved) ===' 'WARN'
exit 1
