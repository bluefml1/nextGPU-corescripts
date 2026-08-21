#Requires -Version 5.1
<#
.SYNOPSIS
    Machine identity (ProgramData) + STATUS flag; domain.txt is identity-only.
#>

$script:NextGpuMachineProgramDataDir = Join-Path $env:ProgramData 'nextGPU'
$script:NextGpuMachineIdentityPath = Join-Path $script:NextGpuMachineProgramDataDir 'machine-identity.env'
$script:NextGpuMachineStatusFlagPath = Join-Path $script:NextGpuMachineProgramDataDir 'machine-status.flag'
$script:NextGpuValidStatuses = @('online', 'updating', 'update_fail')

function Get-NextGpuIdentityPath {
    return $script:NextGpuMachineIdentityPath
}

function Get-NextGpuStatusFlagPath {
    return $script:NextGpuMachineStatusFlagPath
}

function Ensure-NextGpuMachineProgramData {
    if (-not (Test-Path -LiteralPath $script:NextGpuMachineProgramDataDir)) {
        New-Item -ItemType Directory -Path $script:NextGpuMachineProgramDataDir -Force | Out-Null
    }
}

function Write-NextGpuAtomicTextFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Lines,
        [string]$Encoding = 'ASCII'
    )

    Ensure-NextGpuMachineProgramData
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $temp = "$Path.tmp.$PID"
    try {
        if ($Encoding -eq 'UTF8') {
            $Lines | Set-Content -LiteralPath $temp -Encoding UTF8
        }
        else {
            $Lines | Set-Content -LiteralPath $temp -Encoding ASCII
        }
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
    catch {
        if (Test-Path -LiteralPath $temp) {
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Resolve-NextGpuRepoRootForIdentity {
    param([string]$RepoRoot = '')

    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        return $RepoRoot.TrimEnd('\')
    }
    if (-not [string]::IsNullOrWhiteSpace($env:NEXTGPU_REPO_ROOT)) {
        return $env:NEXTGPU_REPO_ROOT.TrimEnd('\')
    }
    $marker = Join-Path $script:NextGpuMachineProgramDataDir 'repo-root.txt'
    if (Test-Path -LiteralPath $marker) {
        try {
            $marked = (Get-Content -LiteralPath $marker -Raw -ErrorAction Stop).Trim().TrimEnd('\')
            if ($marked) { return $marked }
        }
        catch { }
    }
    if ($PSScriptRoot) {
        return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
    }
    return $null
}

function Resolve-NextGpuDomainTxtPathForIdentity {
    param([string]$RepoRoot = '')

    $root = Resolve-NextGpuRepoRootForIdentity -RepoRoot $RepoRoot
    if ($root) {
        return (Join-Path $root 'domain.txt')
    }
    $programDataCopy = Join-Path $script:NextGpuMachineProgramDataDir 'domain.txt'
    if (Test-Path -LiteralPath $programDataCopy) {
        return $programDataCopy
    }
    return $null
}

function ConvertFrom-NextGpuEnvFile {
    param([string]$Path)

    $map = [ordered]@{
        DOMAIN             = ''
        PUBLIC_IP          = ''
        COMPUTER_NAME      = ''
        VENDOR_ID          = ''
        VENDOR_ID_ENABLED  = ''
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return $map
    }
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -notmatch '=') { continue }
        $idx = $line.IndexOf('=')
        $key = $line.Substring(0, $idx).Trim().ToUpperInvariant()
        $val = $line.Substring($idx + 1).Trim().Trim([char]0xFEFF, [char]0x200B)
        if ($map.Contains($key)) {
            $map[$key] = $val
        }
    }
    return $map
}

function ConvertTo-NextGpuIdentityLines {
    param($Identity)

    $vendorEnabled = [string]$Identity.VENDOR_ID_ENABLED
    if ([string]::IsNullOrWhiteSpace($vendorEnabled)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Identity.VENDOR_ID)) {
            $vendorEnabled = 'yes'
        }
        else {
            $vendorEnabled = 'no'
        }
    }

    return @(
        "DOMAIN=$([string]$Identity.DOMAIN)"
        "PUBLIC_IP=$([string]$Identity.PUBLIC_IP)"
        "COMPUTER_NAME=$([string]$Identity.COMPUTER_NAME)"
        "VENDOR_ID=$([string]$Identity.VENDOR_ID)"
        "VENDOR_ID_ENABLED=$vendorEnabled"
    )
}

function Read-NextGpuDomainTxtIdentity {
    param([string]$DomainPath)

    $map = [ordered]@{
        DOMAIN            = ''
        PUBLIC_IP         = ''
        COMPUTER_NAME     = ''
        VENDOR_ID         = ''
        VENDOR_ID_ENABLED = ''
        STATUS            = ''
    }
    if (-not $DomainPath -or -not (Test-Path -LiteralPath $DomainPath)) {
        return $map
    }
    foreach ($line in Get-Content -LiteralPath $DomainPath -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*DOMAIN\s*=\s*(.*)\s*$') { $map.DOMAIN = $Matches[1].Trim() }
        elseif ($line -match '^\s*PUBLIC_IP\s*=\s*(.*)\s*$') { $map.PUBLIC_IP = $Matches[1].Trim() }
        elseif ($line -match '^\s*COMPUTER_NAME\s*=\s*(.*)\s*$') { $map.COMPUTER_NAME = $Matches[1].Trim() }
        elseif ($line -match '^\s*VENDOR_ID_ENABLED\s*=\s*(.*)\s*$') { $map.VENDOR_ID_ENABLED = $Matches[1].Trim() }
        elseif ($line -match '^\s*VENDOR_ID\s*=\s*(.*)\s*$') { $map.VENDOR_ID = $Matches[1].Trim() }
        elseif ($line -match '^\s*STATUS\s*=\s*(.*)\s*$') { $map.STATUS = $Matches[1].Trim() }
    }
    return $map
}

function Save-NextGpuMachineIdentity {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$PublicIp,
        [string]$Domain = '',
        [string]$VendorId = '',
        [string]$VendorIdEnabled = ''
    )

    $computerName = $ComputerName.Trim()
    $publicIp = $PublicIp.Trim()
    if ([string]::IsNullOrWhiteSpace($computerName) -or [string]::IsNullOrWhiteSpace($publicIp)) {
        throw 'COMPUTER_NAME and PUBLIC_IP are required to save machine identity.'
    }

    $vendorEnabled = $VendorIdEnabled.Trim()
    if ([string]::IsNullOrWhiteSpace($vendorEnabled)) {
        $vendorEnabled = if (-not [string]::IsNullOrWhiteSpace($VendorId)) { 'yes' } else { 'no' }
    }

    $identity = [ordered]@{
        DOMAIN            = $Domain.Trim()
        PUBLIC_IP         = $publicIp
        COMPUTER_NAME     = $computerName
        VENDOR_ID         = $VendorId.Trim()
        VENDOR_ID_ENABLED = $vendorEnabled
    }

    $lines = @(
        '# nextGPU machine identity — do not put STATUS here.'
    ) + (ConvertTo-NextGpuIdentityLines -Identity $identity)

    Write-NextGpuAtomicTextFile -Path $script:NextGpuMachineIdentityPath -Lines $lines -Encoding ASCII
    return $identity
}

