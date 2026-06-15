#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies TaskScheduler.ps1 and Register-*Task.ps1 wiring (static + optional live registration).
#>
[CmdletBinding()]
param(
    [switch]$Register
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tasksDir = $PSScriptRoot
$repoRoot = if ($env:NEXTGPU_REPO_ROOT) { $env:NEXTGPU_REPO_ROOT } else { (Resolve-Path (Join-Path $tasksDir '..\..')).Path }
$fail = 0

function Test-Line {
    param([string]$Label, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        Write-Host "[OK]   $Label" -ForegroundColor Green
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor DarkGray }
    } else {
        Write-Host "[FAIL] $Label" -ForegroundColor Red
        if ($Detail) { Write-Host "       $Detail" -ForegroundColor Red }
        $script:fail++
    }
}

Write-Host '=== Task Scheduler setup verification ===' -ForegroundColor Cyan
Write-Host "Repo root: $repoRoot"
Write-Host "Tasks dir: $tasksDir"
Write-Host ''

$orchestrator = Join-Path $tasksDir 'TaskScheduler.ps1'
$expectedChain = @(
    'NextGpuScheduledTaskCommon.ps1',
    'Register-HeartbeatTask.ps1',
    'Register-AutoRepairTask.ps1',
    'Register-AutoUpdateTask.ps1',
    'Register-NvidiaLogonTask.ps1',
    'Register-EndSessionTask.ps1'
)

Test-Line 'TaskScheduler.ps1 exists' (Test-Path -LiteralPath $orchestrator)

$orchestratorText = Get-Content -LiteralPath $orchestrator -Raw
foreach ($scriptName in @(
    'Register-HeartbeatTask.ps1',
    'Register-AutoRepairTask.ps1',
    'Register-AutoUpdateTask.ps1',
    'Register-NvidiaLogonTask.ps1',
    'Register-EndSessionTask.ps1'
)) {
    $path = Join-Path $tasksDir $scriptName
    Test-Line "$scriptName exists" (Test-Path -LiteralPath $path)
    Test-Line "TaskScheduler.ps1 references $scriptName" ($orchestratorText -like "*$scriptName*")
}

Test-Line 'NextGpuScheduledTaskCommon.ps1 exists' (Test-Path -LiteralPath (Join-Path $tasksDir 'NextGpuScheduledTaskCommon.ps1'))

foreach ($bat in @('heartbeat-only.bat', 'auto-repair.bat', 'auto-update.bat')) {
    $batPath = Join-Path $repoRoot "scripts\runtime\$bat"
    Test-Line "Runtime script $bat" (Test-Path -LiteralPath $batPath) $batPath
}

$endSession = Join-Path $repoRoot 'endSession.ps1'
Test-Line 'endSession.ps1 (repo root or fallback path)' (
    (Test-Path -LiteralPath $endSession) -or (Test-Path -LiteralPath 'C:\Program Files\Sunshine\scripts\endSession.ps1')
) $endSession

$nvidiaStart = Join-Path $repoRoot 'scripts\provisioning\Start-Nvidia-InSession.ps1'
Test-Line 'Start-Nvidia-InSession.ps1' (Test-Path -LiteralPath $nvidiaStart) $nvidiaStart

$nvidiaLogonHelper = Join-Path $repoRoot 'scripts\desktop\NextGpuLogonTask.ps1'
Test-Line 'NextGpuLogonTask.ps1 (NVIDIA logon helper)' (Test-Path -LiteralPath $nvidiaLogonHelper) $nvidiaLogonHelper

Write-Host ''
Write-Host '=== Common helper smoke test ===' -ForegroundColor Cyan
. (Join-Path $tasksDir 'NextGpuScheduledTaskCommon.ps1')

$durations = @{
    (New-TimeSpan -Minutes 5) = 'PT5M'
    (New-TimeSpan -Minutes 1) = 'PT1M'
    (New-TimeSpan -Hours 1)   = 'PT1H'
    (New-TimeSpan -Hours 2)   = 'PT2H'
    (New-TimeSpan -Hours 3)   = 'PT3H'
    (New-TimeSpan -Minutes 3) = 'PT3M'
}
foreach ($entry in $durations.GetEnumerator()) {
    $got = Format-Iso8601Duration -Span $entry.Key
    Test-Line "ISO duration $($entry.Key)" ($got -eq $entry.Value) "got $got expected $($entry.Value)"
}

