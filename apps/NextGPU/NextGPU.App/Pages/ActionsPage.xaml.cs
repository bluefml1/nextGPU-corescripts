using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using NextGPU.Core;

namespace NextGPU.App.Pages;

public partial class ActionsPage : Page
{
    public ActionsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => BuildButtons();
    }

    private void BuildButtons()
    {
        AddInstallMonitorButtons();
        AddStreamingButtons();
        AddTunnelButtons();
        AddMaintenanceButtons();
        AddProvisioningButtons();
        AddInventoryButtons();
        AddDriversButtons();
        AddDangerButtons();
    }

    private void AddInstallMonitorButtons()
    {
        AddNavLogButton(InstallMonitorPanel, "Latest setup log (Logs tab)",
            "Opens Logs with the newest setup_log_*.txt selected (if any).",
            () => NavigateLogsPrefer(null));

        AddNavLogButton(InstallMonitorPanel, "Sunshine bind log (Logs tab)",
            "Opens sunshine-bind.log (VDD / output_name binding).",
            () => NavigateLogsPrefer("sunshine-bind.log"));

        AddNavLogButton(InstallMonitorPanel, "VDD install log (Logs tab)",
            "Opens VDD-VAD.log.",
            () => NavigateLogsPrefer("VDD-VAD.log"));

        AddExplorerButton(InstallMonitorPanel, "Open logs folder",
            "Explorer: repo logs directory.");
    }

    private void AddStreamingButtons()
    {
        AddServiceButton(StreamingPanel, "Restart Sunshine (service)",
            "Restarts gpu-sunshine Windows service.",
            () => App.Session.Services!.Restart(RepoCatalog.SunshineServiceName));

        AddServiceButton(StreamingPanel, "Restart Sunshine (interactive)",
            "Stops service and starts sunshine.exe in user session.",
            () => App.Session.Services!.RestartSunshineInteractive());

        AddServiceButton(StreamingPanel, "Restart Moonlight Web",
            "Restarts moonlight-web service.",
            () => App.Session.Services!.Restart("moonlight-web"));
    }

    private void AddTunnelButtons()
    {
        AddServiceButton(TunnelPanel, "Restart cloudflared",
            "Restarts Cloudflare Tunnel service.",
            () => App.Session.Services!.Restart("cloudflared"));
    }

    private void AddMaintenanceButtons()
    {
        AddScriptButton(MaintenancePanel, "Run update check", @"scripts\runtime\checking-update.bat");

        AddScriptButton(MaintenancePanel, "Update games", @"scripts\maintenance\updateGames.bat");

        AddScriptButton(MaintenancePanel, "Sync Game/Apps Data Officially from NextGPU",
            @"scripts\maintenance\sync-games-apps-official.bat",
            keepConsoleOpen: true);

        AddScriptButton(MaintenancePanel, "Auto-repair (once)", @"scripts\runtime\auto-repair-once.bat");

        AddScriptButton(MaintenancePanel, "Auto-repair (service loop)",
            @"scripts\runtime\auto-repair.bat",
            confirm: "auto-repair.bat runs a continuous loop (NSSM service). Launch elevated console to view output? You normally leave this to the gpu-auto-repair service.",
            keepConsoleOpen: true);

        AddScriptButton(MaintenancePanel, "Network copy (copy.bat)", @"scripts\maintenance\copy.bat");

        AddScriptButton(MaintenancePanel, "Extract archives (extract.bat)", @"scripts\maintenance\extract.bat");

        AddScriptButton(MaintenancePanel, "Launch Garena (garena.bat)", @"scripts\maintenance\garena.bat");

        AddCaptureButton(MaintenancePanel, "Test repo layout (PS)",
            @"scripts\maintenance\Test-NextGpuLayout.ps1", "");
    }

    private void AddProvisioningButtons()
    {
        AddPowerShellButton(ProvisioningPanel, "Register Sunshine logon task",
            @"scripts\provisioning\Register-SunshineLogonTask.ps1", "",
            "Registers nextGPU-SunshineLogon (elevated).");

        AddPowerShellButton(ProvisioningPanel, "Register Desktop cleanup (nextGPU)",
            @"scripts\desktop\Register-NextGpuDesktopCleanupTask.ps1", "",
            "Registers nextGPU-DesktopCleanupLogon.");

        AddPowerShellButton(ProvisioningPanel, "Clear nextGPU Desktop now",
            @"scripts\desktop\Clear-NextGpuUserDesktop.ps1", "",
            "Removes all items from the nextGPU user Desktop folder (elevated path if not logged in as nextGPU).");

        AddPowerShellButton(ProvisioningPanel, "Start Sunshine in user session",
            @"scripts\provisioning\Start-Sunshine-InSession.ps1", "",
            "Stops gpu-sunshine and starts Sunshine in the interactive session (console stays open).",
            keepConsoleOpen: true);

        AddPowerShellButton(ProvisioningPanel, "Sunshine API restart (PS)",
            @"scripts\provisioning\Invoke-SunshineApiRestart.ps1", "",
            "POST Sunshine /api/restart (and reset persistence). Console stays open to read output.",
            keepConsoleOpen: true);

        AddCaptureButton(ProvisioningPanel, "VDD vs output_name (Get-VddOutputName)",
            @"scripts\provisioning\Get-VddOutputName.ps1", "");

        AddPowerShellButton(ProvisioningPanel, "Apply Sunshine dd_* defaults (Set-SunshineOutputName)",
            @"scripts\provisioning\Set-SunshineOutputName.ps1", "",
            "Writes dd_configuration_option + dd_config_revert_on_disconnect (no output_name).");
    }

    private void AddInventoryButtons()
    {
        AddCaptureButton(InventoryPanel, "WMI support check",
            @"scripts\provisioning\Ensure-WmiSupport.ps1", "");

        AddCaptureButton(InventoryPanel, "Machine inventory (long)",
            @"scripts\provisioning\Get-MachineInventory.ps1", "");
    }

    private void AddDriversButtons()
    {
        AddScriptButton(DriversPanel, "Install VDD/VAD", @"scripts\drivers\InstallVDD-VAD.bat");

        AddScriptButton(DriversPanel, "Install ViGEmBus", @"scripts\drivers\ViGEmBus.bat");

        AddScriptButton(DriversPanel, "Setup wallpaper", @"scripts\desktop\Setup-Wallpaper.bat");

        AddScriptButton(DriversPanel, "Lock shutdown (non-Authority)",
            @"scripts\desktop\Setup-Shutdown-Policy.bat",
            confirm: "Restrict shutdown/restart to NextGPU-Authority only?");

        AddCaptureButton(DriversPanel, "List display IDs",
            @"scripts\provisioning\Get-DisplayDeviceId.ps1",
            "-ListAll -IncludeInactive");
    }

    private void AddDangerButtons()
    {
        AddScriptButton(DangerPanel, "Full setup (RegisterMachine)",
            @"RegisterMachine_Beta.bat",
            confirm: "Launch full machine setup? This is a long install. The elevated console stays open (/k) when finished so you can read output — also use Logs → setup_log_*.txt (Live tail) and sunshine-bind.log.",
            keepConsoleOpen: true);

        AddScriptButton(DangerPanel, "Uninstall nextGPU",
            @"uninstall-all.bat",
            confirm: "Type YES to launch uninstall-all.bat",
            requireYes: true);
    }

    private void AddNavLogButton(Panel panel, string label, string tooltip, Action navigate)
    {
        var btn = CreateActionButton(label, tooltip);
        btn.Click += (_, _) => navigate();
        panel.Children.Add(btn);
    }

    private void AddExplorerButton(Panel panel, string label, string tooltip)
    {
        var btn = CreateActionButton(label, tooltip);
        btn.Click += (_, _) =>
        {
            if (App.Session.LogTail is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = App.Session.LogTail.LogsDirectory,
                UseShellExecute = true
            });
        };
        panel.Children.Add(btn);
    }

    private void NavigateLogsPrefer(string? explicitName)
    {
        if (App.Session.LogTail is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }
        var mw = Window.GetWindow(this) as MainWindow;
        if (mw is null)
            return;
        var pick = explicitName
                   ?? App.Session.LogTail.FindLatestSetupLogFileName()
                   ?? "sunshine-bind.log";
        mw.NavigateToLogs(pick);
    }

    private void AddServiceButton(Panel panel, string label, string tooltip, Func<(bool, string)> action)
    {
        var btn = CreateActionButton(label, tooltip);
        btn.Click += async (_, _) =>
        {
            if (App.Session.Services is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = await Task.Run(action);
            ShowResult(r);
        };
        panel.Children.Add(btn);
    }

    private void AddScriptButton(Panel panel, string label, string relativePath, string? confirm = null,
        bool requireYes = false, bool keepConsoleOpen = false)
    {
        var hint = keepConsoleOpen ? " Elevated console stays open (/k or -NoExit)." : "";
        var btn = CreateActionButton(label, $"Runs {relativePath} elevated.{hint}");
        btn.Click += (_, _) =>
        {
            if (!Confirm(confirm, requireYes))
                return;
            RunScript(relativePath, keepConsoleOpen);
        };
        panel.Children.Add(btn);
    }

    private void AddPowerShellButton(Panel panel, string label, string relativePath, string psArgs,
        string tooltip, bool keepConsoleOpen = false)
    {
        var hint = keepConsoleOpen ? " Console stays open (-NoExit)." : "";
        var btn = CreateActionButton(label, $"{tooltip}{hint}");
        btn.Click += (_, _) =>
        {
            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = App.Session.Scripts.RunPowerShellRelative(relativePath, psArgs, elevated: true, keepConsoleOpen: keepConsoleOpen);
            ShowResult(r);
        };
        panel.Children.Add(btn);
    }

    private void AddCaptureButton(Panel panel, string label, string relativePath, string psArgs)
    {
        var btn = CreateActionButton(label, "Runs PowerShell and shows captured output.");
        btn.Click += async (_, _) =>
        {
            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = await Task.Run(() => App.Session.Scripts.RunPowerShellCapture(relativePath, psArgs));
            MessageBox.Show(r.Message, r.Success ? label : "Error", MessageBoxButton.OK,
                r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
        };
        panel.Children.Add(btn);
    }

    private static Button CreateActionButton(string label, string tooltip)
    {
        return new Button
        {
            Content = label,
            ToolTip = tooltip,
            Margin = new Thickness(0, 0, 8, 8),
            Padding = new Thickness(14, 8, 14, 8),
            MinWidth = 160,
            Style = (Style)Application.Current.FindResource("SecondaryButton")
        };
    }

    private void RunScript(string relativePath, bool keepConsoleOpen = false)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not found.", "NextGPU");
            return;
        }
        var r = App.Session.Scripts.RunBatchRelative(relativePath, elevated: true, arguments: null, keepConsoleOpen: keepConsoleOpen);
        ShowResult(r);
    }

    private static bool Confirm(string? message, bool requireYes)
    {
        if (string.IsNullOrWhiteSpace(message))
            return MessageBox.Show("Continue?", "NextGPU", MessageBoxButton.YesNo) == MessageBoxResult.Yes;

        if (!requireYes)
            return MessageBox.Show(message, "NextGPU", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;

        var input = InputDialog.Show(message + "\n\nType YES to continue:", Application.Current.MainWindow);
        return string.Equals(input?.Trim(), "YES", StringComparison.OrdinalIgnoreCase);
    }

    private static void ShowResult((bool Success, string Message) r)
    {
        MessageBox.Show(r.Message, "NextGPU", MessageBoxButton.OK,
            r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }
}
