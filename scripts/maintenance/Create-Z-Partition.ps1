#Requires -RunAsAdministrator
#Requires -Version 5.1
<#
.SYNOPSIS
    Shrink a source volume and extend an existing target or create a new partition.
.DESCRIPTION
    Choose source drive (e.g. C:), size to take (GB), then either:
    - Extend an existing volume on the same disk (e.g. shrink C:, add to existing Z:)
    - Create a new partition with a new drive letter
    Extend only works when the target partition is immediately after the shrunk space on disk.
#>
[CmdletBinding()]
param(
    [string]$SourceDriveLetter = '',
    [string]$TargetDriveLetter = '',
    [ValidateSet('', 'Extend', 'Create')]
    [string]$TargetMode = '',
    [int]$NewPartitionSizeGB = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName Microsoft.VisualBasic

function Format-GB([int64]$bytes) {
    return '{0:N2}' -f ($bytes / 1GB)
}

function Get-FixedLetterVolumes {
    $result = @()
    $vols = Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter } | Sort-Object DriveLetter
    foreach ($v in $vols) {
        $part = Get-Partition -DriveLetter $v.DriveLetter -ErrorAction SilentlyContinue
        $result += [pscustomobject]@{
            DriveLetter = $v.DriveLetter.ToString().ToUpperInvariant()
            Size        = [int64]$v.Size
            Free        = [int64]$v.SizeRemaining
            Label       = if ($v.FileSystemLabel) { $v.FileSystemLabel } else { '' }
            DiskNumber  = if ($part) { $part.DiskNumber } else { -1 }
            Partition   = $part
        }
    }
    return $result
}

function Prompt-SourceDrive($vols) {
    $lines = $vols | ForEach-Object {
        '{0}:  free {1} GB / total {2} GB  disk {3}  {4}' -f $_.DriveLetter, (Format-GB $_.Free), (Format-GB $_.Size), $_.DiskNumber, $_.Label
    }
    $pick = [Microsoft.VisualBasic.Interaction]::InputBox(
        ("Choose source drive to SHRINK (take space from).`nExamples: C for OS, Z for data.`n`n" + ($lines -join "`n")),
        'NextGPU Disk Management',
        $vols[0].DriveLetter
    )
    if ([string]::IsNullOrWhiteSpace($pick)) { return $null }
    return $pick.Trim().TrimEnd(':').ToUpperInvariant()
}

function Prompt-TargetMode {
    $r = [System.Windows.Forms.MessageBox]::Show(
        @(
            'What should happen with the freed space?',
            '',
            'YES  = Extend an EXISTING volume (e.g. shrink C:, add to existing Z:)',
            'NO   = Create a NEW partition with a new drive letter',
            '',
            'Note: Extend only works when the target volume is the next partition on the same disk after the source.'
        ) -join [Environment]::NewLine,
        'NextGPU Disk Management',
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    switch ($r) {
        ([System.Windows.Forms.DialogResult]::Yes) { return 'Extend' }
        ([System.Windows.Forms.DialogResult]::No) { return 'Create' }
        default { return $null }
    }
}

function Get-ExtendCandidates {
    param(
        [Microsoft.Management.Infrastructure.CimInstance]$SourcePart,
        [int64]$ShrinkBytes
    )
    $newSourceSize = [int64]$SourcePart.Size - $ShrinkBytes
    if ($newSourceSize -le 0) { return @() }

    $unallocStart = [int64]$SourcePart.Offset + $newSourceSize
    $diskNum = $SourcePart.DiskNumber
    $parts = @(Get-Partition -DiskNumber $diskNum -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -and $_.DriveLetter -ne $SourcePart.DriveLetter })

    $matched = @($parts | Where-Object { [int64]$_.Offset -eq $unallocStart })
    foreach ($p in $matched) {
        $vol = Get-Volume -DriveLetter $p.DriveLetter -ErrorAction SilentlyContinue
        [pscustomobject]@{
            DriveLetter = $p.DriveLetter.ToString().ToUpperInvariant()
            Offset      = $p.Offset
            Size        = [int64]$p.Size
            Free        = if ($vol) { [int64]$vol.SizeRemaining } else { 0 }
            Label       = if ($vol -and $vol.FileSystemLabel) { $vol.FileSystemLabel } else { '' }
            Partition   = $p
        }
    }
}

