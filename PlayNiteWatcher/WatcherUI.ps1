$isAdmin = [bool]([System.Security.Principal.WindowsIdentity]::GetCurrent().groups -match 'S-1-5-32-544')
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

$OutputEncoding = [Console]::OutputEncoding = New-Object System.Text.Utf8Encoding
[Console]::InputEncoding = New-Object System.Text.Utf8Encoding

$flagFilePath = "$env:APPDATA\PlayniteWatcher\PlayniteWatcherAdminFlag"

class ApplicationInfo {
    [string]$applicationName
    [string]$uniqueId
    [string]$uuid
    [string]$cmd
    [string]$detached
    [string]$imagePath
    [bool]$waitAll
    [bool]$autoDetach
    [int]$exitTimeout
    [bool]$useSteamEpicFormat
    [string]$kioskOutput
}

# To minimize prompts, we will only warn the user once about admin rights.
if (-not $isAdmin) {
    if (-not (Test-Path $flagFilePath)) {
        $result = [System.Windows.Forms.MessageBox]::Show("You will be prompted for administrator rights, as Sunshine requires admin in order to modify the apps.json file.", "Administrator Required", [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) {
            exit
        }

        # If the user clicks OK, we will run the script with elevated privileges.
        # Create the flag file to indicate that the user has been warned about admin rights.
        # This will prevent the prompt from appearing again in future runs.
        New-Item -ItemType File -Path $flagFilePath -Force
    }
   
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -WindowStyle Hidden
    exit
    
}

$scriptPath = Split-Path $MyInvocation.MyCommand.Path -Parent
Set-Location $scriptPath
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

function LoadConfigFilePath() {
    # Retrieve the path utilizing regex from the primary script.
    $scriptContents = Get-Content "./PlayniteWatcher.ps1"
    $ma = $scriptContents | select-string '(\$sunshineConfigPath)\s=\s"(.*)"'
    $foundPath = $ma.Matches.Groups[2].Value
    if (-not (Test-Path $foundPath)) {
        throw "Could not verify Sunshine/Apollo config path"
    }
    $configPathTextBox.Text = $foundPath.Replace('\\', '\')
}

function LoadPlayniteExecutablePath() {
    . (Join-Path $scriptPath "Playnite-Common.ps1")
    try {
        $configuredExe = Get-PlayniteDesktopExeFromConfig -RepoRoot $scriptPath
        $playNitePathTextBox.Text = $configuredExe
        return $configuredExe
    }
    catch {
        $playNitePathTextBox.Text = ""
        return $null
    }
}

function Get-EventLogsPrepCmd {
    return [PSCustomObject]@{
        do       = ""
        undo     = 'powershell.exe -ExecutionPolicy Bypass -NoProfile -File "C:\Program Files\Sunshine\scripts\eventLogs.ps1"'
        elevated = $true
    }
}

function SaveChanges($configPath, $updatedApps) {
    $appsJsonPath = Join-Path $configPath "apps.json"
    $appConfiguration = Get-Content -Encoding utf8 -Path $appsJsonPath -Raw | ConvertFrom-Json
    [object[]]$filteredApps = FilterPlayniteApps -configPath $configPath

    foreach ($app in $updatedApps) {
        if ($app.uniqueId -eq "") {
            continue;
        }

        if ($app.useSteamEpicFormat) {
            $jsonApp = [PSCustomObject]@{
                name                      = $app.applicationName
                'playnite-id'             = $app.uniqueId
                output                    = $app.kioskOutput
                'prep-cmd'                = @(Get-EventLogsPrepCmd)
                'auto-detach'             = $true
                'exclude-global-prep-cmd' = $false
                'exit-timeout'            = 5
                'image-path'              = ""
                elevated                  = $true
                'wait-all'                = $false
                'wait-exit'               = $false
            }
            # Steam/Epic export uses Moonlight pairing (resolved-appids.txt), not a Sunshine cmd line.
        }
        else {
            $jsonApp = [PSCustomObject]@{
                'image-path'              = $app.imagePath
                name                      = $app.applicationName
                'prep-cmd'                = @(Get-EventLogsPrepCmd)
                'wait-all'                = $app.waitAll
                'exit-timeout'            = $app.exitTimeout
                'auto-detach'             = $app.autoDetach
                'exclude-global-prep-cmd' = $false
                'uuid'                    = $app.uuid
            }
            if ($app.detached -ne "") {
                $jsonApp | Add-Member -MemberType NoteProperty -Name "detached" -Value $app.detached -Force
            }
        }
        $filteredApps += $jsonApp
    }
    $appConfiguration.apps = $filteredApps
    $appConfiguration | ConvertTo-Json -Depth 100 | Set-Content -Path $appsJsonPath -Encoding utf8
}

function Test-IsPlayniteManagedSunshineApp($app) {
    if ($app.'playnite-id') { return $true }
    if ($app.'image-path' -and ($app.'image-path' -match 'Apps\\')) { return $true }
    if ($app.cmd -like '*PlayniteWatcher*' -or $app.cmd -like '*Playnite.DesktopApp*') { return $true }
    if ($app.detached -like '*playnite*' -or $app.detached -like '*Playnite*') { return $true }
    if ($app.'prep-cmd') {
        foreach ($prep in @($app.'prep-cmd')) {
            if ($prep.undo -like '*eventLogs.ps1*') { return $true }
        }
    }
    return $false
}

function ParseGames($configPath) {
    $appsPath = Join-Path $configPath "apps.json"
    $apps = @()
    $JsonContent = Get-Content -Encoding utf8 -Path $appsPath -Raw | ConvertFrom-Json
    $JsonContent.apps | ForEach-Object {
        $app = [ApplicationInfo]::new()
        $id = $null
        $parsed = $false

        if ($_.'playnite-id') {
            $id = $_.'playnite-id'.ToString()
            $app.useSteamEpicFormat = $true
            $app.kioskOutput = if ($_.output) { $_.output } else { "" }
            $parsed = $true
        }
        elseif ($_.output -match '^([0-9a-fA-F-]{36})\.kiosk\.log$') {
            $id = $Matches[1]
            $app.useSteamEpicFormat = $true
            $app.kioskOutput = $_.output
            $parsed = $true
        }
        elseif ($_.'image-path' -match 'Apps\\(.*)\\') {
            $id = $Matches[1]
            $parsed = $true
        }

        if ($parsed) {
            $app.applicationName = $_.name
            $app.uniqueId = $id
            $app.uuid = if ($_.uuid) { $_.uuid } else { $id.ToUpper() }
            $app.imagePath = if ($_.'image-path') { $_.'image-path' } else { "" }
            $app.cmd = $_.cmd
            $app.detached = $_.detached
            $app.exitTimeout = if ($_.'exit-timeout') { $_.'exit-timeout' } else { 0 }

            $app.waitAll = if ($_.'wait-all') {
                ($_.'wait-all' -eq $true) -or ($_.'wait-all' -eq "true")
            }
            else {
                $false
            }

            $app.autoDetach = if ($_.'auto-detach') {
                ($_.'auto-detach' -eq $true) -or ($_.'auto-detach' -eq "true")
            }
            else {
                $false
            }

            $apps += $app
        }
    }
    return $apps
}

function FilterPlayniteApps($configPath) {
    $appsJsonPath = Join-Path $configPath "apps.json"
    $JsonContent = Get-Content -Encoding utf8 -Path $appsJsonPath -Raw | ConvertFrom-Json
    return $JsonContent.apps | Where-Object { -not (Test-IsPlayniteManagedSunshineApp $_) }
}

function RemoveDuplicates($apps) {
    $dict = [System.Collections.Generic.Dictionary[string, ApplicationInfo]]::new()
    foreach ($app in $apps) {
        if ($dict.ContainsKey($app.uniqueId)) {
            continue
        }
        else {
            $dict.Add($app.uniqueId, $app)
        }
    }
    return $dict.Values
}

function SaveSettings() {
    . (Join-Path $scriptPath "Playnite-Common.ps1")

    $playniteExe = $playNitePathTextBox.Text
    if (-not [string]::IsNullOrWhiteSpace($playniteExe) -and (Test-Path -LiteralPath $playniteExe)) {
        $installDir = Split-Path -Path $playniteExe -Parent
        Save-PlayniteInstallPath -RepoRoot $scriptPath -InstallDir $installDir | Out-Null
    }

    $filePaths = @(".\PlayniteWatcher.ps1", ".\PrepCommandInstaller.ps1")
    foreach ($filePath in $filePaths) {
        $content = Get-Content -Encoding utf8 -Path $filePath
        $configPattern = '(\$sunshineConfigPath\s*=\s*")[^"]*(")'
        $updatedContent = $content -replace $configPattern, "`$1$($configPathTextBox.Text.Replace('\', '\\'))`$2"
        Set-Content -Path $filePath -Value $updatedContent
    }
}

# New function: Folder picker for Sunshine config folder
function ShowFolderBrowserDialog($textBox, $initialDirectory) {
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.SelectedPath = $initialDirectory
    $folderBrowser.Description = "Select Sunshine/Apollo Config Folder"
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textBox.Text = $folderBrowser.SelectedPath
    }
}

# OpenFileDialog Function
function ShowOpenFileDialog($filter, $initialDirectory, $textBox) {
    $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
    $openFileDialog.Filter = $filter
    $openFileDialog.InitialDirectory = $initialDirectory
    if ($openFileDialog.ShowDialog() -eq "OK") {
        $textBox.Text = $openFileDialog.FileName
    }
}

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Playnite Watcher Installer" Height="230" Width="720">
    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <DockPanel Grid.Row="0" Margin="10">
            <Label Content="Sunshine/Apollo Config Folder:" VerticalAlignment="Center" Width="190"/>
            <TextBox Name="SunshineConfigFolder" Text="C:\Program Files\Sunshine\config" Margin="5,0,5,0" Width="325" Height="25" IsReadOnly="true"/>
            <Button Name="BrowseButton" Content="Browse" Width="75" HorizontalAlignment="Left" Margin="5,0,5,0" Height="25"/>
        </DockPanel>
        <DockPanel Grid.Row="1" Margin="10">
            <Label Content="Playnite Executable Path:" VerticalAlignment="Center" Width="190"/>
            <TextBox Name="PlaynitePath" Text="" Margin="5,0,5,0" Width="325" Height="25" IsReadOnly="true"/>
            <Button Name="PlayniteBrowseButton" Content="Browse" Width="75" HorizontalAlignment="Left" Margin="5,0,5,0" Height="25"/>
        </DockPanel>
        <DockPanel Grid.Row="2" Margin="10" VerticalAlignment="Top">
            <Button Name="InstallButton" Content="Install" Width="75" Height="25" Margin="2,0,2,0"/>
            <Button Name="UninstallButton" Content="Uninstall" Width="75" Height="25" Margin="2,0,2,0"/>
        </DockPanel>
        <TextBlock Grid.Row="3" Margin="0" TextWrapping="Wrap" HorizontalAlignment="Center" FontWeight="Bold">
        NOTICE: Clicking install or uninstall will terminate existing Moonlight sessions and restart Playnite to finish the installation.
        </TextBlock>
    </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$configPathTextBox = $window.FindName("SunshineConfigFolder")
$playNitePathTextBox = $window.FindName("PlaynitePath")

# Config folder Browse button click event handler using folder picker
$window.FindName("BrowseButton").Add_Click({
        ShowFolderBrowserDialog -textBox $configPathTextBox -initialDirectory $configPathTextBox.Text
        LoadGames -configPath $configPathTextBox.Text
        SaveSettings
    })

$window.FindName("PlayniteBrowseButton").Add_Click({
        ShowOpenFileDialog -filter "Playnite Executable|Playnite.DesktopApp.exe" -initialDirectory ([System.IO.Path]::GetDirectoryName($playNitePathTextBox.Text)) -textBox $playNitePathTextBox
        SaveSettings
    })

$window.FindName("InstallButton").Add_Click({
        $installCount = 0
        $playniteRoot = Split-Path $playNitePathTextBox.Text -Parent

        . (Join-Path $scriptPath "Playnite-Common.ps1")
        $allowFile = Resolve-DesktopAppAllowlistPath -RepoRoot $scriptPath
        if (Test-Path -LiteralPath $allowFile) {
            try {
                $exportScript = Join-Path $scriptPath "Export-SunshineFromPlaynite.ps1"
                if (Test-Path -LiteralPath $exportScript) {
                    . $exportScript
                    $exportParams = @{ PlayniteInstallDir = $playniteRoot }
                    if (-not [string]::IsNullOrWhiteSpace($configPathTextBox.Text)) {
                        $exportParams.SunshineConfigDir = $configPathTextBox.Text
                    }
                    Invoke-SunshineExportFromPlaynite @exportParams
                }
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show(
                    "Sunshine export failed: $($_.Exception.Message)",
                    "Export warning",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning)
            }
        }

        $updatedApps = ParseGames -configPath $configPathTextBox.Text
        $updatedApps = RemoveDuplicates -apps $updatedApps

        $playniteExe = $playNitePathTextBox.Text
        $playniteRootDir = Split-Path $playniteExe -Parent
        $fullScreenExe = Join-Path $playniteRootDir "Playnite.FullscreenApp.exe"

        foreach ($playniteApp in $updatedApps) {
            $installCount += 1
            $playniteApp.cmd = ""
            if ($playniteApp.useSteamEpicFormat) {
                $playniteApp.detached = ""
            }
        }

        ## add FullScreen applet (launch Playnite fullscreen directly; prep-cmd undo only on games)
        if ($null -eq ($updatedApps | Where-Object { $_.applicationName -eq "PlayNite FullScreen App" })) {
            $updatedApps = , [PSCustomObject]@{
                applicationName    = "PlayNite FullScreen App"
                imagePath          = "$scriptPath\playnite-boxart.png"
                cmd                = "`"$fullScreenExe`""
                detached           = ""
                waitAll            = $false
                autoDetach         = $false
                exitTimeout        = 0
                uuid               = "14D9821B-7EA2-48C2-9AF7-970608282F93"
                useSteamEpicFormat = $false
            } + $updatedApps
        }

        Remove-Item -Path "$playniteRoot\Extensions\PlayniteWatcherExt" -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -Path "./PlayNiteWatcherExt" -Destination "$playniteRoot\Extensions\PlayNiteWatcherExt" -Force -Recurse
        SaveChanges -configPath $configPathTextBox.Text -updatedApps $updatedApps

        $scopedInstall = {
            . $scriptPath\PrepCommandInstaller.ps1 $true
        }
        & $scopedInstall

        ## Open it in a background thread, so that if the user disconnects from a Moonlight session, Playnite will still restart.
        Start-Job -ArgumentList $playNitePathTextBox.Text {
            param($path)
            Start-Sleep -Seconds 5
            Get-Process Playnite.DesktopApp -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
            Start-Process -FilePath explorer.exe -ArgumentList $path
        }

        [System.Windows.Forms.MessageBox]::Show("The script has been successfully installed to $installCount application(s)!", "Installation Complete!", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    })

$window.FindName("UninstallButton").Add_Click({
        $msgBoxTitle = "Uninstall script"
        $msgBoxText = "Are you sure you want to remove this script? This will remove all exported games from Playnite"
        $msgBoxButtons = [System.Windows.Forms.MessageBoxButtons]::YesNo
        $msgBoxIcon = [System.Windows.Forms.MessageBoxIcon]::Warning
        $msgBoxResult = [System.Windows.Forms.MessageBox]::Show($msgBoxText, $msgBoxTitle, $msgBoxButtons, $msgBoxIcon)

        if ($msgBoxResult -eq [System.Windows.Forms.DialogResult]::Yes) {
            $playnitePath = $playNitePathTextBox.Text
            $playniteRoot = Split-Path $playnitePath -Parent
            $parsedApps = ParseGames -configPath $configPathTextBox.Text | ForEach-Object { $_.uniqueId = ""; $_ }
            SaveChanges -configPath $configPathTextBox.Text -updatedApps $parsedApps

            $scopedInstall = {
                . $scriptPath\PrepCommandInstaller.ps1 $false
            }
            Remove-Item "$playniteRoot\Extensions\PlayNiteWatcherExt" -Force -Recurse
            & $scopedInstall
            [System.Windows.Forms.MessageBox]::Show("You can now close this application, the script has been successfully uninstalled", "Uninstall Complete!", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })

$window.Add_Loaded({
        try {
            LoadConfigFilePath
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("An issue was encountered while attempting to retrieve your Sunshine config folder. Once you dismiss this message, a window will open, prompting you to locate the Sunshine config folder. Please navigate to your Sunshine config folder and then click Open.", "Error: Could not find config folder", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            ShowFolderBrowserDialog -textBox $configPathTextBox -initialDirectory $env:ProgramFiles
        }
        try {
            $path = LoadPlayniteExecutablePath
            if (-not (Test-Path $path)) {
                throw "Could not locate PlayNite"
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("An issue was encountered while attempting to retrieve the PlayNite executable path. Once you dismiss this message, a window will open, prompting you to locate the PlayNite folder. Please ensure that you choose the PlayNite folder and select the `Playnite.DesktopApp.exe` file within it.", "Error: Could not find PlayNite Executable", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            ShowOpenFileDialog -filter "Playnite Exe|Playnite.DesktopApp.exe|All files (*.*)|*.*" -initialDirectory $env:ProgramFiles -textBox $playNitePathTextBox
        }
        SaveSettings
    })

# Show WPF window
$window.ShowDialog() | Out-Null
