Set-StrictMode -Version Latest

function Get-NextGpuRepoRoot {
    if ($env:NEXTGPU_REPO_ROOT) {
        return $env:NEXTGPU_REPO_ROOT
    }
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Format-Iso8601Duration {
    param([TimeSpan]$Span)

    if ($Span.TotalDays -ge 1 -and ($Span.TotalHours % 24) -eq 0 -and $Span.Minutes -eq 0 -and $Span.Seconds -eq 0) {
        return 'P{0}D' -f [int]$Span.TotalDays
    }

    $parts = @()
    if ($Span.Hours -gt 0) { $parts += '{0}H' -f $Span.Hours }
    if ($Span.Minutes -gt 0) { $parts += '{0}M' -f $Span.Minutes }
    if ($Span.Seconds -gt 0) { $parts += '{0}S' -f $Span.Seconds }
    if ($parts.Count -eq 0) { return 'PT0S' }
    return 'PT' + ($parts -join '')
}

function Escape-XmlText {
    param([string]$Text)
    $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

function Register-NextGpuPerpetualBatTask {
    param(
        [Parameter(Mandatory)]
        [string]$TaskName,
        [Parameter(Mandatory)]
        [string]$BatFileName,
        [Parameter(Mandatory)]
        [string]$StdoutLog,
        [Parameter(Mandatory)]
        [string]$StderrLog,
        [Parameter(Mandatory)]
        [TimeSpan]$Interval,
        [Parameter(Mandatory)]
        [string]$Description,
        [string]$RepoRoot = (Get-NextGpuRepoRoot),
        [TimeSpan]$ExecutionTimeLimit = (New-TimeSpan -Hours 2),
        [ValidateSet('Queue', 'IgnoreNew', 'Parallel', 'StopExisting')]
        [string]$MultipleInstancesPolicy = 'Queue'
    )

    $runtimeDir = Join-Path $RepoRoot 'scripts\runtime'
    $logDir = Join-Path $RepoRoot 'logs'
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $batPath = Join-Path $runtimeDir $BatFileName
    if (-not (Test-Path -LiteralPath $batPath)) {
        throw "Batch script not found: $batPath"
    }

    $stdoutPath = Join-Path $logDir $StdoutLog
    $stderrPath = Join-Path $logDir $StderrLog
    $wrapperPs1 = Join-Path $PSScriptRoot 'Invoke-ScheduledRuntimeBat.ps1'
    if (-not (Test-Path -LiteralPath $wrapperPs1)) {
        throw "Task runner script not found: $wrapperPs1"
    }

    $psArgs = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -BatPath "{1}" -StdoutLog "{2}" -StderrLog "{3}"' -f `
        $wrapperPs1, $batPath, $stdoutPath, $stderrPath
    $startBoundary = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
    $intervalIso = Format-Iso8601Duration -Span $Interval
    $executionLimitIso = Format-Iso8601Duration -Span $ExecutionTimeLimit
    $xmlPsArgs = Escape-XmlText -Text $psArgs
    $xmlRepoRoot = Escape-XmlText -Text $RepoRoot
    $xmlDescription = Escape-XmlText -Text $Description

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$xmlDescription</Description>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
    <TimeTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      <Repetition>
        <Interval>$intervalIso</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>$MultipleInstancesPolicy</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>$executionLimitIso</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$xmlPsArgs</Arguments>
      <WorkingDirectory>$xmlRepoRoot</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force | Out-Null
    Write-Host "[*] Registered scheduled task: $TaskName (every $intervalIso, indefinite, boot + wake catch-up)"
}

# Legacy helper kept for scripts that do not need perpetual scheduling yet.
function Register-NextGpuRepeatingBatTask {
    param(
        [Parameter(Mandatory)]
        [string]$TaskName,
        [Parameter(Mandatory)]
        [string]$BatFileName,
        [Parameter(Mandatory)]
        [string]$StdoutLog,
        [Parameter(Mandatory)]
        [string]$StderrLog,
        [Parameter(Mandatory)]
        [TimeSpan]$Interval,
        [string]$RepoRoot = (Get-NextGpuRepoRoot),
        [TimeSpan]$ExecutionTimeLimit = (New-TimeSpan -Hours 2),
        [string]$Description = 'NextGPU scheduled maintenance task.'
    )

    Register-NextGpuPerpetualBatTask `
        -TaskName $TaskName `
        -BatFileName $BatFileName `
        -StdoutLog $StdoutLog `
        -StderrLog $StderrLog `
        -Interval $Interval `
        -Description $Description `
        -RepoRoot $RepoRoot `
        -ExecutionTimeLimit $ExecutionTimeLimit `
        -MultipleInstancesPolicy 'Queue'
}
