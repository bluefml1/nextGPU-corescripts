using System.Windows.Controls;
using NextGPU.Core;

namespace NextGPU.App.Pages;

public partial class SunshinePage : Page
{
    public SunshinePage()
    {
        InitializeComponent();
        Loaded += (_, _) => BuildButtons();
    }

    private void BuildButtons()
    {
        ControlPanel.Children.Clear();
        DiagPanel.Children.Clear();

        ActionPageTools.AddServiceButton(ControlPanel, "Restart Sunshine (Service)",
            () => App.Session.Services!.Restart(RepoCatalog.SunshineServiceName),
            "Restart gpu-sunshine service");
        ActionPageTools.AddServiceButton(ControlPanel, "Restart Sunshine (Interactive)",
            () => App.Session.Services!.RestartSunshineInteractive(),
            "Stop service and start Sunshine in interactive user session");
        ActionPageTools.AddPowerShellButton(ControlPanel, "Start Sunshine In Session",
            @"scripts\provisioning\Start-Sunshine-InSession.ps1", keepConsoleOpen: true);
        ActionPageTools.AddPowerShellButton(ControlPanel, "Sunshine API Restart",
            @"scripts\provisioning\Invoke-SunshineApiRestart.ps1", keepConsoleOpen: true);
        ActionPageTools.AddPowerShellButton(ControlPanel, "Register Sunshine Logon Task",
            @"scripts\provisioning\Register-SunshineLogonTask.ps1");

        ActionPageTools.AddCaptureButton(DiagPanel, "Get VDD Output Name", @"scripts\provisioning\Get-VddOutputName.ps1");
        ActionPageTools.AddPowerShellButton(DiagPanel, "Apply Sunshine dd_* Defaults",
            @"scripts\provisioning\Set-SunshineOutputName.ps1");
        ActionPageTools.AddOpenLogsButton(DiagPanel, "Open sunshine-bind.log", "sunshine-bind.log");
        ActionPageTools.AddOpenLogsButton(DiagPanel, "Open sunshine.log", "sunshine.log");
    }
}
