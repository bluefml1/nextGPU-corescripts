param(
    [string]$Username = 'nextGPU',
    [string]$DomainTxtPath = ''
)

# Moonlight fallback wipe when POST /host/cancel runs cancel_app() (Sunshine endSession.ps1) but
# verifyRentalUser.ps1 still reports the rental user is not ready.
# Never run from startSession.ps1 or automatic stream teardown — rental dashboard/API only.
# Does not call Sunshine endSession.ps1 (Sunshine config path unchanged).
#
# Invoke with named args, e.g.:
#   -Username nextGPU -DomainTxtPath "C:\path\domain.txt"

if ($Username -match '^(?i:true|false)$') {
    $Username = 'nextGPU'
}

$script:StateFileName = 'StartSession-last-start-time.txt'
$logDir = $PSScriptRoot
$script:LogPath = Join-Path $logDir "CancelSession_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$script:StateFilePath = Join-Path $logDir $script:StateFileName
$script:LogFallbackTag = 'CancelSession'

$commonPath = Join-Path $PSScriptRoot 'nextGpuSessionCommon.ps1'
if (-not (Test-Path -LiteralPath $commonPath)) {
    Write-Error "Missing shared helpers: $commonPath"
    exit 1
}
. $commonPath

Write-Log '========================================='
Write-Log "Cancel session: resetting rental user '$Username'..."
if (-not [string]::IsNullOrWhiteSpace($DomainTxtPath)) {
    Write-Log "DomainTxtPath=$DomainTxtPath" -Level INFO
}
Write-Log '========================================='

Remove-BogusRentalUsers -KeepName $Username
Repair-BogusAutologon -Name $Username

$recreated = New-NextGpuRentalUser -Name $Username
if (-not $recreated) {
    Write-Log "Could not recreate rental user '$Username' (run elevated)." -Level FAIL
    Write-Log "Log saved to: $script:LogPath"
    exit 1
}

$verifyExit = Invoke-NextGpuUserVerify -Name $Username -ProfilePolicy 'AfterRecreate'
if ($verifyExit -ne 0) {
    Write-Log "FAILED: '$Username' is not ready after cancel wipe." -Level FAIL
    Write-Log "Log saved to: $script:LogPath"
    exit 1
}

Clear-SessionStartTime

Write-Log "OK: '$Username' reset after cancel. Machine ready for next rental." -Level PASS
Write-Log "Log saved to: $script:LogPath"
exit 0
