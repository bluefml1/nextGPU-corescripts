#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Restrict shutdown/restart to NextGPU-Authority only (nextGPU and other users blocked).
.DESCRIPTION
    - User rights: SeShutdownPrivilege / SeRemoteShutdownPrivilege for LOCAL SYSTEM + NextGPU-Authority only
    - User GPO registry.pol: Explorer NoClose for standard users
    - Logon scheduled task: clears UI block for NextGPU-Authority each sign-in
#>
[CmdletBinding()]
param(
    [string]$ScriptDir = '',
    [string]$AuthorityAccountName = 'NextGPU-Authority',
    [switch]$SkipScheduledTask
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $localScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
    $ScriptDir = if ($env:NEXTGPU_REPO_ROOT) {
        $env:NEXTGPU_REPO_ROOT
    } else {
        (Resolve-Path (Join-Path $localScriptDir '..\..')).Path
    }
}

$defaultUserHivePath = Join-Path $PSScriptRoot 'DefaultUserHive.ps1'
if (-not (Test-Path -LiteralPath $defaultUserHivePath)) {
    throw "Required helper not found: $defaultUserHivePath (copy scripts\desktop\DefaultUserHive.ps1 next to Set-ShutdownPolicy.ps1)"
}
. $defaultUserHivePath

function Write-Log([string]$Message) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
}

#region registry.pol (same format as Set-DesktopWallpaper-Gpo.ps1)
enum RegType {
    REG_NONE = 0
    REG_SZ = 1
    REG_EXPAND_SZ = 2
    REG_BINARY = 3
    REG_DWORD = 4
    REG_MULTI_SZ = 7
    REG_QWORD = 11
}

class GPRegistryPolicyEntry {
    [string]$KeyName
    [string]$ValueName
    [RegType]$ValueType
    [object]$ValueData

    GPRegistryPolicyEntry([string]$KeyName, [string]$ValueName, [RegType]$ValueType, [object]$ValueData) {
        $this.KeyName = $KeyName
        $this.ValueName = $ValueName
        $this.ValueType = $ValueType
        $this.ValueData = $ValueData
    }
}

function New-RegistryPolEntryBytes {
    param([GPRegistryPolicyEntry]$Entry)
    $bytes = New-Object System.Collections.Generic.List[byte]
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes('['))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes($Entry.KeyName + [char]0))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes($Entry.ValueName + [char]0))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    [void]$bytes.AddRange([System.BitConverter]::GetBytes([int32]$Entry.ValueType))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))

    switch ($Entry.ValueType) {
        { @([RegType]::REG_SZ, [RegType]::REG_EXPAND_SZ, [RegType]::REG_MULTI_SZ) -contains $_ } {
            $dataBytes = [System.Text.Encoding]::Unicode.GetBytes([string]$Entry.ValueData + [char]0)
            $dataSize = $dataBytes.Length
        }
        ([RegType]::REG_DWORD) {
            $dataBytes = [System.BitConverter]::GetBytes([int32]$Entry.ValueData)
            $dataSize = 4
        }
        default {
            $dataBytes = [byte[]]@()
            $dataSize = 0
        }
    }

    [void]$bytes.AddRange([System.BitConverter]::GetBytes($dataSize))
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(';'))
    if ($dataSize -gt 0) { [void]$bytes.AddRange($dataBytes) }
    [void]$bytes.AddRange([System.Text.Encoding]::Unicode.GetBytes(']'))
    return $bytes.ToArray()
}

function Read-RegistryPolFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }

    $raw = [System.IO.File]::ReadAllBytes($Path)
    if ($raw.Length -lt 8) { return @() }

    $sig = [System.Text.Encoding]::ASCII.GetString($raw, 0, 4)
    if ($sig -ne 'PReg') { throw "Invalid registry.pol header in $Path" }

    $entries = New-Object System.Collections.Generic.List[object]
    $index = 8
    while ($index -lt $raw.Length - 2) {
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne '[') { break }
        $index += 2

        $semi = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ';') { $semi = $i; break }
        }
        if ($semi -lt 0) { break }
        $keyName = [System.Text.Encoding]::Unicode.GetString($raw, $index, $semi - $index)
        $index = $semi + 2

        $semi = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ';') { $semi = $i; break }
        }
        if ($semi -lt 0) { break }
        $valueName = [System.Text.Encoding]::Unicode.GetString($raw, $index, $semi - $index)
        $index = $semi + 2

        $valueType = [System.BitConverter]::ToInt32($raw, $index)
        $index += 4
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne ';') { break }
        $index += 2

        $valueLength = [System.BitConverter]::ToInt32($raw, $index)
        $index += 4
        if ([char][System.BitConverter]::ToUInt16($raw, $index) -ne ';') { break }
        $index += 2

        $valueData = $null
        if ($valueLength -gt 0 -and $valueType -eq [RegType]::REG_SZ) {
            $valueData = [System.Text.Encoding]::Unicode.GetString($raw, $index, $valueLength - 2)
            $index += $valueLength
        }
        elseif ($valueType -eq [RegType]::REG_DWORD) {
            $valueData = [System.BitConverter]::ToInt32($raw, $index)
            $index += 4
        }

        $close = -1
        for ($i = $index; $i -lt $raw.Length - 1; $i += 2) {
            if ([char][System.BitConverter]::ToUInt16($raw, $i) -eq ']') { $close = $i; break }
        }
        if ($close -lt 0) { break }
        $index = $close + 2

        if ($valueName) {
            $entries.Add([GPRegistryPolicyEntry]::new($keyName, $valueName, [RegType]$valueType, $valueData))
        }
    }
    return $entries.ToArray()
}

