#Requires -Version 5.1
<#
.SYNOPSIS
    UI automation for RunAsTool: add program, enable admin, create bypass shortcut.
#>

function Convert-SecureStringToPlainText {
    param([securestring]$SecureString)
    if (-not $SecureString) { return "" }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Add-RunAsToolAutomationTypes {
    if (-not ("RunAsToolUiNative" -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class RunAsToolUiNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr FindWindowEx(IntPtr hwndParent, IntPtr hwndChildAfter, string lpszClass, string lpszWindow);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);
    public const uint WM_SETTEXT = 0x000C;
    public const uint BM_CLICK = 0x00F5;
    public const uint WM_COMMAND = 0x0111;
    public const int IDOK = 1;
}
"@
    }
}

function Get-RunAsToolMainWindowHandle {
    param([System.Diagnostics.Process]$Process)

    if (-not $Process) { return [IntPtr]::Zero }
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $Process.Refresh()
            if ($Process.MainWindowHandle -ne [IntPtr]::Zero) {
                return $Process.MainWindowHandle
            }
        }
        catch { }
        Start-Sleep -Milliseconds 250
    }
    return [IntPtr]::Zero
}

function Set-RunAsToolWindowForeground {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return $false }
    Add-RunAsToolAutomationTypes
    [RunAsToolUiNative]::ShowWindow($Hwnd, 9) | Out-Null
    return [RunAsToolUiNative]::SetForegroundWindow($Hwnd)
}

