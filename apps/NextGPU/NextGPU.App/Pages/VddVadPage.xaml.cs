using System.Windows.Controls;

namespace NextGPU.App.Pages;

public partial class VddVadPage : Page
{
    public VddVadPage()
    {
        InitializeComponent();
        Loaded += (_, _) => BuildButtons();
    }

    private void BuildButtons()
    {
        DriverPanel.Children.Clear();

        ActionPageTools.AddBatchButton(DriverPanel, "Install VDD/VAD", @"scripts\drivers\InstallVDD-VAD.bat");
        ActionPageTools.AddPowerShellButton(DriverPanel, "Install VAD Fallback", @"scripts\drivers\Install-VAD-Fallback.ps1", keepConsoleOpen: true,
            tooltip: "Fallback install path when VirtualAudioDriver is not ready.");
        ActionPageTools.AddCaptureButton(DriverPanel, "Check VDD/VAD Status", @"scripts\drivers\Get-VddVadStatus.ps1");
        ActionPageTools.AddBatchButton(DriverPanel, "Install ViGEmBus", @"scripts\drivers\ViGEmBus.bat");
        ActionPageTools.AddCaptureButton(DriverPanel, "List Display IDs", @"scripts\provisioning\Get-DisplayDeviceId.ps1", "-ListAll -IncludeInactive");
        ActionPageTools.AddCaptureButton(DriverPanel, "WMI Support Check", @"scripts\provisioning\Ensure-WmiSupport.ps1");
        ActionPageTools.AddOpenLogsButton(DriverPanel, "Open VDD-VAD.log", "VDD-VAD.log");
        ActionPageTools.AddOpenLogsButton(DriverPanel, "Open ViGEmBus.log", "ViGEmBus.log");
    }
}