function Write-RegistryPolFile {
    param(
        [string]$Path,
        [GPRegistryPolicyEntry[]]$Entries
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([uint32]0x67655250)
    $bw.Write([uint32]1)
    foreach ($entry in $Entries) {
        $bw.Write((New-RegistryPolEntryBytes -Entry $entry))
    }
    $bw.Close()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
}

function Update-UserRegistryPol {
    param(
        [string]$PolPath,
        [string]$PolicyKey,
        [string[]]$ReplaceValueNames,
        [GPRegistryPolicyEntry[]]$PolicyValues
    )
    $existing = @(Read-RegistryPolFile -Path $PolPath)
    $kept = @($existing | Where-Object {
        -not ($_.KeyName -eq $PolicyKey -and $ReplaceValueNames -contains $_.ValueName)
    })
    $merged = @($kept) + @($PolicyValues)
    Write-RegistryPolFile -Path $PolPath -Entries $merged
}
#endregion

function Set-ShutdownUserRights {
    param([string]$AuthoritySid)

    $cfgPath = Join-Path $env:TEMP ("nextgpu_secexport_{0}.inf" -f [guid]::NewGuid().ToString('n'))
    $dbPath = Join-Path $env:TEMP ("nextgpu_secdb_{0}.sdb" -f [guid]::NewGuid().ToString('n'))

    Write-Log "Exporting security policy..."
    $export = Start-Process -FilePath 'secedit.exe' -ArgumentList @('/export', '/cfg', $cfgPath, '/quiet') -Wait -PassThru -WindowStyle Hidden
    if ($export.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $cfgPath)) {
        throw "secedit /export failed (exit $($export.ExitCode))"
    }

    $allowed = @('*S-1-5-18', "*$AuthoritySid")
    $privilegeValue = ($allowed -join ',')

    $lines = Get-Content -LiteralPath $cfgPath -Encoding Unicode
    $output = New-Object System.Collections.Generic.List[string]
    $inPrivilege = $false
    $shutdownSet = $false
    $remoteSet = $false

    foreach ($line in $lines) {
        if ($line -match '^\s*\[Privilege Rights\]') {
            $inPrivilege = $true
            [void]$output.Add($line)
            continue
        }
        if ($inPrivilege -and $line -match '^\s*\[') {
            if (-not $shutdownSet) { [void]$output.Add("SeShutdownPrivilege = $privilegeValue") }
            if (-not $remoteSet) { [void]$output.Add("SeRemoteShutdownPrivilege = $privilegeValue") }
            $inPrivilege = $false
        }

        if ($inPrivilege -and $line -match '^\s*SeShutdownPrivilege\s*=') {
            [void]$output.Add("SeShutdownPrivilege = $privilegeValue")
            $shutdownSet = $true
            continue
        }
        if ($inPrivilege -and $line -match '^\s*SeRemoteShutdownPrivilege\s*=') {
            [void]$output.Add("SeRemoteShutdownPrivilege = $privilegeValue")
            $remoteSet = $true
            continue
        }

        [void]$output.Add($line)
    }

    if (-not $shutdownSet) {
        [void]$output.Add('')
        [void]$output.Add('[Privilege Rights]')
        [void]$output.Add("SeShutdownPrivilege = $privilegeValue")
        [void]$output.Add("SeRemoteShutdownPrivilege = $privilegeValue")
    }

    Set-Content -LiteralPath $cfgPath -Value $output -Encoding Unicode

    Write-Log "Applying shutdown privileges: $privilegeValue"
    if (Test-Path -LiteralPath $dbPath) { Remove-Item -LiteralPath $dbPath -Force }
    $configure = Start-Process -FilePath 'secedit.exe' -ArgumentList @(
        '/configure', '/db', $dbPath, '/cfg', $cfgPath, '/areas', 'USER_RIGHTS'
    ) -Wait -PassThru -WindowStyle Hidden
    if ($configure.ExitCode -ne 0) {
        throw "secedit /configure failed (exit $($configure.ExitCode))"
    }

    try { Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath $dbPath -Force -ErrorAction SilentlyContinue } catch {}
}

