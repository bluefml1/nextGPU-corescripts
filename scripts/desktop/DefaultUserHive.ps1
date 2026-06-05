# Shared helpers for mounting C:\Users\Default\NTUSER.DAT without leaving stale hives.
# Dot-source from Set-DesktopWallpaper-Gpo.ps1 and Set-ShutdownPolicy.ps1.

$Script:DefaultUserHiveNames = @(
    'HKU\NextGPUWallpaperDefault',
    'HKU\NextGPUShutdownDefault',
    'HKU\NextGPUDefaultUser',
    'HKU\NextGPUWallpaperUninstall',
    'HKU\NextGPUShutdownUninstall',
    'HKU\NextGPUUninstallDefault'
)

function Invoke-RegExe {
    param([Parameter(Mandatory)][string[]]$RegArguments)
    $escaped = ($RegArguments | ForEach-Object {
        if ($null -eq $_) { '""' }
        elseif ($_ -match '[\s"]') { '"' + ($_ -replace '"', '""') + '"' }
        else { $_ }
    }) -join ' '
    $output = cmd.exe /c "reg.exe $escaped 2>&1"
    $exitCode = $LASTEXITCODE
    $text = if ($null -eq $output) { '' } else { ($output | Out-String).Trim() }
    return @{ ExitCode = $exitCode; Output = $text }
}

function Unload-RegistryHiveSafe {
    param([Parameter(Mandatory)][string]$HiveName)

    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 400

    $last = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        $last = Invoke-RegExe -RegArguments @('unload', $HiveName)
        if ($last.ExitCode -eq 0) {
            return $last
        }
        if ($attempt -lt 5) {
            Start-Sleep -Seconds 1
        }
    }
    return $last
}

function Release-StaleDefaultUserHives {
    [CmdletBinding()]
    param(
        [string[]]$ExtraHiveNames = @()
    )

    $names = @($Script:DefaultUserHiveNames) + @($ExtraHiveNames) | Select-Object -Unique
    foreach ($hive in $names) {
        if ((Invoke-RegExe -RegArguments @('query', $hive)).ExitCode -ne 0) {
            continue
        }
        $unload = Unload-RegistryHiveSafe -HiveName $hive
        if ($unload.ExitCode -ne 0 -and $unload.Output) {
            Write-Verbose "Could not unload ${hive}: $($unload.Output)"
        }
    }

    [gc]::Collect()
    [gc]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500
}

function Invoke-DefaultUserNtuserScript {
    param(
        [Parameter(Mandatory)][scriptblock]$ApplyKeys,
        [string]$HiveName = 'HKU\NextGPUDefaultUser',
        [string]$NtuserPath = $(Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT')
    )

    if (-not (Test-Path -LiteralPath $NtuserPath)) {
        return @{ Loaded = $false; HiveName = $HiveName; Message = "NTUSER.DAT not found: $NtuserPath" }
    }

    Release-StaleDefaultUserHives -ExtraHiveNames @($HiveName)

    $loaded = $false
    try {
        $load = Invoke-RegExe -RegArguments @('load', $HiveName, $NtuserPath)
        if ($load.ExitCode -ne 0) {
            return @{ Loaded = $false; HiveName = $HiveName; Message = $load.Output }
        }
        $loaded = $true
        & $ApplyKeys $HiveName
        return @{ Loaded = $true; HiveName = $HiveName; Message = '' }
    }
    finally {
        if ($loaded) {
            $unload = Unload-RegistryHiveSafe -HiveName $HiveName
            if ($unload.ExitCode -ne 0) {
                Write-Warning "Could not unload $HiveName. registry.pol / logon tasks still apply. $($unload.Output)"
            }
        }
    }
}

function Set-DefaultUserShutdownExplorerPolicy {
    param([Parameter(Mandatory)][string]$HiveName)

    $explorerKey = "$HiveName\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    foreach ($valueName in @('NoClose', 'NoStartMenuSubItems')) {
        $result = Invoke-RegExe -RegArguments @(
            'add', $explorerKey, '/v', $valueName, '/t', 'REG_DWORD', '/d', '1', '/f'
        )
        if ($result.ExitCode -ne 0) {
            throw "reg add failed for ${explorerKey}\${valueName}: $($result.Output)"
        }
    }
}
