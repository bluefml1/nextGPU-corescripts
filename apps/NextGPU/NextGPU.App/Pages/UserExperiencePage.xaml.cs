using System.Windows.Controls;

namespace NextGPU.App.Pages;

public partial class UserExperiencePage : Page
{
    public UserExperiencePage()
    {
        InitializeComponent();
        Loaded += (_, _) => BuildButtons();
    }

    private void BuildButtons()
    {
        DesktopPanel.Children.Clear();
        DataPanel.Children.Clear();

        ActionPageTools.AddBatchButton(DesktopPanel, "Setup Wallpaper", @"scripts\desktop\Setup-Wallpaper.bat");
        ActionPageTools.AddBatchButton(DesktopPanel, "Apply Wallpaper Now", @"scripts\desktop\Apply-WallpaperNow.bat");
        ActionPageTools.AddCaptureButton(DesktopPanel, "Test Wallpaper Policy", @"scripts\desktop\Test-WallpaperPolicy.ps1");
        ActionPageTools.AddPowerShellButton(DesktopPanel, "Clear nextGPU Desktop now", @"scripts\desktop\Clear-NextGpuUserDesktop.ps1");
        ActionPageTools.AddPowerShellButton(DesktopPanel, "Register Desktop Cleanup Task", @"scripts\desktop\Register-NextGpuDesktopCleanupTask.ps1");
        ActionPageTools.AddOpenLogsButton(DesktopPanel, "Open Wallpaper Display Log", "wallpaper-after-display.log");

        ActionPageTools.AddBatchButton(DataPanel, "Sync Game/Apps Officially", @"scripts\maintenance\sync-games-apps-official.bat", keepConsoleOpen: true);
        ActionPageTools.AddBatchButton(DataPanel, "Update Games API", @"scripts\maintenance\updateGames.bat");
        ActionPageTools.AddBatchButton(DataPanel, "Network Copy", @"scripts\maintenance\copy.bat");
        ActionPageTools.AddBatchButton(DataPanel, "Extract Archives", @"scripts\maintenance\extract.bat");
        ActionPageTools.AddOpenLogsButton(DataPanel, "Open Network Copy Log", "network_copy.log");
    }
}
