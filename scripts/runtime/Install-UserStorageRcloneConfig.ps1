#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Write [nextgpu-user] rclone remote under %ProgramData%\nextGPU\rclone\ (bucket/region/creds only).
#>
[CmdletBinding()]
param(
    [string]$AccessKeyId = '',
    [string]$SecretAccessKey = '',
    [string]$Bucket = '',
    [string]$Region = '',
    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commonPath = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
. $commonPath

if ([string]::IsNullOrWhiteSpace($Bucket)) {
    $Bucket = $script:NextGpuUserStorageBucket
}
if ([string]::IsNullOrWhiteSpace($Region)) {
    $Region = $script:NextGpuUserStorageRegion
}

$creds = Get-UserStorageS3Credentials
if (-not $AccessKeyId -and $creds) {
    $AccessKeyId = $creds.AccessKeyId
}
if (-not $SecretAccessKey -and $creds) {
    $SecretAccessKey = $creds.SecretAccessKey
}

if ([string]::IsNullOrWhiteSpace($AccessKeyId) -or [string]::IsNullOrWhiteSpace($SecretAccessKey)) {
    if ($NoPrompt) {
        Write-Host '[ERROR] AWS credentials missing. Set NEXTGPU_USER_S3_* machine env vars or create:' -ForegroundColor Red
        Write-Host "  $script:NextGpuUserStorageSecretsDir\user-s3.env" -ForegroundColor Red
        exit 1
    }

    $prompted = Request-UserStorageS3Credentials -AllowSave
    if (-not $prompted) {
        Write-Host '[ERROR] User storage setup stopped - credentials were not provided.' -ForegroundColor Red
        exit 1
    }
    $AccessKeyId = $prompted.AccessKeyId
    $SecretAccessKey = $prompted.SecretAccessKey
    if ($prompted.Source -and $prompted.Source -ne 'prompt') {
        Write-Host "[*] Using credentials from $($prompted.Source)" -ForegroundColor DarkGray
    }
}

if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageRcloneDir)) {
    New-Item -ItemType Directory -Path $script:NextGpuUserStorageRcloneDir -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $script:NextGpuUserStorageSecretsDir)) {
    New-Item -ItemType Directory -Path $script:NextGpuUserStorageSecretsDir -Force | Out-Null
}

$remote = $script:NextGpuUserStorageRemoteName
# Do not set "bucket" here: IAM keys often see all buckets at remote root.
# Mount uses nextgpu-user:next-gpu-storage/<userID>/ (see Get-UserStorageRemotePathForUserId).
$ini = @"
[$remote]
type = s3
provider = AWS
access_key_id = $AccessKeyId
secret_access_key = $SecretAccessKey
region = $Region
no_check_bucket = true
"@

Set-Content -LiteralPath $script:NextGpuUserStorageRcloneConfigPath -Value $ini.TrimEnd() -Encoding UTF8 -Force

try {
    Set-UserStorageRcloneConfigAcl
    $null = Set-NextGpuRentalUserStorageAccess
    Write-Host '[*] rclone.conf + ProgramData paths readable by BUILTIN\Users (recreate-safe).'
} catch {
    Write-Warning "Could not set ACL on rclone.conf: $($_.Exception.Message)"
}

Write-UserStorageLog "Wrote rclone config [$remote] (path ${remote}:$Bucket/<userID>/; region $Region)." -Level OK
Write-Host "[*] Config: $script:NextGpuUserStorageRcloneConfigPath"
Write-Host "[*] Per-user S3 prefix is resolved at logon from checkDomain (not stored in config)."
exit 0
