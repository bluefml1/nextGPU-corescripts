using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;

namespace NextGPU.App.Pages;

public partial class UserStoragePage : Page
{
    public UserStoragePage()
    {
        InitializeComponent();
        Loaded += (_, _) => BuildButtons();
    }

    private void BuildButtons()
    {
        OneClickPanel.Children.Clear();
        VerifyPanel.Children.Clear();
        DeployPanel.Children.Clear();
        DiagnosePanel.Children.Clear();
        MountPanel.Children.Clear();
        LogsPanel.Children.Clear();

        ActionPageTools.AddPrimaryBatchButton(OneClickPanel,
            "One-Click Setup (Admin)",
            @"scripts\runtime\User-Storage.bat",
            arguments: "Setup",
            keepConsoleOpen: true,
            confirm: "Install per-user S3 storage (rclone, WinFsp, AWS config, logon auto-mount)? You may be prompted for AWS keys.",
            tooltip: "Full setup: prerequisites, rclone.conf, publish to ProgramData, register BUILTIN\\Users logon task (+22s).");

        ActionPageTools.AddBatchButton(OneClickPanel,
            "Publish / Sync scripts & tasks",
            @"scripts\runtime\User-Storage.bat",
            arguments: "Sync",
            keepConsoleOpen: true,
            tooltip: "After script updates or nextGPU recreate: publish scripts, ACLs, re-register tasks.");

        ActionPageTools.AddCaptureButton(VerifyPanel,
            "Run readiness test",
            @"scripts\runtime\Test-NextGpuUserStorageRecreateReadiness.ps1",
            "");

        ActionPageTools.AddCaptureButton(VerifyPanel,
            "Test mount prerequisites",
            @"scripts\runtime\Test-UserStorageMount.ps1",
            "");

        ActionPageTools.AddBatchButton(DeployPanel,
            "Legacy: Setup-UserStorage.bat",
            @"scripts\runtime\Setup-UserStorage.bat",
            keepConsoleOpen: true,
            tooltip: "Same as One-Click Setup (wrapper).");

        ActionPageTools.AddPowerShellButton(DeployPanel,
            "Register tasks only",
            @"scripts\runtime\Register-UserStorageTasks.ps1", "",
            tooltip: "Re-register ensure + mount (BUILTIN\\Users) + unmount tasks.");

        ActionPageTools.AddPrimaryPowerShellButton(DiagnosePanel,
            "Diagnose & fix (ACL + WinFsp)",
            @"scripts\runtime\Troubleshoot-UserStorage.ps1",
            "-RepairAcl -InstallWinFsp",
            keepConsoleOpen: true,
            tooltip: "Config, API, WinFsp, tasks. Repairs ACL and installs rclone/WinFsp if missing.");

        ActionPageTools.AddPowerShellButton(DiagnosePanel,
            "Quick diagnose (no install)",
            @"scripts\runtime\Troubleshoot-UserStorage.ps1", "",
            keepConsoleOpen: true);

        ActionPageTools.AddCaptureButton(DiagnosePanel,
            "Test checkDomain API",
            @"scripts\runtime\Test-UserStorageMount.ps1", "");

        ActionPageTools.AddPowerShellButton(MountPanel,
            "Mount U: now (Admin + Moonlight)",
            @"scripts\runtime\Invoke-UserStorageMountFromAdmin.ps1", "",
            keepConsoleOpen: true,
            tooltip: "Triggers nextGPU-UserStorageMount while renter session is active.");

        ActionPageTools.AddPowerShellButton(MountPanel,
            "Start Sunshine + storage hook",
            @"scripts\provisioning\Start-Sunshine-InSession.ps1", "",
            keepConsoleOpen: true,
            tooltip: "Starts Sunshine and triggers mount task in session.");

        ActionPageTools.AddOpenExplorerButton(LogsPanel,
            "Open ProgramData storage logs",
            UserStorageUiPaths.ProgramDataLogsFolder,
            "C:\\ProgramData\\nextGPU\\logs");

        ActionPageTools.AddOpenExplorerButton(LogsPanel,
            "Open repo mirror logs",
            () => UserStorageUiPaths.RepoLogsFolder(),
            "logs\\user-storage-mount.log under repo root");

        ActionPageTools.AddOpenLogsButton(LogsPanel,
            "View mount log in app",
            "user-storage-mount.log");

        ActionPageTools.AddOpenLogsButton(LogsPanel,
            "View session log in app",
            "user-storage-session.log");
    }
}

internal static class UserStorageUiPaths
{
    public static string ProgramDataLogsFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "nextGPU", "logs");

    public static string RepoLogsFolder()
    {
        if (string.IsNullOrWhiteSpace(App.Session.RepoRoot))
            return string.Empty;
        return Path.Combine(App.Session.RepoRoot, "logs");
    }
}
