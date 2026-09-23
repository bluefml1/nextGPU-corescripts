# =====================================================================
# Update-Games.ps1
# Restarts Sunshine (API), fetches apps from Moonlight Web, sends to updateNewGame
# Usage: .\scripts\maintenance\Update-Games.ps1 -ComputerName "MYPC_AB12" -PublicIP "1.2.3.4"
# Or run without args — it will prompt you.
# =====================================================================

param(
    [string]$ComputerName,
    [string]$PublicIP,
    [switch]$ForceMoonlightRefresh,
    [switch]$SkipSunshineRestart
)

$API_URL   = "https://oa0bwhfkqk.execute-api.ap-southeast-1.amazonaws.com/updateNewGame"
$HOST_ID   = 0
$DOMAIN    = $null  # auto-read from domain.txt if found

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$RepoRoot = if ($env:NEXTGPU_REPO_ROOT) {
    $env:NEXTGPU_REPO_ROOT
} else {
    (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
}

function Wait-MoonlightAppsReady {
    param(
        [string]$AppsUrl,
        [int]$TimeoutSec = 45
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $null = Invoke-RestMethod -Uri $AppsUrl -Method GET -TimeoutSec 5
            return $true
        } catch {
            Start-Sleep -Seconds 2
        }
    }
    return $false
}

# ===================== READ domain.txt (optional) =====================
$DomainFile = Join-Path $RepoRoot "domain.txt"
if (Test-Path $DomainFile) {
    foreach ($line in Get-Content $DomainFile) {
        if ($line -match "^DOMAIN=(.+)")        { $DOMAIN = $matches[1].Trim() }
        if (-not $ComputerName -and $line -match "^COMPUTER_NAME=(.+)") { $ComputerName = $matches[1].Trim() }
        if (-not $PublicIP -and $line -match "^PUBLIC_IP=(.+)")         { $PublicIP = $matches[1].Trim() }
    }
}

# ===================== INPUT =====================
if (-not $ComputerName) {
    $ComputerName = Read-Host "Enter computer_name"
}
if (-not $PublicIP) {
    $PublicIP = Read-Host "Enter publicIP"
}

