#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NextGpuScheduledTaskCommon.ps1')

Register-NextGpuPerpetualBatTask `
    -TaskName 'nextGPU-AutoRepair' `
    -BatFileName 'auto-repair.bat' `
    -StdoutLog 'auto-repair.log' `
    -StderrLog 'auto-repair-error.log' `
    -Interval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -MultipleInstancesPolicy 'IgnoreNew' `
    -Description 'Health-checks cloudflared, Sunshine, Moonlight, and local HTTP every minute while the PC is on. Skips when machine-status.flag=updating.'
