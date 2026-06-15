#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NextGpuScheduledTaskCommon.ps1')

Register-NextGpuPerpetualBatTask `
    -TaskName 'nextGPU-Heartbeat' `
    -BatFileName 'heartbeat-only.bat' `
    -StdoutLog 'heartbeat.log' `
    -StderrLog 'heartbeat-error.log' `
    -Interval (New-TimeSpan -Minutes 5) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 3) `
    -MultipleInstancesPolicy 'Queue' `
    -Description 'Posts machine status to AWS every 5 minutes while the PC is on.'