function Register-ShutdownLogonTask {
    param([string]$LogonScriptPath)

    $taskName = 'nextGPU-ShutdownPolicyLogon'
    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    $psArgs = "-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LogonScriptPath`" -AuthorityAccountName `"$AuthorityAccountName`""
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -GroupId 'Users' -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Log "Registered scheduled task: $taskName"
}

function Set-ExplorerShutdownPolicyHive {
    param(
        [string]$HiveRoot,
        [bool]$BlockShutdown
    )
    $regPath = Join-Path $HiveRoot 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
    if (-not (Test-Path -LiteralPath $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    if ($BlockShutdown) {
        Set-ItemProperty -LiteralPath $regPath -Name 'NoClose' -Value 1 -Type DWord -Force
        Set-ItemProperty -LiteralPath $regPath -Name 'NoStartMenuSubItems' -Value 1 -Type DWord -Force
    } else {
        Remove-ItemProperty -LiteralPath $regPath -Name 'NoClose' -ErrorAction SilentlyContinue
        Remove-ItemProperty -LiteralPath $regPath -Name 'NoStartMenuSubItems' -ErrorAction SilentlyContinue
    }
}

# --- main ---
Write-Log "NextGPU shutdown policy (authority: $AuthorityAccountName)"

$authority = Get-LocalUser -Name $AuthorityAccountName -ErrorAction Stop
$authoritySid = $authority.Sid.Value
Write-Log "Authority SID: $authoritySid"

Set-ShutdownUserRights -AuthoritySid $authoritySid

$policyKey = 'Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$userPolPath = Join-Path $env:SystemRoot 'System32\GroupPolicy\User\registry.pol'
$policyValues = @(
    [GPRegistryPolicyEntry]::new($policyKey, 'NoClose', [RegType]::REG_DWORD, 1)
    [GPRegistryPolicyEntry]::new($policyKey, 'NoStartMenuSubItems', [RegType]::REG_DWORD, 1)
)
Update-UserRegistryPol -PolPath $userPolPath -PolicyKey $policyKey -ReplaceValueNames @('NoClose', 'NoStartMenuSubItems') -PolicyValues $policyValues
Write-Log "Updated User registry.pol (shutdown UI restrictions)"

Write-Log 'Running gpupdate /force /target:user ...'
$null = & gpupdate.exe /force /target:user 2>&1

if ($env:USERNAME -ieq $AuthorityAccountName) {
    Set-ExplorerShutdownPolicyHive -HiveRoot 'HKCU:' -BlockShutdown $false
} else {
    Set-ExplorerShutdownPolicyHive -HiveRoot 'HKCU:' -BlockShutdown $true
}

Write-Log 'Applying block to Default user profile (new accounts)...'
$defaultResult = Invoke-DefaultUserNtuserScript -HiveName 'HKU\NextGPUShutdownDefault' -ApplyKeys {
    param($HiveName)
    Set-DefaultUserShutdownExplorerPolicy -HiveName $HiveName
}
if (-not $defaultResult.Loaded -and $defaultResult.Message) {
    Write-Warning "Default user shutdown keys skipped: $($defaultResult.Message) registry.pol and logon task still apply."
}

$logonScript = Join-Path $ScriptDir 'scripts\desktop\Apply-ShutdownPolicy-Logon.ps1'
if (-not (Test-Path -LiteralPath $logonScript)) {
    $logonScript = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Apply-ShutdownPolicy-Logon.ps1'
}

if (-not $SkipScheduledTask) {
    if (Test-Path -LiteralPath $logonScript) {
        Register-ShutdownLogonTask -LogonScriptPath $logonScript
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $logonScript -AuthorityAccountName $AuthorityAccountName
    } else {
        Write-Warning "Logon script not found: $logonScript"
    }
}

Write-Log 'Done. Only NextGPU-Authority may shut down or restart (plus SYSTEM).'
Write-Log 'nextGPU and other non-authority users: shutdown/restart blocked via user rights and Start menu policy.'
exit 0
