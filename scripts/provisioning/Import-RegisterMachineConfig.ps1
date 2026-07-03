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
$adminAccount = [string]$config.adminAccountName

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

$vendorId = $vendorId.Trim()
$computerLower = $computerName.Trim().ToLowerInvariant()

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