if (-not $ComputerName -or -not $PublicIP) {
    Write-Host "ERROR: computer_name and publicIP are required." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "computer_name : $ComputerName" -ForegroundColor Cyan
Write-Host "publicIP      : $PublicIP"      -ForegroundColor Cyan
if ($DOMAIN) { Write-Host "domain        : $DOMAIN" -ForegroundColor Cyan }
Write-Host ""

# After Sunshine restart, force Moonlight to re-read Sunshine's app list.
if (-not $SkipSunshineRestart) {
    $ForceMoonlightRefresh = $true
}
$refreshFlag = if ($ForceMoonlightRefresh) { 'true' } else { 'false' }
$APPS_URL  = "http://localhost:8080/api/apps?host_id=$HOST_ID&force_refresh=$refreshFlag"

# ===================== RESTART SUNSHINE =====================
if (-not $SkipSunshineRestart) {
    Write-Host "[1/4] Restarting Sunshine via API (so app list is complete)..." -ForegroundColor Yellow
    $restartPs1 = Join-Path $RepoRoot "scripts\provisioning\Invoke-SunshineApiRestart.ps1"
    if (-not (Test-Path -LiteralPath $restartPs1)) {
        Write-Host "ERROR: Invoke-SunshineApiRestart.ps1 not found at $restartPs1" -ForegroundColor Red
        exit 1
    }

    & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $restartPs1 `
        -SkipResetDisplayPersistence `
        -WaitAfterSec 12
    $restartExit = $LASTEXITCODE
    if ($null -eq $restartExit) { $restartExit = 0 }
    # Invoke-SunshineApiRestart treats connection-closed (52/56) as success during restart.
    if ($restartExit -ne 0 -and $restartExit -ne 52 -and $restartExit -ne 56) {
        Write-Host "ERROR: Sunshine API restart failed (exit $restartExit)." -ForegroundColor Red
        exit 1
    }
    Write-Host "   Sunshine restart requested. Waiting for Moonlight Web..." -ForegroundColor Green

    if (-not (Wait-MoonlightAppsReady -AppsUrl $APPS_URL -TimeoutSec 45)) {
        Write-Host "WARN: Moonlight Web not ready yet; will still attempt fetch." -ForegroundColor Yellow
    }
} else {
    Write-Host "[1/4] Skipping Sunshine restart (-SkipSunshineRestart)." -ForegroundColor DarkGray
}

# ===================== FETCH APPS =====================
Write-Host ""
Write-Host "[2/4] Fetching apps from Moonlight Web (force_refresh=$refreshFlag)..." -ForegroundColor Yellow

try {
    $Response = Invoke-RestMethod -Uri $APPS_URL -Method GET -TimeoutSec 30
} catch {
    Write-Host "ERROR: Could not reach $APPS_URL" -ForegroundColor Red
    Write-Host "       Make sure Moonlight Web service is running." -ForegroundColor DarkGray
    exit 1
}

$Apps = $Response.apps
if (-not $Apps -or $Apps.Count -eq 0) {
    Write-Host "ERROR: No apps returned from Moonlight Web." -ForegroundColor Red
    exit 1
}

Write-Host "   Found $($Apps.Count) app(s):" -ForegroundColor Green
foreach ($App in $Apps) {
    Write-Host "   - $($App.title) (app_id: $($App.app_id))" -ForegroundColor DarkGray
}

# ===================== BUILD PAYLOAD =====================
Write-Host ""
Write-Host "[3/4] Building payload..." -ForegroundColor Yellow

$Payload = [ordered]@{
    computer_name = $ComputerName
    publicIP      = $PublicIP
}

foreach ($App in $Apps) {
    $Title = $App.title.Trim()
    $AppId = $App.app_id

    if ($DOMAIN) {
        $StreamUrl = "https://$DOMAIN/stream.html?hostId=$HOST_ID&appId=$AppId"
    } else {
        $StreamUrl = "http://localhost:8080/stream.html?hostId=$HOST_ID&appId=$AppId"
    }

    $Payload[$Title] = $StreamUrl
}

$JsonPayload = $Payload | ConvertTo-Json -Compress
Write-Host "   Payload built with $($Apps.Count) game(s)." -ForegroundColor Green

# ===================== SEND TO API =====================
Write-Host ""
Write-Host "[4/4] Sending to updateNewGame API..." -ForegroundColor Yellow

try {
    $Result = Invoke-RestMethod `
        -Uri $API_URL `
        -Method POST `
        -ContentType "application/json" `
        -Body $JsonPayload `
        -TimeoutSec 30

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "SUCCESS!" -ForegroundColor Green
    if ($Result.added)   { Write-Host "  Added   : $($Result.added -join ', ')"   -ForegroundColor Green }
    if ($Result.removed) { Write-Host "  Removed : $($Result.removed -join ', ')" -ForegroundColor Yellow }
    Write-Host "  Message : $($Result.message)" -ForegroundColor Green
    Write-Host "========================================" -ForegroundColor Green

} catch {
    $StatusCode = $_.Exception.Response.StatusCode.Value__
    $ErrorBody  = $_.ErrorDetails.Message

    Write-Host ""
    Write-Host "========================================" -ForegroundColor Red
    Write-Host "ERROR: API call failed (HTTP $StatusCode)" -ForegroundColor Red
    if ($ErrorBody) {
        try {
            $Parsed = $ErrorBody | ConvertFrom-Json
            Write-Host "  $($Parsed.error)" -ForegroundColor Red
        } catch {
            Write-Host "  $ErrorBody" -ForegroundColor Red
        }
    }
    Write-Host "========================================" -ForegroundColor Red
    exit 1
}