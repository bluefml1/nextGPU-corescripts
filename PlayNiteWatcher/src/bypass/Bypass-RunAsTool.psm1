#Requires -Version 5.1
<#
    RunAsTool management for bypass shortcuts.
    Dot-sourced from Playnite-Common.ps1.
#>

$script:_moduleRoot = $PSScriptRoot

function Start-RunAsToolApplication {
    param(
        [Parameter(Mandatory)]
        [string]$ExePath,
        [string]$WorkingDirectory = ""
    )

    if (-not (Test-BypassPathLiteral -Path $ExePath)) {
        throw "RunAsTool not found: $ExePath"
    }

    $workDir = $WorkingDirectory
    if ([string]::IsNullOrWhiteSpace($workDir)) {
        $workDir = Split-Path -Path $ExePath -Parent
    }

    $existing = Get-Process -Name "RunAsTool*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existing) {
        try {
            Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win32RunAsToolFocus {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@ -ErrorAction SilentlyContinue
            [Win32RunAsToolFocus]::ShowWindow($existing.MainWindowHandle, 9) | Out-Null
            [Win32RunAsToolFocus]::SetForegroundWindow($existing.MainWindowHandle) | Out-Null
        }
        catch { }
        return $existing
    }

    return Start-Process -FilePath $ExePath -WorkingDirectory $workDir -PassThru
}

function Assert-BypassShortcutPaths {
    param(
        [string]$ExePath,
        [string]$BypassesPath,
        [string]$RunAsToolExe = "",
        [string]$LaunchPath = ""
    )

    if ([string]::IsNullOrWhiteSpace($ExePath)) {
        throw "Application executable path is required."
    }
    if ([string]::IsNullOrWhiteSpace($BypassesPath)) {
        throw "Game Shortcuts folder is not configured. Run Setup Bypass Folder first."
    }
    if (-not [string]::IsNullOrWhiteSpace($RunAsToolExe) -and -not (Test-BypassPathLiteral -Path $RunAsToolExe)) {
        throw "RunAsTool not found: $RunAsToolExe"
    }
    if (-not [string]::IsNullOrWhiteSpace($LaunchPath)) {
        $launchLeaf = Split-Path -Path $LaunchPath -Leaf
        if ([string]::IsNullOrWhiteSpace($launchLeaf)) {
            throw "Bypass shortcut path is invalid: $LaunchPath"
        }
    }
}

function Install-RunAsToolIfMissing {
    param(
        [string]$RepoRoot,
        [switch]$SkipDownload,
        [scriptblock]$LogAction
    )

    $watcherRoot = Get-PlayNiteWatcherScriptRoot
    $installScript = Join-Path $watcherRoot "Install-RunAsTool.ps1"
    if (-not (Test-Path -LiteralPath $installScript)) {
        return $null
    }

    $installArgs = @{
        RepoRoot  = $watcherRoot
        LogAction = $LogAction
    }
    if ($SkipDownload.IsPresent) {
        $installArgs['SkipDownload'] = $true
    }

    $result = & $installScript @installArgs
    if ($result.Path -and (Test-Path -LiteralPath $result.Path)) {
        return $result.Path
    }
    return $null
}

function Resolve-RunAsToolExe {
    param(
        [string]$RepoRoot,
        [string]$OverridePath = "",
        [switch]$InstallIfMissing
    )

    if (-not [string]::IsNullOrWhiteSpace($OverridePath) -and (Test-Path -LiteralPath $OverridePath)) {
        return $OverridePath
    }

    $wrapper = Get-BypassShortcutsConfig -RepoRoot $RepoRoot
    $saved = $wrapper.Config.runAsToolExe
    if (-not [string]::IsNullOrWhiteSpace($saved) -and (Test-Path -LiteralPath $saved)) {
        return $saved
    }

    foreach ($candidate in @(
            (Join-Path $script:DefaultRunAsToolProgramDataDir "RunAsTool_x64.exe"),
            (Join-Path $script:DefaultRunAsToolProgramDataDir "RunAsTool.exe")
        )) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    $watcherRoot = Get-PlayNiteWatcherScriptRoot
    $bundled = @(
        (Join-Path $watcherRoot "tools\runastool\RunAsTool_x64.exe"),
        (Join-Path $watcherRoot "tools\runastool\RunAsTool.exe")
    )
    foreach ($candidate in $bundled) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    if ($InstallIfMissing) {
        $installed = Install-RunAsToolIfMissing -RepoRoot $RepoRoot
        if ($installed) {
            return $installed
        }
    }

    return $null
}

function Show-ResolveRunAsToolExeDialog {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "RunAsTool|RunAsTool.exe;RunAsTool_x64.exe|All files (*.*)|*.*"
    $dialog.Title = "Locate RunAsTool.exe"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        return $dialog.FileName
    }
    return $null
}

function Ensure-RunAsToolExeResolved {
    param(
        [string]$RepoRoot,
        [ref]$ConfigRef,
        [switch]$Launch,
        [scriptblock]$LogAction
    )

    $exe = Resolve-RunAsToolExe -RepoRoot $RepoRoot -OverridePath $ConfigRef.Value.runAsToolExe -InstallIfMissing
    if (-not $exe) {
        $exe = Install-RunAsToolIfMissing -RepoRoot $RepoRoot -LogAction $LogAction
    }

    if ($exe) {
        $ConfigRef.Value.runAsToolExe = $exe
        if ($Launch.IsPresent) {
            Start-RunAsToolApplication -ExePath $exe | Out-Null
        }
        return $exe
    }

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    $choice = [System.Windows.Forms.MessageBox]::Show(
        "RunAsTool is not installed and auto-download failed.`n`nYes = retry download`nNo = browse for RunAsTool.exe`nCancel = abort",
        "RunAsTool required",
        [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
        [System.Windows.Forms.MessageBoxIcon]::Warning)

    if ($choice -eq [System.Windows.Forms.DialogResult]::Cancel) {
        throw "RunAsTool is required for bypass shortcut creation."
    }

    if ($choice -eq [System.Windows.Forms.DialogResult]::Yes) {
        $exe = Install-RunAsToolIfMissing -RepoRoot $RepoRoot -LogAction $LogAction
        if ($exe) {
            $ConfigRef.Value.runAsToolExe = $exe
            if ($Launch.IsPresent) {
                Start-RunAsToolApplication -ExePath $exe | Out-Null
            }
            return $exe
        }
    }

    $picked = Show-ResolveRunAsToolExeDialog
    if ($picked) {
        $ConfigRef.Value.runAsToolExe = $picked
        if ($Launch.IsPresent) {
            Start-RunAsToolApplication -ExePath $picked | Out-Null
        }
        return $picked
    }

    throw "RunAsTool.exe could not be resolved."
}

Export-ModuleMember -Function *
