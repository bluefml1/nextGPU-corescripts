#Requires -RunAsAdministrator
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NextGpuScheduledTaskCommon.ps1')

Register-NextGpuPerpetualBatTask `
    -TaskName 'nextGPU-AutoUpdate' `
    -BatFileName 'auto-update.bat' `
    -StdoutLog 'auto-update.log' `
    -StderrLog 'auto-update-error.log' `
    -Interval (New-TimeSpan -Hours 1) `
    -ExecutionTimeLimit (New-TimeSpan -Hours 3) `
    -MultipleInstancesPolicy 'IgnoreNew' `
    -Description 'Checks Sunshine/Moonlight versions and applies updates every hour while the PC is on and machine is available.'