function Read-NextGpuMachineIdentity {
    param(
        [string]$RepoRoot = '',
        [switch]$NoMigrate
    )

    if (Test-Path -LiteralPath $script:NextGpuMachineIdentityPath) {
        $identity = ConvertFrom-NextGpuEnvFile -Path $script:NextGpuMachineIdentityPath
        if (-not [string]::IsNullOrWhiteSpace([string]$identity.COMPUTER_NAME) -and
            -not [string]::IsNullOrWhiteSpace([string]$identity.PUBLIC_IP)) {
            return $identity
        }
    }

    if ($NoMigrate) {
        return [ordered]@{
            DOMAIN            = ''
            PUBLIC_IP         = ''
            COMPUTER_NAME     = ''
            VENDOR_ID         = ''
            VENDOR_ID_ENABLED = ''
        }
    }

    $domainPath = Resolve-NextGpuDomainTxtPathForIdentity -RepoRoot $RepoRoot
    $fromDomain = Read-NextGpuDomainTxtIdentity -DomainPath $domainPath
    if ([string]::IsNullOrWhiteSpace([string]$fromDomain.COMPUTER_NAME) -or
        [string]::IsNullOrWhiteSpace([string]$fromDomain.PUBLIC_IP)) {
        return $fromDomain
    }

    return Save-NextGpuMachineIdentity `
        -ComputerName $fromDomain.COMPUTER_NAME `
        -PublicIp $fromDomain.PUBLIC_IP `
        -Domain $fromDomain.DOMAIN `
        -VendorId $fromDomain.VENDOR_ID `
        -VendorIdEnabled $fromDomain.VENDOR_ID_ENABLED
}

function Write-NextGpuDomainTxtFromIdentity {
    param(
        [string]$RepoRoot = '',
        [hashtable]$Identity = $null,
        [switch]$PublishProgramDataCopy
    )

    if ($null -eq $Identity) {
        $Identity = Read-NextGpuMachineIdentity -RepoRoot $RepoRoot
    }
    if ([string]::IsNullOrWhiteSpace([string]$Identity.COMPUTER_NAME) -or
        [string]::IsNullOrWhiteSpace([string]$Identity.PUBLIC_IP)) {
        throw 'Cannot write domain.txt: identity missing COMPUTER_NAME or PUBLIC_IP.'
    }

    $domainPath = Resolve-NextGpuDomainTxtPathForIdentity -RepoRoot $RepoRoot
    if (-not $domainPath) {
        throw 'Cannot resolve domain.txt path (set NEXTGPU_REPO_ROOT or repo-root.txt).'
    }

    $lines = ConvertTo-NextGpuIdentityLines -Identity $Identity
    Write-NextGpuAtomicTextFile -Path $domainPath -Lines $lines -Encoding UTF8

    if ($PublishProgramDataCopy) {
        $userStorage = Join-Path $PSScriptRoot 'UserStorageCommon.ps1'
        if (Test-Path -LiteralPath $userStorage) {
            . $userStorage
            $root = Resolve-NextGpuRepoRootForIdentity -RepoRoot $RepoRoot
            if ($root) {
                $null = Publish-NextGpuDomainForRentalUser -RepoRoot $root
            }
        }
        else {
            $copyPath = Join-Path $script:NextGpuMachineProgramDataDir 'domain.txt'
            Write-NextGpuAtomicTextFile -Path $copyPath -Lines $lines -Encoding UTF8
        }
    }

    return $domainPath
}

function Repair-NextGpuDomainTxtIfNeeded {
    param([string]$RepoRoot = '')

    $identity = Read-NextGpuMachineIdentity -RepoRoot $RepoRoot
    if ([string]::IsNullOrWhiteSpace([string]$identity.COMPUTER_NAME) -or
        [string]::IsNullOrWhiteSpace([string]$identity.PUBLIC_IP)) {
        return $false
    }

    $domainPath = Resolve-NextGpuDomainTxtPathForIdentity -RepoRoot $RepoRoot
    $needsRewrite = $false
    if (-not $domainPath -or -not (Test-Path -LiteralPath $domainPath)) {
        $needsRewrite = $true
    }
    else {
        $existing = Read-NextGpuDomainTxtIdentity -DomainPath $domainPath
        if ([string]::IsNullOrWhiteSpace([string]$existing.COMPUTER_NAME) -or
            [string]::IsNullOrWhiteSpace([string]$existing.PUBLIC_IP)) {
            $needsRewrite = $true
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$existing.STATUS)) {
            # Strip legacy STATUS= from domain.txt
            $needsRewrite = $true
        }
    }

    if ($needsRewrite) {
        $null = Write-NextGpuDomainTxtFromIdentity -RepoRoot $RepoRoot -Identity $identity -PublishProgramDataCopy
        return $true
    }
    return $false
}

function Get-NextGpuMachineStatus {
    param(
        [string]$RepoRoot = '',
        [switch]$NoMigrate
    )

    if (Test-Path -LiteralPath $script:NextGpuMachineStatusFlagPath) {
        try {
            $raw = (Get-Content -LiteralPath $script:NextGpuMachineStatusFlagPath -Raw -ErrorAction Stop).Trim()
            $status = ($raw -split '\r?\n')[0].Trim().ToLowerInvariant()
            if ($script:NextGpuValidStatuses -contains $status) {
                return $status
            }
        }
        catch { }
    }

    if (-not $NoMigrate) {
        $domainPath = Resolve-NextGpuDomainTxtPathForIdentity -RepoRoot $RepoRoot
        $fromDomain = Read-NextGpuDomainTxtIdentity -DomainPath $domainPath
        $legacy = ([string]$fromDomain.STATUS).Trim().ToLowerInvariant()
        if ($script:NextGpuValidStatuses -contains $legacy) {
            Set-NextGpuMachineStatus -Status $legacy
            return $legacy
        }
    }

    return 'online'
}

function Set-NextGpuMachineStatus {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('online', 'updating', 'update_fail')]
        [string]$Status
    )

    $value = $Status.Trim().ToLowerInvariant()
    Write-NextGpuAtomicTextFile -Path $script:NextGpuMachineStatusFlagPath -Lines @($value) -Encoding ASCII
    return $value
}
