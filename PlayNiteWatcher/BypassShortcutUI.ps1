#Requires -Version 5.1
<#
    WinForms UI for Playnite bypass shortcut wizard.
#>

function Show-BypassExeFileDialog {
    param([string]$InitialPath = "")

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Executables (*.exe)|*.exe|All files (*.*)|*.*"
    $dialog.Title = "Select application executable"
    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        $dir = Split-Path -Path $InitialPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-BypassPathLiteral -Path $dir)) {
            $dialog.InitialDirectory = $dir
        }
    }
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return $dialog.FileName
}

function Show-BypassShortcutNameDialog {
    param(
        [string]$DefaultName = "",
        [string]$BypassesPath = ""
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Bypass shortcut name"
    $form.Size = New-Object System.Drawing.Size(480, 180)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(12, 15)
    $label.Size = New-Object System.Drawing.Size(440, 40)
    $label.Text = "Shortcut name (saved as .lnk in Game Shortcuts):"
    $form.Controls.Add($label)

    $text = New-Object System.Windows.Forms.TextBox
    $text.Location = New-Object System.Drawing.Point(12, 55)
    $text.Size = New-Object System.Drawing.Size(440, 23)
    $text.Text = $DefaultName
    $form.Controls.Add($text)

    if ($BypassesPath) {
        $hint = New-Object System.Windows.Forms.Label
        $hint.Location = New-Object System.Drawing.Point(12, 82)
        $hint.Size = New-Object System.Drawing.Size(440, 20)
        $hint.ForeColor = [System.Drawing.Color]::Gray
        $hint.Text = "Folder: $BypassesPath"
        $form.Controls.Add($hint)
    }

    $ok = New-Object System.Windows.Forms.Button
    $ok.Location = New-Object System.Drawing.Point(280, 110)
    $ok.Size = New-Object System.Drawing.Size(80, 28)
    $ok.Text = "OK"
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Location = New-Object System.Drawing.Point(372, 110)
    $cancel.Size = New-Object System.Drawing.Size(80, 28)
    $cancel.Text = "Cancel"
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $name = Sanitize-BypassShortcutFileName -Name $text.Text
    if ([string]::IsNullOrWhiteSpace($name)) {
        [System.Windows.Forms.MessageBox]::Show("Shortcut name is required.", "Bypass") | Out-Null
        return $null
    }
    return $name
}

function Show-BypassReplaceDialog {
    param(
        [object]$PlayniteMatch,
        [object]$AllowlistMatch
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $playLine = if ($PlayniteMatch) { "Playnite: $($PlayniteMatch.Name) ($($PlayniteMatch.PrimaryPlayPath))" } else { "Playnite: (not found)" }
    $allowLine = if ($AllowlistMatch) { "Allowlist: $($AllowlistMatch.Title) exe=$($AllowlistMatch.Exe) nameId=$($AllowlistMatch.NameId)" } else { "Allowlist: (not found)" }

    $msg = "App already exists:`n`n$playLine`n$allowLine`n`nReplace launch path with bypass shortcut and update allowlist?"
    return [System.Windows.Forms.MessageBox]::Show(
        $msg,
        "Replace bypass app?",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Question)
}

function Show-BypassAddAppForm {
    param(
        [string]$DefaultExe = "",
        [string]$DefaultTitle = "",
        [string]$DefaultType = "ThirdParty",
        [string]$DefaultSlot = ""
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $defs = Get-AllowlistTypeDefinitions

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Add bypass app to allowlist"
    $form.Size = New-Object System.Drawing.Size(460, 280)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false

    $y = 12
    function Add-LabelRow([string]$Text, [int]$Y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Location = New-Object System.Drawing.Point(12, $Y)
        $l.Size = New-Object System.Drawing.Size(120, 20)
        $l.Text = $Text
        $form.Controls.Add($l)
    }

    Add-LabelRow "Type" $y
    $typeCombo = New-Object System.Windows.Forms.ComboBox
    $typeCombo.Location = New-Object System.Drawing.Point(140, ($y - 3))
    $typeCombo.Size = New-Object System.Drawing.Size(290, 23)
    $typeCombo.DropDownStyle = "DropDownList"
    foreach ($d in $defs) { [void]$typeCombo.Items.Add($d.Type) }
    $idx = [array]::IndexOf($typeCombo.Items, $DefaultType)
    $typeCombo.SelectedIndex = if ($idx -ge 0) { $idx } else { 0 }
    $form.Controls.Add($typeCombo)
    $y += 36

    Add-LabelRow "Executable" $y
    $exeBox = New-Object System.Windows.Forms.TextBox
    $exeBox.Location = New-Object System.Drawing.Point(140, ($y - 3))
    $exeBox.Size = New-Object System.Drawing.Size(210, 23)
    $exeBox.Text = if ($DefaultExe) { [System.IO.Path]::GetFileName($DefaultExe) } else { "" }
    $form.Controls.Add($exeBox)
    $browse = New-Object System.Windows.Forms.Button
    $browse.Location = New-Object System.Drawing.Point(355, ($y - 4))
    $browse.Size = New-Object System.Drawing.Size(75, 25)
    $browse.Text = "Browse..."
    $browse.Add_Click({
            $picked = Show-BypassExeFileDialog -InitialPath $DefaultExe
            if ($picked) {
                $exeBox.Text = [System.IO.Path]::GetFileName($picked)
                $script:__bypassPickedExe = $picked
                if ([string]::IsNullOrWhiteSpace($titleBox.Text)) {
                    $titleBox.Text = [System.IO.Path]::GetFileNameWithoutExtension($picked)
                }
            }
        })
    $form.Controls.Add($browse)
    $script:__bypassPickedExe = $DefaultExe
    $y += 36

    Add-LabelRow "Title" $y
    $titleBox = New-Object System.Windows.Forms.TextBox
    $titleBox.Location = New-Object System.Drawing.Point(140, ($y - 3))
    $titleBox.Size = New-Object System.Drawing.Size(290, 23)
    $titleBox.Text = $DefaultTitle
    $form.Controls.Add($titleBox)
    $y += 36

    Add-LabelRow "Slot / NameId" $y
    $slotBox = New-Object System.Windows.Forms.TextBox
    $slotBox.Location = New-Object System.Drawing.Point(140, ($y - 3))
    $slotBox.Size = New-Object System.Drawing.Size(290, 23)
    $slotBox.Text = $DefaultSlot
    $form.Controls.Add($slotBox)
    $y += 44

    $ok = New-Object System.Windows.Forms.Button
    $ok.Location = New-Object System.Drawing.Point(260, $y)
    $ok.Size = New-Object System.Drawing.Size(80, 28)
    $ok.Text = "OK"
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Location = New-Object System.Drawing.Point(350, $y)
    $cancel.Size = New-Object System.Drawing.Size(80, 28)
    $cancel.Text = "Cancel"
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $exeName = $exeBox.Text.Trim()
    $slot = $slotBox.Text.Trim()
    $title = $titleBox.Text.Trim()
    $type = [string]$typeCombo.SelectedItem

    if ([string]::IsNullOrWhiteSpace($exeName) -or [string]::IsNullOrWhiteSpace($slot)) {
        [System.Windows.Forms.MessageBox]::Show("Executable and Slot / NameId are required.", "Bypass") | Out-Null
        return $null
    }

    if (-not $exeName.EndsWith('.exe', [System.StringComparison]::OrdinalIgnoreCase)) {
        $exeName = "$exeName.exe"
    }

    $fullExe = $script:__bypassPickedExe
    if ([string]::IsNullOrWhiteSpace($fullExe) -or ([System.IO.Path]::GetFileName($fullExe) -ine $exeName)) {
        if ($exeName -match '^[A-Za-z]:[\\/]' -or $exeName -match '^\\\\') {
            $fullExe = $exeName
        }
        elseif (-not [string]::IsNullOrWhiteSpace($script:__bypassPickedExe) -and ($script:__bypassPickedExe -match '[\\/]')) {
            $fullExe = Join-Path (Split-Path -Path $script:__bypassPickedExe -Parent) $exeName
        }
        else {
            $fullExe = $exeName
        }
    }

    try {
        $nameId = Resolve-AllowlistNameId -Type $type -SlotInput $slot
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Invalid slot") | Out-Null
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($title)) {
        $title = [System.IO.Path]::GetFileNameWithoutExtension($exeName)
    }

    return [PSCustomObject]@{
        Exe         = $exeName
        ExeFullPath = $fullExe
        Title       = $title
        Type        = $type
        NameIdInput = $slot
        NameId      = $nameId
    }
}

function Show-BypassContinueAnotherDialog {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    return [System.Windows.Forms.MessageBox]::Show(
        "Add another bypass app?",
        "Bypass wizard",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
}

function Show-BypassExportSunshineDialog {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    return [System.Windows.Forms.MessageBox]::Show(
        "Export to Sunshine now so new apps appear in Moonlight?",
        "Export",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
}

function ConvertTo-BypassSyncTypeDisplayName {
    param([string]$SyncType)
    if ($SyncType -eq 'OutsideAllowlist') { return 'Outside allowlist' }
    return 'In allowlist'
}

function ConvertFrom-BypassSyncTypeDisplayName {
    param([string]$DisplayName)
    if ($DisplayName -eq 'Outside allowlist') { return 'OutsideAllowlist' }
    return 'InAllowlist'
}

function Show-BypassHelperPathDialog {
    param([string]$InitialPath = "")

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Helper apps (*.exe;*.lnk)|*.exe;*.lnk|All files (*.*)|*.*"
    $dialog.Title = "Select helper executable or shortcut"
    if (-not [string]::IsNullOrWhiteSpace($InitialPath)) {
        $dir = Split-Path -Path $InitialPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($dir) -and (Test-BypassPathLiteral -Path $dir)) {
            $dialog.InitialDirectory = $dir
        }
    }
    if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return $dialog.FileName
}

function Show-BypassShortcutReviewDialog {
    param(
        [object[]]$Rows,
        [string]$BypassesPath = ""
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Review bypass shortcuts"
    $form.Size = New-Object System.Drawing.Size(960, 520)
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize = New-Object System.Drawing.Size(720, 400)

    $header = New-Object System.Windows.Forms.Label
    $header.Location = New-Object System.Drawing.Point(12, 12)
    $header.Size = New-Object System.Drawing.Size(920, 48)
    $count = @($Rows).Count
    $folderLine = if ($BypassesPath) { "`nFolder: $BypassesPath" } else { "" }
    $header.Text = "$count sync-list entry(ies). Pre-launches from bypass-sync-list.json run before the shortcut .lnk. Shortcut names are fixed. Pre-launches column is read-only for sync-list rows.$folderLine"
    $form.Controls.Add($header)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 68)
    $grid.Size = New-Object System.Drawing.Size(920, 380)
    $grid.Anchor = "Top, Bottom, Left, Right"
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.MultiSelect = $false
    $form.Controls.Add($grid)

    $colFile = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colFile.Name = "File"
    $colFile.HeaderText = "File"
    $colFile.ReadOnly = $true
    $colFile.FillWeight = 14
    [void]$grid.Columns.Add($colFile)

    $colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colName.Name = "DisplayName"
    $colName.HeaderText = "Shortcut name"
    $colName.ReadOnly = $true
    $colName.FillWeight = 18
    [void]$grid.Columns.Add($colName)

    $colPre = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colPre.Name = "PreLaunches"
    $colPre.HeaderText = "Pre-launches"
    $colPre.ReadOnly = $true
    $colPre.FillWeight = 22
    [void]$grid.Columns.Add($colPre)

    $colHint = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colHint.Name = "Hint"
    $colHint.HeaderText = "Hint"
    $colHint.ReadOnly = $true
    $colHint.FillWeight = 46
    [void]$grid.Columns.Add($colHint)

    $rowIndex = 0
    foreach ($r in @($Rows)) {
        $preSummary = if ($r.PreLaunchesSummary) { $r.PreLaunchesSummary } elseif ($r.HelperPath) { $r.HelperPath } else { "" }
        [void]$grid.Rows.Add($r.FileName, $r.DisplayName, $preSummary, $r.Hint)
        $grid.Rows[$rowIndex].Tag = $r
        $rowIndex++
    }

    $grid.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -lt 0) { return }
    })

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "OK"
    $ok.Size = New-Object System.Drawing.Size(90, 30)
    $ok.Anchor = "Bottom, Right"
    $ok.Location = New-Object System.Drawing.Point(750, 460)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($ok)

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Size = New-Object System.Drawing.Size(90, 30)
    $cancel.Anchor = "Bottom, Right"
    $cancel.Location = New-Object System.Drawing.Point(846, 460)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancel)

    $form.AcceptButton = $ok
    $form.CancelButton = $cancel

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }

    $results = @()
    foreach ($gridRow in $grid.Rows) {
        if ($gridRow.IsNewRow) { continue }
        $original = $gridRow.Tag
        if (-not $original) { continue }

        $displayName = Sanitize-BypassShortcutFileName -Name ([string]$gridRow.Cells["DisplayName"].Value)
        if ([string]::IsNullOrWhiteSpace($displayName)) {
            [System.Windows.Forms.MessageBox]::Show(
                "Shortcut name is required for: $($original.FileName)",
                "Bypass review",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return $null
        }

        $helperPath = [string]$gridRow.Cells["PreLaunches"].Value

        $results += [PSCustomObject]@{
            OriginalLnkPath     = $original.OriginalLnkPath
            FileName            = $original.FileName
            DisplayName         = $displayName
            SyncListEntry       = $original.SyncListEntry
            PreLaunches         = $original.PreLaunches
            PreLaunchesSummary  = if ($original.PreLaunchesSummary) { $original.PreLaunchesSummary } else { $helperPath }
            SuggestedPlayniteId = $original.SuggestedPlayniteId
            SuggestedNameId     = $original.SuggestedNameId
            SuggestedExe        = $original.SuggestedExe
            SuggestedType       = $original.SuggestedType
            Hint                = $original.Hint
            IsNewDesktopApp     = $original.IsNewDesktopApp
            HelperPath          = $original.HelperPath
            HelperDelaySec      = $original.HelperDelaySec
        }
    }

    return $results
}

function Show-BypassDuplicateNoticesDialog {
    param([string[]]$Notices)

    $items = @($Notices | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($items.Count -eq 0) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $body = ($items -join ("$([Environment]::NewLine)$([Environment]::NewLine)"))
    [System.Windows.Forms.MessageBox]::Show(
        $body,
        "Duplicate Playnite entries",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
}

function Show-RunAsToolManualStepsDialog {
    param(
        [string]$AdminUser,
        [string]$BypassesPath
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $msg = @"
RunAsTool is running. Complete these steps manually:

1. Log in as $AdminUser
2. Enable Edit Mode
3. Add File, then Run as administrator
4. Create shortcut in:
   $BypassesPath

When finished, run:
  .\Sync-PlayniteBypassShortcuts.ps1 -Interactive
"@

    [System.Windows.Forms.MessageBox]::Show(
        $msg,
        "RunAsTool - manual setup",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}
