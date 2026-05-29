using System.Windows.Controls;

namespace NextGPU.App.Pages;

public partial class DiskManagementPage : Page
{
    public DiskManagementPage()
    {
        InitializeComponent();
        Loaded += (_, _) => BuildButtons();
    }

    private void BuildButtons()
    {
        ChkPanel.Children.Clear();
        PartitionPanel.Children.Clear();

        ActionPageTools.AddPowerShellButton(ChkPanel, "Run CHKDSK Repair (Choose Disk/All)",
            @"scripts\maintenance\Run-ChkDsk-Repair.ps1", "", keepConsoleOpen: true,
            tooltip: "GUI prompt chooses one disk or all fixed disks, runs chkdsk /f, asks restart.");

        ActionPageTools.AddPowerShellButton(PartitionPanel, "Shrink Volume (Extend Existing or Create New)",
            @"scripts\maintenance\Create-Z-Partition.ps1", "", keepConsoleOpen: true,
            tooltip: "Shrink any fixed drive; extend an existing volume (e.g. Z:) or create a new partition with a new letter.");
    }
}