function Prompt-ExtendTarget {
    param([object[]]$Candidates, [string]$DefaultLetter = '')

    if ($Candidates.Count -eq 1) {
        $only = $Candidates[0].DriveLetter
        $auto = [System.Windows.Forms.MessageBox]::Show(
            ("Only one eligible volume to extend: {0}:`n`nUse this target?" -f $only),
            'NextGPU Disk Management',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )
        if ($auto -eq [System.Windows.Forms.DialogResult]::Yes) { return $only }
        return $null
    }

    $lines = $Candidates | ForEach-Object {
        '{0}:  total {1} GB, free {2} GB  {3}' -f $_.DriveLetter, (Format-GB $_.Size), (Format-GB $_.Free), $_.Label
    }
    $def = if ($DefaultLetter) { $DefaultLetter } else { $Candidates[0].DriveLetter }
    $pick = [Microsoft.VisualBasic.Interaction]::InputBox(
        ("Choose volume to EXTEND (must be next to freed space on disk).`n`n" + ($lines -join "`n")),
        'NextGPU Disk Management',
        $def
    )
    if ([string]::IsNullOrWhiteSpace($pick)) { return $null }
    return $pick.Trim().TrimEnd(':').ToUpperInvariant()
}

function Prompt-NewDriveLetter {
    param([string[]]$InUseLetters)

    $suggestions = @('H', 'G', 'F', 'E', 'D', 'Y', 'X', 'W')
    $firstFree = $suggestions | Where-Object { $InUseLetters -notcontains $_ } | Select-Object -First 1
    if (-not $firstFree) { $firstFree = 'H' }

    $pick = [Microsoft.VisualBasic.Interaction]::InputBox(
        ("Enter NEW drive letter (single letter).`nIn use: {0}" -f ($InUseLetters -join ', ')),
        'NextGPU Disk Management',
        $firstFree
    )
    if ([string]::IsNullOrWhiteSpace($pick)) { return $null }
    return $pick.Trim().TrimEnd(':').ToUpperInvariant()
}

function Get-ShrinkStats {
    param(
        [Microsoft.Management.Infrastructure.CimInstance]$Partition,
        [int64]$VolumeFreeBytes
    )
    $supported = Get-PartitionSupportedSize -DriveLetter $Partition.DriveLetter
    $sizeMin = [int64]$supported.SizeMin
    $sizeMax = [int64]$supported.SizeMax
    $current = [int64]$Partition.Size
    $maxShrinkBytes = [math]::Max(0, $current - $sizeMin)
    $maxShrinkGb = [int][math]::Floor($maxShrinkBytes / 1GB)
    [pscustomobject]@{
        CurrentSizeGb   = [math]::Round($current / 1GB, 2)
        VolumeFreeGb    = [math]::Round($VolumeFreeBytes / 1GB, 2)
        MinSizeGb       = [math]::Round($sizeMin / 1GB, 2)
        MaxShrinkGb     = $maxShrinkGb
        MaxShrinkBytes  = $maxShrinkBytes
        SizeMin         = $sizeMin
        SizeMax         = $sizeMax
    }
}

function Show-ShrinkCapacityInfo {
    param(
        [string]$DriveLetter,
        [pscustomobject]$Stats
    )
    Write-Host ''
    Write-Host ('Drive {0}: capacity' -f $DriveLetter) -ForegroundColor Cyan
    Write-Host ('  Partition total:     {0} GB' -f $Stats.CurrentSizeGb)
    Write-Host ('  Explorer free:       {0} GB  (not the same as shrinkable!)' -f $Stats.VolumeFreeGb) -ForegroundColor Yellow
    Write-Host ('  Windows max shrink:  {0} GB  (limited by files at end of volume)' -f $Stats.MaxShrinkGb) -ForegroundColor Green
    Write-Host ('  Smallest allowed:    {0} GB' -f $Stats.MinSizeGb)
    Write-Host ''
}

function Show-ShrinkFailureHints {
    Write-Host '[FAIL] Resize-Partition failed.' -ForegroundColor Red
    Write-Host '[HINT] Free space is NOT shrinkable space. Windows must move files at the end of C:.' -ForegroundColor Yellow
    Write-Host '[HINT] Try (as Admin), then reboot and rerun:' -ForegroundColor Yellow
    Write-Host '  powercfg -h off' -ForegroundColor Yellow
    Write-Host '  Disable System Restore on C: (optional)' -ForegroundColor Yellow
    Write-Host '  Move pagefile off C: or set smaller pagefile, reboot' -ForegroundColor Yellow
    Write-Host '  Disk Cleanup + Defrag/Optimize C: (retrim)' -ForegroundColor Yellow
}