$sampleXmlTask = 'nextGPU-VerifySample'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($isAdmin) {
    try {
        Register-NextGpuPerpetualBatTask `
            -TaskName $sampleXmlTask `
            -BatFileName 'heartbeat-only.bat' `
            -StdoutLog 'heartbeat.log' `
            -StderrLog 'heartbeat-error.log' `
            -Interval (New-TimeSpan -Minutes 5) `
            -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
            -Description 'Temporary verification task' `
            -RepoRoot $repoRoot | Out-Null

        $task = Get-ScheduledTask -TaskName $sampleXmlTask
        $xml = [xml]$task.Xml
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')

        Test-Line 'Sample task registered' ($null -ne $task)
        Test-Line 'Sample task enabled' $task.Settings.Enabled
        Test-Line 'Sample StartWhenAvailable' $task.Settings.StartWhenAvailable
        Test-Line 'Sample has BootTrigger' ($null -ne $xml.SelectSingleNode('//t:Triggers/t:BootTrigger', $ns))
        $stopAtEnd = $xml.SelectSingleNode('//t:Triggers/t:TimeTrigger/t:Repetition/t:StopAtDurationEnd', $ns)
        Test-Line 'Sample StopAtDurationEnd=false' ($stopAtEnd -and $stopAtEnd.InnerText -eq 'false')
        $interval = $xml.SelectSingleNode('//t:Triggers/t:TimeTrigger/t:Repetition/t:Interval', $ns)
        Test-Line 'Sample repetition PT5M' ($interval -and $interval.InnerText -eq 'PT5M')
        Test-Line 'Sample action powershell.exe' ($task.Actions.Execute -eq 'powershell.exe')
        Test-Line 'Sample uses Invoke-ScheduledRuntimeBat.ps1' ($task.Actions.Arguments -like '*Invoke-ScheduledRuntimeBat.ps1*')
        Test-Line 'Sample runs heartbeat-only.bat' ($task.Actions.Arguments -like '*heartbeat-only.bat*')
        Test-Line 'Sample working directory' ($task.Actions.WorkingDirectory -eq $repoRoot)
    }
    finally {
        Unregister-ScheduledTask -TaskName $sampleXmlTask -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
} else {
    Test-Line 'Sample task XML registration (admin required)' $true 'Skipped — run elevated to test live registration'
}

if ($Register) {
    Write-Host ''
    Write-Host '=== Live TaskScheduler.ps1 registration ===' -ForegroundColor Cyan
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Test-Line 'Administrator privileges for -Register' $false 'Re-run with elevated PowerShell'
    } else {
        & $orchestrator
        $expectedTasks = @{
            'nextGPU-Heartbeat'  = @{ Interval = 'PT5M'; Bat = 'heartbeat-only.bat' }
            'nextGPU-AutoRepair' = @{ Interval = 'PT1M'; Bat = 'auto-repair.bat' }
            'nextGPU-AutoUpdate' = @{ Interval = 'PT1H'; Bat = 'auto-update.bat' }
            'nextGPU-NvidiaLogon' = @{ Interval = $null; Bat = 'Start-Nvidia-InSession.ps1' }
            'EndSession'         = @{ Interval = $null; Bat = $null }
        }
        foreach ($entry in $expectedTasks.GetEnumerator()) {
            $name = $entry.Key
            $t = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Test-Line "Registered task: $name" ($null -ne $t)
            if (-not $t) { continue }
            Test-Line "$name enabled" $t.Settings.Enabled
            if ($entry.Value.Interval) {
                $tx = [xml]$t.Xml
                $nsm = New-Object System.Xml.XmlNamespaceManager($tx.NameTable)
                $nsm.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
                $ival = $tx.SelectSingleNode('//t:Triggers/t:TimeTrigger/t:Repetition/t:Interval', $nsm)
                Test-Line "$name interval $($entry.Value.Interval)" ($ival -and $ival.InnerText -eq $entry.Value.Interval)
                $args = $t.Actions.Arguments
                Test-Line "$name runs $($entry.Value.Bat)" ($args -like "*$($entry.Value.Bat)*")
            } elseif ($entry.Value.Bat) {
                $args = $t.Actions.Arguments
                Test-Line "$name runs $($entry.Value.Bat)" ($args -like "*$($entry.Value.Bat)*")
            }
        }
    }
}

Write-Host ''
if ($fail -eq 0) {
    Write-Host 'Verification passed.' -ForegroundColor Green
    exit 0
}
Write-Host "Verification failed ($fail issue(s))." -ForegroundColor Red
exit 1
