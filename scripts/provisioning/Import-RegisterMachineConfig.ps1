#Requires -Version 5.1
<#
.SYNOPSIS
    Reads register-machine-ui-config.json and writes a temporary .cmd with set statements.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ConfigPath,
    [Parameter(Mandatory)][string]$OutputBatPath
)

$ErrorActionPreference = 'Stop'

function Escape-CmdSetValue {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $s = [string]$Value
    $s = $s -replace '%', '%%'
    $s = $s -replace '\^', '^^'
    $s = $s -replace '&', '^&'
    $s = $s -replace '\|', '^|'
    $s = $s -replace '<', '^<'
    $s = $s -replace '>', '^>'
    return $s
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Error "Config not found: $ConfigPath"
    exit 1
}

try {
    $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    $config = $raw | ConvertFrom-Json
}
catch {
    Write-Error "Invalid JSON in $ConfigPath : $($_.Exception.Message)"
    exit 1
}

$enableVdd = if ($config.enableVdd) { '1' } else { '0' }
$cfToken = [string]$config.cfApiToken
$accountId = [string]$config.accountId
$apiKey = [string]$config.apiKey
$computerName = [string]$config.computerName
$price = [string]$config.price
$vendorId = if ($null -ne $config.vendorId) { [string]$config.vendorId } else { '' }
$vendorShutdownApiKey = if ($null -ne $config.vendorShutdownApiKey) { [string]$config.vendorShutdownApiKey } else { '' }
$adminAccount = [string]$config.adminAccountName
$adminPasswordEncrypted = if ($null -ne $config.adminPasswordEncrypted) { [string]$config.adminPasswordEncrypted } else { '' }

Write-Host "[DEBUG] adminPasswordEncrypted length: $($adminPasswordEncrypted.Length)"
Write-Host "[DEBUG] adminPasswordEncrypted prefix: $($adminPasswordEncrypted.Substring(0, [Math]::Min(20, $adminPasswordEncrypted.Length)))..."

$required = @{
    cfApiToken       = $cfToken
    accountId        = $accountId
    apiKey           = $apiKey
    computerName     = $computerName
    price            = $price
    adminAccountName = $adminAccount
}
foreach ($key in $required.Keys) {
    if ([string]::IsNullOrWhiteSpace($required[$key])) {
        Write-Error "Missing required field: $key"
        exit 1
    }
}

# Store admin password securely using DPAPI
if (-not [string]::IsNullOrWhiteSpace($adminPasswordEncrypted)) {
    try {
        $storeScript = Join-Path $PSScriptRoot "Store-NextGpuAdminCredential.ps1"
        if (Test-Path -LiteralPath $storeScript) {
            Write-Host "[INFO] Storing NextGPU-Admin password securely..."
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @(
                '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', $storeScript,
                '-EncryptedPassword', $adminPasswordEncrypted
            ) -Wait -PassThru -NoNewWindow
            if ($proc.ExitCode -eq 0) {
                Write-Host "[OK] Admin password stored securely."
            }
            else {
                Write-Warning "Failed to store admin password (exit code: $($proc.ExitCode))."
            }
        }
        else {
            Write-Warning "Store-NextGpuAdminCredential.ps1 not found at $storeScript"
        }
    }
    catch {
        Write-Warning "Failed to store admin password: $($_.Exception.Message)"
    }
}

$vendorId = $vendorId.Trim()
$vendorShutdownApiKey = $vendorShutdownApiKey.Trim()
$computerLower = $computerName.Trim().ToLowerInvariant()

# Persist vendor_id early so EndSession fallback works even if register API is re-run later.
$programDataNextGpu = Join-Path $env:ProgramData 'nextGPU'
if (-not (Test-Path -LiteralPath $programDataNextGpu)) {
    New-Item -ItemType Directory -Path $programDataNextGpu -Force | Out-Null
}
$vendorIdPath = Join-Path $programDataNextGpu 'vendor-id.txt'
if ([string]::IsNullOrWhiteSpace($vendorId)) {
    if (Test-Path -LiteralPath $vendorIdPath) {
        Remove-Item -LiteralPath $vendorIdPath -Force -ErrorAction SilentlyContinue
    }
}
else {
    Set-Content -LiteralPath $vendorIdPath -Value $vendorId -Encoding ASCII -Force
}

# Persist vendor shutdown API key (onDemandGPUHost) — separate from registerMachine apiKey.
$secretsHelper = Join-Path $PSScriptRoot '..\runtime\NextGpuOnDemandGpuHostSecrets.ps1'
if (Test-Path -LiteralPath $secretsHelper) {
    . $secretsHelper
    if ([string]::IsNullOrWhiteSpace($vendorId)) {
        Remove-NextGpuOnDemandGpuHostApiKey
        Write-Host '[*] Vendor shutdown API key cleared (no vendor_id).'
    }
    elseif ([string]::IsNullOrWhiteSpace($vendorShutdownApiKey)) {
        Write-Error 'vendorShutdownApiKey is required when vendorId is set.'
        exit 1
    }
    else {
        try {
            $savedSecret = Save-NextGpuOnDemandGpuHostApiKey -ApiKey $vendorShutdownApiKey
            Write-Host '[OK] Vendor shutdown API key saved (path not echoed).'
            Write-Host "[*] Secrets file: $savedSecret"
        }
        catch {
            Write-Warning "Failed to persist vendor shutdown API key: $($_.Exception.Message)"
        }
    }
}
else {
    Write-Warning 'NextGpuOnDemandGpuHostSecrets.ps1 not found; vendor shutdown API key will not persist.'
}

$lines = @(
    '@echo off',
    "set `"ENABLE_VDD=$enableVdd`"",
    "set `"VDD_CLI_SET=1`"",
    "set `"CF_API_TOKEN=$(Escape-CmdSetValue $cfToken.Trim())`"",
    "set `"ACCOUNT_ID=$(Escape-CmdSetValue $accountId.Trim())`"",
    "set `"API_KEY=$(Escape-CmdSetValue $apiKey.Trim())`"",
    "set `"COMPUTER_NAME_CUSTOM=$(Escape-CmdSetValue $computerName.Trim())`"",
    "set `"PRICE=$(Escape-CmdSetValue $price.Trim())`"",
    "set `"VENDOR_ID=$(Escape-CmdSetValue $vendorId)`"",
    "set `"ADMIN_ACCOUNT_NAME=$(Escape-CmdSetValue $adminAccount.Trim())`"",
    "set `"COMPUTER_NAME_LOWER=$(Escape-CmdSetValue $computerLower)`"",
    'set "RM_UI_CONFIG=1"'
)

$dir = Split-Path -Parent $OutputBatPath
if ($dir -and -not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

Set-Content -LiteralPath $OutputBatPath -Value $lines -Encoding ASCII
exit 0