function Offer-ShrinkPrep {
    $r = [System.Windows.Forms.MessageBox]::Show(
        @(
            'Shrinkable space is much smaller than Explorer free space.',
            '',
            'Run quick prep now?',
            '  - Disable hibernation (powercfg -h off)',
            '',
            'Then reboot and run this tool again for a larger shrink.'
        ) -join [Environment]::NewLine,
        'NextGPU Disk Management',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Write-Host '[*] Disabling hibernation...' -ForegroundColor Cyan
    & powercfg.exe -h off
    Write-Host '[OK] Hibernation disabled. Reboot, then retry partition shrink.' -ForegroundColor Green
}

function Resolve-ShrinkSizeGb {
    param(
        [string]$DriveLetter,
        [pscustomobject]$Stats,
        [int]$RequestedGb
    )
    $max = $Stats.MaxShrinkGb
    if ($max -lt 20) {
        Show-ShrinkCapacityInfo -DriveLetter $DriveLetter -Stats $Stats
        Offer-ShrinkPrep
        throw ('Only about {0} GB can be taken from {1}:. Run prep steps, reboot, then retry.' -f $max, $DriveLetter)
    }

    if ($RequestedGb -le $max) { return $RequestedGb }

    Show-ShrinkCapacityInfo -DriveLetter $DriveLetter -Stats $Stats
    $msg = @(
        ('You asked for {0} GB but Windows only allows about {1} GB from {2}:.' -f $RequestedGb, $max, $DriveLetter),
        ('Explorer shows {0} GB free, but immovable files block most of that.' -f $Stats.VolumeFreeGb),
        '',
        ('Use maximum shrinkable size ({0} GB) instead?' -f $max)
    ) -join [Environment]::NewLine

    $useMax = [System.Windows.Forms.MessageBox]::Show(
        $msg,
        'NextGPU Disk Management',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    if ($useMax -eq [System.Windows.Forms.DialogResult]::Yes) { return $max }

    $offerPrep = [System.Windows.Forms.MessageBox]::Show(
        'Show steps to increase shrinkable space (disable hibernation now)?',
        'NextGPU Disk Management',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($offerPrep -eq [System.Windows.Forms.DialogResult]::Yes) { Offer-ShrinkPrep }
    throw ('Cancelled: requested {0} GB but max shrinkable is {1} GB.' -f $RequestedGb, $max)
}

Write-Host '=== NextGPU Disk: Shrink + Extend or Create ===' -ForegroundColor Cyan

$vols = @(Get-FixedLetterVolumes)
if ($vols.Count -eq 0) { throw 'No fixed lettered volumes found.' }

$inUse = @($vols | ForEach-Object { $_.DriveLetter })

$source = $SourceDriveLetter
if ([string]::IsNullOrWhiteSpace($source)) {
    $source = Prompt-SourceDrive -vols $vols
}
if ([string]::IsNullOrWhiteSpace($source)) {
    Write-Host '[*] Cancelled.' -ForegroundColor Yellow
    exit 0
}
$source = $source.Trim().TrimEnd(':').ToUpperInvariant()

$srcVol = $vols | Where-Object { $_.DriveLetter -eq $source } | Select-Object -First 1
if (-not $srcVol) { throw ('Source drive {0}: not found.' -f $source) }

$srcPart = Get-Partition -DriveLetter $source -ErrorAction Stop
$shrinkStats = Get-ShrinkStats -Partition $srcPart -VolumeFreeBytes $srcVol.Free
Show-ShrinkCapacityInfo -DriveLetter $source -Stats $shrinkStats

if ($NewPartitionSizeGB -le 0) {
    $defaultGb = [math]::Min(200, $shrinkStats.MaxShrinkGb)
    if ($defaultGb -lt 20) { $defaultGb = $shrinkStats.MaxShrinkGb }
    $sizeInput = [Microsoft.VisualBasic.Interaction]::InputBox(
        @(
            ('How many GB to take from {0}: ?' -f $source),
            ('Explorer free: {0} GB' -f $shrinkStats.VolumeFreeGb),
            ('Max shrinkable now: {0} GB (Windows limit)' -f $shrinkStats.MaxShrinkGb),
            'Minimum request: 20 GB'
        ) -join [Environment]::NewLine,
        'NextGPU Disk Management',
        [string]$defaultGb
    )
    if ([string]::IsNullOrWhiteSpace($sizeInput)) {
        Write-Host '[*] Cancelled.' -ForegroundColor Yellow
        exit 0
    }
    if (-not [int]::TryParse($sizeInput.Trim(), [ref]$NewPartitionSizeGB)) {
        throw 'Invalid size (enter a whole number of GB).'
    }
}

if ($NewPartitionSizeGB -lt 20) {
    throw 'Size must be at least 20 GB.'
}

$NewPartitionSizeGB = Resolve-ShrinkSizeGb -DriveLetter $source -Stats $shrinkStats -RequestedGb $NewPartitionSizeGB
$shrinkStats = Get-ShrinkStats -Partition $srcPart -VolumeFreeBytes $srcVol.Free

$shrinkBytes = [int64]$NewPartitionSizeGB * 1GB
$targetSourceSize = [int64]$srcPart.Size - $shrinkBytes

if ($targetSourceSize -lt [int64]$shrinkStats.SizeMin) {
    throw ('Cannot shrink {0}: by {1} GB. Maximum is about {2} GB.' -f $source, $NewPartitionSizeGB, $shrinkStats.MaxShrinkGb)
}

$mode = $TargetMode
if ([string]::IsNullOrWhiteSpace($mode)) {
    $mode = Prompt-TargetMode
}
if ([string]::IsNullOrWhiteSpace($mode)) {
    Write-Host '[*] Cancelled.' -ForegroundColor Yellow
    exit 0
}

$extendCandidates = @(Get-ExtendCandidates -SourcePart $srcPart -ShrinkBytes $shrinkBytes)
$targetLetter = $TargetDriveLetter.Trim().TrimEnd(':').ToUpperInvariant()

if ($mode -eq 'Extend') {
    if ($extendCandidates.Count -eq 0) {
        $warn = [System.Windows.Forms.MessageBox]::Show(
            @(
                ('No volume on disk {0} is directly after {1}: after shrinking.' -f $srcPart.DiskNumber, $source),
                '',
                'You can still try a specific letter, or switch to Create new partition.',
                '',
                'Continue and enter target letter manually?'
            ) -join [Environment]::NewLine,
            'NextGPU Disk Management',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($warn -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Host '[*] Cancelled.' -ForegroundColor Yellow
            exit 0
        }
        if ([string]::IsNullOrWhiteSpace($targetLetter)) {
            $targetLetter = [Microsoft.VisualBasic.Interaction]::InputBox(
                'Enter drive letter to extend (e.g. Z)',
                'NextGPU Disk Management',
                'Z'
            )
            if ([string]::IsNullOrWhiteSpace($targetLetter)) { exit 0 }
            $targetLetter = $targetLetter.Trim().TrimEnd(':').ToUpperInvariant()
        }
        if ($targetLetter -eq $source) {
            throw ('Cannot extend {0}: - choose a different volume than the source.' -f $source)
        }
        if ($inUse -notcontains $targetLetter) {
            throw ('Drive {0}: does not exist. Use Create new partition instead.' -f $targetLetter)
        }
        $tgtPart = Get-Partition -DriveLetter $targetLetter -ErrorAction Stop
        if ($tgtPart.DiskNumber -ne $srcPart.DiskNumber) {
            throw ('{0}: is on disk {1}; source {2}: is on disk {3}. Must be same disk.' -f $targetLetter, $tgtPart.DiskNumber, $source, $srcPart.DiskNumber)
        }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($targetLetter)) {
            $pref = ($extendCandidates | Where-Object { $_.DriveLetter -eq 'Z' } | Select-Object -First 1)
            $defaultZ = if ($pref) { $pref.DriveLetter } else { '' }
            $targetLetter = Prompt-ExtendTarget -Candidates $extendCandidates -DefaultLetter $defaultZ
        }
        if ([string]::IsNullOrWhiteSpace($targetLetter)) {
            Write-Host '[*] Cancelled.' -ForegroundColor Yellow
            exit 0
        }
        if ($targetLetter -eq $source) {
            throw ('Target cannot be the same as source ({0}:).' -f $source)
        }
        $match = $extendCandidates | Where-Object { $_.DriveLetter -eq $targetLetter } | Select-Object -First 1
        if (-not $match) {
            Write-Host ('[WARN] {0}: may not be adjacent to freed space; extend can fail.' -f $targetLetter) -ForegroundColor Yellow
        }
    }

    $tgtPart = Get-Partition -DriveLetter $targetLetter -ErrorAction Stop
    $tgtVol = Get-Volume -DriveLetter $targetLetter -ErrorAction SilentlyContinue
    $tgtSizeBefore = [int64]$tgtPart.Size

    $confirmMsg = @(
        'Extend existing volume?',
        '',
        ('Shrink {0}: by {1} GB' -f $source, $NewPartitionSizeGB),
        ('Extend {0}: (current ~{1} GB)' -f $targetLetter, (Format-GB $tgtSizeBefore)),
        "Disk: $($srcPart.DiskNumber)",
        '',
        'Requires target partition to sit immediately after freed space on the disk.'
    ) -join [Environment]::NewLine

    $ok = [System.Windows.Forms.MessageBox]::Show($confirmMsg, 'NextGPU Disk Management',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ok -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

    Write-Host ('[*] Shrinking {0}: ...' -f $source) -ForegroundColor Cyan
    try {
        Resize-Partition -DriveLetter $source -Size $targetSourceSize -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Show-ShrinkFailureHints
        exit 1
    }

    Write-Host ('[*] Extending {0}: into freed space ...' -f $targetLetter) -ForegroundColor Cyan
    try {
        $maxSize = (Get-PartitionSupportedSize -DriveLetter $targetLetter).SizeMax
        Resize-Partition -DriveLetter $targetLetter -Size $maxSize -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host ('[FAIL] Could not extend {0}: {1}' -f $targetLetter, $_.Exception.Message) -ForegroundColor Red
        Write-Host '[HINT] Disk layout may not allow extend (target not adjacent). Unallocated space remains on disk - use Disk Management or create a new partition.' -ForegroundColor Yellow
        exit 1
    }

    $tgtPartAfter = Get-Partition -DriveLetter $targetLetter
    $addedGb = [math]::Round(($tgtPartAfter.Size - $tgtSizeBefore) / 1GB, 2)
    Write-Host ('[OK] {0}: shrunk; {1}: extended by ~{2} GB (now ~{3} GB).' -f $source, $targetLetter, $addedGb, (Format-GB $tgtPartAfter.Size)) -ForegroundColor Green
}
else {
    if ([string]::IsNullOrWhiteSpace($targetLetter)) {
        $targetLetter = Prompt-NewDriveLetter -InUseLetters $inUse
    }
    if ([string]::IsNullOrWhiteSpace($targetLetter)) {
        Write-Host '[*] Cancelled.' -ForegroundColor Yellow
        exit 0
    }
    if ($targetLetter -eq $source) {
        throw ('New letter cannot be same as source ({0}:).' -f $source)
    }
    if ($inUse -contains $targetLetter) {
        throw ('Drive {0}: already exists. Use Extend existing volume to grow it instead.' -f $targetLetter)
    }

    $confirmMsg = @(
        'Create new partition?',
        '',
        ('Shrink {0}: by {1} GB' -f $source, $NewPartitionSizeGB),
        ('New partition: {0}: (~{1} GB, NTFS)' -f $targetLetter, $NewPartitionSizeGB),
        "Disk: $($srcPart.DiskNumber)"
    ) -join [Environment]::NewLine

    $ok = [System.Windows.Forms.MessageBox]::Show($confirmMsg, 'NextGPU Disk Management',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($ok -ne [System.Windows.Forms.DialogResult]::Yes) { exit 0 }

    Write-Host ('[*] Shrinking {0}: ...' -f $source) -ForegroundColor Cyan
    try {
        Resize-Partition -DriveLetter $source -Size $targetSourceSize -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        Show-ShrinkFailureHints
        exit 1
    }

    Write-Host ('[*] Creating {0}: ...' -f $targetLetter) -ForegroundColor Cyan
    try {
        $null = New-Partition -DiskNumber $srcPart.DiskNumber -Size $shrinkBytes -DriveLetter $targetLetter -ErrorAction Stop
        Format-Volume -DriveLetter $targetLetter -FileSystem NTFS -NewFileSystemLabel 'NextGPUData' -Confirm:$false -Force | Out-Null
    }
    catch {
        Write-Host "[FAIL] $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    Write-Host ('[OK] {0}: created (~{1} GB).' -f $targetLetter, $NewPartitionSizeGB) -ForegroundColor Green
    Write-Host ('    {0}: now ~{1} GB' -f $source, (Format-GB $targetSourceSize)) -ForegroundColor Green
}

$restart = [System.Windows.Forms.MessageBox]::Show(
    "Disk operation complete.`n`nRestart now (recommended)?",
    'NextGPU Disk Management',
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
)
if ($restart -eq [System.Windows.Forms.DialogResult]::Yes) {
    shutdown.exe /r /t 8 /c 'NextGPU disk layout change'
}

exit 0
