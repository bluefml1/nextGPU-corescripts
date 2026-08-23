#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Register nextGPU-PlayniteLogon — starts Playnite elevated as NextGPU-Admin at user logon.
.DESCRIPTION
    AtLogOn task runs as Limited nextGPU and calls NextGPU.Launcher.exe --play-elevated
    (WinExe, no console), which asks
    NextGPUService for op=launch-elevated → Playnite.DesktopApp.exe --startdesktop
    --hidesplashscreen as NextGPU-Admin. Playnite folder stays data-volume Users RX
    (no nextGPU write ACL); Admin owns games.db / CEF writes.
.EXAMPLE
    .\Register-PlayniteLogonTask.ps1
    .\Register-PlayniteLogonTask.ps1 -PlayniteInstallDir "D:\Playnite"
#>
[CmdletBinding()]
param(
    [string]$PlayniteInstallDir = '',
    [string]$TaskName = 'nextGPU-PlayniteLogon'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$watcherRoot = $PSScriptRoot
$repoRoot = Split-Path $watcherRoot -Parent
. (Join-Path $watcherRoot 'Playnite-Common.ps1')

$helper = Join-Path $repoRoot 'scripts\desktop\NextGpuLogonTask.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    throw "Logon task helper not found: $helper"
}
. $helper

$installDir = Resolve-PlayniteInstallPathFromConfig -RepoRoot $watcherRoot -OverrideDir $PlayniteInstallDir
if ([string]::IsNullOrWhiteSpace($installDir)) {
    throw "Playnite install directory not set. Pass -PlayniteInstallDir or run Setup-PlayniteSteam first (PlayniteInstall.path)."
}
$playniteExe = Get-PlayniteDesktopExe -InstallDir $installDir

# Deploy script copies for manual/debug; logon uses WinExe NextGPU.Launcher (no console).
$destDir = Join-Path $env:ProgramData 'nextGPU\scripts'
$srcPs1 = Join-Path $repoRoot 'scripts\runtime\NextGPU-PlayElevated.ps1'
$srcVbs = Join-Path $repoRoot 'scripts\runtime\NextGPU-PlayElevated.vbs'
$srcCmd = Join-Path $repoRoot 'scripts\runtime\NextGPU-PlayElevated.cmd'
if (-not (Test-Path -LiteralPath $destDir)) {
    New-Item -ItemType Directory -Path $destDir -Force | Out-Null
}
if (Test-Path -LiteralPath $srcPs1) {
    Copy-Item -LiteralPath $srcPs1 -Destination (Join-Path $destDir 'NextGPU-PlayElevated.ps1') -Force
}
if (Test-Path -LiteralPath $srcVbs) {
    Copy-Item -LiteralPath $srcVbs -Destination (Join-Path $destDir 'NextGPU-PlayElevated.vbs') -Force
}
if (Test-Path -LiteralPath $srcCmd) {
    Copy-Item -LiteralPath $srcCmd -Destination (Join-Path $destDir 'NextGPU-PlayElevated.cmd') -Force
}

$launcherExe = Join-Path $env:ProgramFiles 'NextGPU\Launcher\NextGPU.Launcher.exe'
if (-not (Test-Path -LiteralPath $launcherExe)) {
    throw "NextGPU.Launcher.exe not found: $launcherExe (install NextGPU Launcher, then re-register this task)"
}

# Do not pass --wait: Playnite stays open for the session; task must exit after elevate request.
$elevateArgs = @(
    '--play-elevated'
    '--exe'
    ('"{0}"' -f $playniteExe)
    '--cwd'
    ('"{0}"' -f $installDir)
    '--args'
    '"--startdesktop --hidesplashscreen"'
) -join ' '

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction -Execute $launcherExe -Argument $elevateArgs -WorkingDirectory $installDir
$trigger = New-ScheduledTaskTrigger -AtLogOn
$principal = Get-NextGpuLogonTaskPrincipal -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -Hidden

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
}
catch {
    Write-Warning "Register-ScheduledTask failed for ${TaskName}: $($_.Exception.Message). Trying schtasks..."
    $tr = "`"$launcherExe`" $elevateArgs"
    $ok = $false
    foreach ($ru in @('BUILTIN\Users', 'Users')) {
        $null = schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /RU $ru /RL LIMITED /F 2>&1
        if ($LASTEXITCODE -eq 0) {
            $ok = $true
            break
        }
    }
    if (-not $ok) {
        throw "Failed to register logon task $TaskName (ScheduledTasks and schtasks)."
    }
}

Enable-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Out-Null
Write-Host "[*] Registered scheduled task: $TaskName"
Write-Host "    Elevate: $launcherExe --play-elevated"
Write-Host "    Target: $playniteExe --startdesktop --hidesplashscreen"
Write-Host "    Principal: BUILTIN\Users (Limited) → pipe launch-elevated → NextGPU-Admin"
Write-Host "    Requires: NextGPUService running + NextGPU-Admin credential at logon."
