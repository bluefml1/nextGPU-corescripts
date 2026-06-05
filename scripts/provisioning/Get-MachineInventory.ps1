#Requires -Version 5.1
# Emits machine fields for RegisterMachine API (CIM — no wmic.exe required).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$cs = Get-CimInstance Win32_ComputerSystem
$gpus = @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name })

$gpuName = ''
foreach ($pattern in @('NVIDIA', 'AMD Radeon', 'Intel')) {
    $match = $gpus | Where-Object { $_.Name -match $pattern } | Select-Object -First 1
    if ($match) { $gpuName = $match.Name.Trim(); break }
}
if (-not $gpuName -and $gpus.Count -gt 0) {
    $gpuName = ($gpus | Where-Object { $_.Name } | Select-Object -First 1).Name.Trim()
}
if (-not $gpuName) { $gpuName = 'Unknown' }

$ramGb = 0
if ($cs.TotalPhysicalMemory) {
    $ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
}

$now = Get-Date
$lastCheckin = $now.ToString('yyyy-MM-dd HH:mm')

# Pipe-safe single-line values for batch FOR /F
Write-Output ("OS_NAME={0}" -f ($os.Caption -replace '\|',' '))
Write-Output ("OS_VERSION={0}" -f $os.Version)
Write-Output ("CPU={0}" -f (($cpu.Name -replace '\|',' ').Trim()))
Write-Output ("TotalPhysicalMemory={0}" -f $ramGb)
Write-Output ("GPU_NAME={0}" -f ($gpuName -replace '\|',' '))
Write-Output ("LAST_CHECKIN={0}" -f $lastCheckin)