function Wait-ForDialogWindow {
    param(
        [int]$TimeoutMs = 15000,
        [string]$TitleContains = ""
    )

    Add-RunAsToolAutomationTypes
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ([DateTime]::UtcNow -lt $deadline) {
        $found = [IntPtr]::Zero
        $callback = [RunAsToolUiNative+EnumWindowsProc]{
            param($hWnd, $lParam)
            $classSb = New-Object System.Text.StringBuilder 64
            [RunAsToolUiNative]::GetClassName($hWnd, $classSb, $classSb.Capacity) | Out-Null
            if ($classSb.ToString() -ne '#32770') { return $true }
            if ($TitleContains) {
                $titleSb = New-Object System.Text.StringBuilder 512
                [RunAsToolUiNative]::GetWindowText($hWnd, $titleSb, $titleSb.Capacity) | Out-Null
                if ($titleSb.ToString() -notmatch [regex]::Escape($TitleContains)) { return $true }
            }
            $script:__ratDialogHwnd = $hWnd
            return $false
        }
        $script:__ratDialogHwnd = [IntPtr]::Zero
        [RunAsToolUiNative]::EnumWindows($callback, [IntPtr]::Zero) | Out-Null
        if ($script:__ratDialogHwnd -ne [IntPtr]::Zero) {
            return $script:__ratDialogHwnd
        }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Set-CommonFileDialogPath {
    param(
        [IntPtr]$DialogHwnd,
        [string]$Path
    )

    Add-RunAsToolAutomationTypes
    $edit = [RunAsToolUiNative]::FindWindowEx($DialogHwnd, [IntPtr]::Zero, "ComboBoxEx32", $null)
    if ($edit -eq [IntPtr]::Zero) {
        $edit = [RunAsToolUiNative]::FindWindowEx($DialogHwnd, [IntPtr]::Zero, "Edit", $null)
    }
    if ($edit -eq [IntPtr]::Zero) {
        $combo = [RunAsToolUiNative]::FindWindowEx($DialogHwnd, [IntPtr]::Zero, "ComboBox", $null)
        if ($combo -ne [IntPtr]::Zero) {
            $edit = [RunAsToolUiNative]::FindWindowEx($combo, [IntPtr]::Zero, "Edit", $null)
        }
    }
    if ($edit -eq [IntPtr]::Zero) {
        throw "Could not find file name field in common dialog."
    }
    [void][RunAsToolUiNative]::SendMessage($edit, [RunAsToolUiNative]::WM_SETTEXT, [IntPtr]::Zero, $Path)
}

function Confirm-CommonFileDialog {
    param([IntPtr]$DialogHwnd)

    Add-RunAsToolAutomationTypes
    $openBtn = [RunAsToolUiNative]::FindWindowEx($DialogHwnd, [IntPtr]::Zero, "Button", $null)
    while ($openBtn -ne [IntPtr]::Zero) {
        $titleSb = New-Object System.Text.StringBuilder 64
        [RunAsToolUiNative]::GetWindowText($openBtn, $titleSb, $titleSb.Capacity) | Out-Null
        $text = $titleSb.ToString()
        if ($text -match '^(Open|Save|&Open|&Save|OK)$') {
            [void][RunAsToolUiNative]::SendMessage($openBtn, [RunAsToolUiNative]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
            return
        }
        $openBtn = [RunAsToolUiNative]::FindWindowEx($DialogHwnd, $openBtn, "Button", $null)
    }
    [void][RunAsToolUiNative]::SendMessage($DialogHwnd, [RunAsToolUiNative]::WM_COMMAND, [IntPtr][RunAsToolUiNative]::IDOK, [IntPtr]::Zero)
}

function Invoke-RunAsToolSendKeys {
    param([string]$Keys)
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
}

function Invoke-RunAsToolAdminLoginIfNeeded {
    param(
        [string]$AdminUser,
        [securestring]$AdminPassword,
        [scriptblock]$LogAction
    )

    $plain = Convert-SecureStringToPlainText -SecureString $AdminPassword
    if ([string]::IsNullOrWhiteSpace($plain)) {
        if ($LogAction) { & $LogAction "No admin password provided; skipping RunAsTool login step." "WARN" }
        return
    }

    Start-Sleep -Milliseconds 800
    $loginDlg = Wait-ForDialogWindow -TimeoutMs 5000
    if ($loginDlg -eq [IntPtr]::Zero) {
        if ($LogAction) { & $LogAction "RunAsTool login dialog not detected (may already be configured)." }
        return
    }

    if ($LogAction) { & $LogAction "RunAsTool login dialog detected; entering credentials." }
    Set-RunAsToolWindowForeground -Hwnd $loginDlg | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-RunAsToolSendKeys -Keys $plain
    Start-Sleep -Milliseconds 200
    Invoke-RunAsToolSendKeys -Keys "{ENTER}"
    Start-Sleep -Milliseconds 800
}

function Invoke-RunAsToolAddProgramFile {
    param(
        [IntPtr]$MainHwnd,
        [string]$ExePath,
        [scriptblock]$LogAction
    )

    Set-RunAsToolWindowForeground -Hwnd $MainHwnd | Out-Null
    Start-Sleep -Milliseconds 400
    Invoke-RunAsToolSendKeys -Keys "%f"
    Start-Sleep -Milliseconds 350
    Invoke-RunAsToolSendKeys -Keys "a"
    Start-Sleep -Milliseconds 600

    $dlg = Wait-ForDialogWindow -TimeoutMs 12000
    if ($dlg -eq [IntPtr]::Zero) {
        throw "Open File dialog did not appear after File -> Add File."
    }

    if ($LogAction) { & $LogAction "Setting Open File dialog path: $ExePath" }
    Set-CommonFileDialogPath -DialogHwnd $dlg -Path $ExePath
    Start-Sleep -Milliseconds 200
    Confirm-CommonFileDialog -DialogHwnd $dlg
    Start-Sleep -Milliseconds 1200
}

function Invoke-RunAsToolEnableAdminForProgram {
    param(
        [IntPtr]$MainHwnd,
        [string]$ExeFileName,
        [scriptblock]$LogAction
    )

    Set-RunAsToolWindowForeground -Hwnd $MainHwnd | Out-Null
    Start-Sleep -Milliseconds 500

    $enabled = $false
    try {
        Add-Type -AssemblyName UIAutomationClient | Out-Null
        Add-Type -AssemblyName UIAutomationTypes | Out-Null
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($MainHwnd)
        if ($root) {
            $nameCond = New-Object System.Windows.Automation.PropertyCondition(
                [System.Windows.Automation.AutomationElement]::NameProperty, "Run as administrator")
            $adminCtrl = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $nameCond)
            if ($adminCtrl) {
                $toggle = $adminCtrl.GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern)
                if ($toggle -and $toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) {
                    $toggle.Toggle()
                    $enabled = $true
                    if ($LogAction) { & $LogAction "Enabled 'Run as administrator' via UI Automation." }
                }
                elseif ($toggle) {
                    $enabled = $true
                    if ($LogAction) { & $LogAction "'Run as administrator' already enabled." }
                }
            }
        }
    }
    catch {
        if ($LogAction) { & $LogAction "UIA admin toggle failed: $($_.Exception.Message)" "WARN" }
    }

    if (-not $enabled) {
        if ($LogAction) { & $LogAction "Falling back to keyboard for admin rights selection." }
        Invoke-RunAsToolSendKeys -Keys "{HOME}"
        Start-Sleep -Milliseconds 200
        for ($i = 0; $i -lt 25; $i++) {
            Invoke-RunAsToolSendKeys -Keys "{DOWN}"
            Start-Sleep -Milliseconds 80
        }
        Invoke-RunAsToolSendKeys -Keys "%a"
        Start-Sleep -Milliseconds 400
    }
}

function Invoke-RunAsToolCreateShortcutSave {
    param(
        [IntPtr]$MainHwnd,
        [string]$DestLnk,
        [scriptblock]$LogAction
    )

    $destDir = Split-Path -Path $DestLnk -Parent
    $destName = [System.IO.Path]::GetFileName($DestLnk)
    if ([string]::IsNullOrWhiteSpace($destDir)) {
        throw "Shortcut destination folder is invalid for: $DestLnk"
    }
    if (-not (Test-BypassPathLiteral -Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Set-RunAsToolWindowForeground -Hwnd $MainHwnd | Out-Null
    Start-Sleep -Milliseconds 400
    Invoke-RunAsToolSendKeys -Keys "+{F10}"
    Start-Sleep -Milliseconds 400
    Invoke-RunAsToolSendKeys -Keys "s"
    Start-Sleep -Milliseconds 800

    $dlg = Wait-ForDialogWindow -TimeoutMs 12000
    if ($dlg -eq [IntPtr]::Zero) {
        throw "Save shortcut dialog did not appear after Create Shortcut."
    }

    $fullPath = Join-Path $destDir $destName
    if ($LogAction) { & $LogAction "Saving shortcut to: $fullPath" }
    Set-CommonFileDialogPath -DialogHwnd $dlg -Path $fullPath
    Start-Sleep -Milliseconds 200
    Confirm-CommonFileDialog -DialogHwnd $dlg
    Start-Sleep -Milliseconds 1000
}

function Invoke-RunAsToolBypassShortcutAutomation {
    param(
        [Parameter(Mandatory)]
        [string]$RunAsToolExe,
        [Parameter(Mandatory)]
        [string]$ExePath,
        [Parameter(Mandatory)]
        [string]$DestLnk,
        [string]$AdminUser = "NextGPU-Admin",
        [securestring]$AdminPassword,
        [string]$TileDisplayName = "",
        [int]$TimeoutSec = 120,
        [int]$MaxAttempts = 3,
        [scriptblock]$LogAction
    )

    if (-not (Test-BypassPathLiteral -Path $ExePath)) {
        throw "Executable not found: $ExePath"
    }
    if (-not (Test-BypassPathLiteral -Path $RunAsToolExe)) {
        throw "RunAsTool not found: $RunAsToolExe"
    }

    $exeFileName = [System.IO.Path]::GetFileName($ExePath)
    $lastError = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ($LogAction) { & $LogAction "RunAsTool automation attempt $attempt/$MaxAttempts" }

            $proc = Start-RunAsToolApplication -ExePath $RunAsToolExe
            Start-Sleep -Seconds 2

            $mainHwnd = [IntPtr]::Zero
            $hwndDeadline = [DateTime]::UtcNow.AddSeconds(10)
            while ([DateTime]::UtcNow -lt $hwndDeadline -and $mainHwnd -eq [IntPtr]::Zero) {
                $mainHwnd = Get-RunAsToolMainWindowHandle -Process $proc
                if ($mainHwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 300 }
            }
            if ($mainHwnd -eq [IntPtr]::Zero) {
                throw "RunAsTool main window not found."
            }

            Invoke-RunAsToolAdminLoginIfNeeded -AdminUser $AdminUser -AdminPassword $AdminPassword -LogAction $LogAction
            $mainHwnd = Get-RunAsToolMainWindowHandle -Process $proc
            if ($mainHwnd -ne [IntPtr]::Zero) {
                Set-RunAsToolWindowForeground -Hwnd $mainHwnd | Out-Null
            }

            Invoke-RunAsToolAddProgramFile -MainHwnd $mainHwnd -ExePath $ExePath -LogAction $LogAction
            $mainHwnd = Get-RunAsToolMainWindowHandle -Process $proc
            Invoke-RunAsToolEnableAdminForProgram -MainHwnd $mainHwnd -ExeFileName $exeFileName -LogAction $LogAction
            $mainHwnd = Get-RunAsToolMainWindowHandle -Process $proc
            Invoke-RunAsToolCreateShortcutSave -MainHwnd $mainHwnd -DestLnk $DestLnk -LogAction $LogAction

            $deadline = (Get-Date).AddSeconds($TimeoutSec)
            while ((Get-Date) -lt $deadline) {
                if (Test-BypassPathLiteral -Path $DestLnk) {
                    $info = Get-ShortcutLaunchInfo -LnkPath $DestLnk
                    if ($info -and (Test-ShortcutLooksLikeRunAsTool -ShortcutInfo $info)) {
                        if ($LogAction) { & $LogAction "Bypass shortcut verified: $DestLnk" }
                        return [PSCustomObject]@{
                            Success    = $true
                            LaunchPath = $DestLnk
                            ExePath    = $ExePath
                            Method     = "UiAutomation"
                            ShortcutInfo = $info
                        }
                    }
                    if ($info) {
                        if ($LogAction) { & $LogAction "Shortcut exists but target may not be RunAsTool: $($info.TargetPath)" "WARN" }
                        return [PSCustomObject]@{
                            Success    = $true
                            LaunchPath = $DestLnk
                            ExePath    = $ExePath
                            Method     = "UiAutomation"
                            ShortcutInfo = $info
                        }
                    }
                }
                Start-Sleep -Milliseconds 500
            }

            throw "Shortcut file was not created at: $DestLnk"
        }
        catch {
            $lastError = $_
            if ($LogAction) { & $LogAction "RunAsTool automation attempt $attempt failed: $($_.Exception.Message)" "WARN" }
            Start-Sleep -Seconds 1
        }
    }

    throw "RunAsTool automation failed after $MaxAttempts attempts: $($lastError.Exception.Message)"
}
