# Shared at-logon scheduled task registration (avoids 0x80070534 on localized Windows).
# Dot-source from Set-ShutdownPolicy.ps1, Register-WallpaperFitLogonTask.ps1, Register-SunshineLogonTask.ps1

function Get-NextGpuLogonTaskPrincipal {
    param(
        [ValidateSet('Limited', 'Highest')]
        [string]$RunLevel = 'Limited'
    )
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($def in @(
            @{ Kind = 'GroupId'; Id = 'BUILTIN\Users' }
            @{ Kind = 'GroupId'; Id = 'Users' }
            @{ Kind = 'UserId'; Id = 'S-1-5-32-545'; LogonType = 'Group' }
        )) {
        try {
            if ($def.Kind -eq 'GroupId') {
                return New-ScheduledTaskPrincipal -GroupId $def.Id -RunLevel $RunLevel
            }
            return New-ScheduledTaskPrincipal -UserId $def.Id -LogonType $def.LogonType -RunLevel $RunLevel
        }
        catch {
            [void]$errors.Add($_.Exception.Message)
        }
    }
    throw "Could not resolve logon task principal (Users group): $($errors -join '; ')"
}

function Register-NextGpuAtLogonTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$Argument,
        [object[]]$ExtraTriggers = @(),
        [System.TimeSpan]$ExecutionTimeLimit = $null,
        [ValidateSet('Limited', 'Highest')]
        [string]$RunLevel = 'Limited',
        [string]$PowerShellExe = ''
    )

    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if ([string]::IsNullOrWhiteSpace($PowerShellExe)) {
        $PowerShellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
    }

    $action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $Argument
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $triggers = ,$trigger + @($ExtraTriggers)
    $principal = Get-NextGpuLogonTaskPrincipal -RunLevel $RunLevel
    if ($ExecutionTimeLimit) {
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
            -ExecutionTimeLimit $ExecutionTimeLimit
    }
    else {
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
    }

    try {
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
        return
    }
    catch {
        Write-Warning "Register-ScheduledTask failed for ${TaskName}: $($_.Exception.Message). Trying schtasks..."
    }

    $tr = "`"$PowerShellExe`" $Argument"
    $schtasksLevel = if ($RunLevel -eq 'Highest') { 'HIGHEST' } else { 'LIMITED' }
    foreach ($ru in @('BUILTIN\Users', 'Users')) {
        $null = schtasks.exe /Create /TN $TaskName /TR $tr /SC ONLOGON /RU $ru /RL $schtasksLevel /F 2>&1
        if ($LASTEXITCODE -eq 0) {
            return
        }
    }

    throw "Failed to register logon task $TaskName (ScheduledTasks and schtasks)."
}
