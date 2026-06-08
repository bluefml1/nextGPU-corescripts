using System.Windows;
using System.Windows.Controls;
using NextGPU.Core;

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

        ActionPageTools.AddNavigateButton(DataPanel, "User Storage (U:) — setup & mount",
            "Open the dedicated User Storage page (Admin RDP + Moonlight workflow).",
            () =>
            {
                if (Application.Current.MainWindow is MainWindow mw)
                    mw.NavigateTo(new UserStoragePage());
            });
        ActionPageTools.AddBatchButton(DataPanel, "Sync Game/Apps Officially", @"scripts\maintenance\sync-games-apps-official.bat", keepConsoleOpen: true);
        ActionPageTools.AddBatchButton(DataPanel, "Arrange Games/Apps", @"scripts\maintenance\arrange-games-apps.bat", keepConsoleOpen: true);
        ActionPageTools.AddBatchButton(DataPanel, "Push Zip to R2 Origin", @"scripts\maintenance\push-games-apps-to-r2.bat", keepConsoleOpen: true);
        AddPushMoonlightGamesButton(DataPanel);
        ActionPageTools.AddBatchButton(DataPanel, "Update Games API (Manual)",
            @"scripts\maintenance\updateGames.bat", keepConsoleOpen: true,
            helpText: "Same as Push to AWS but prompts for computer_name and publicIP in the console if domain.txt values are not accepted.");
        ActionPageTools.AddBatchButton(DataPanel, "Network Copy", @"scripts\maintenance\copy.bat");
        ActionPageTools.AddBatchButton(DataPanel, "Extract Archives", @"scripts\maintenance\extract.bat");
        ActionPageTools.AddOpenLogsButton(DataPanel, "Open Network Copy Log", "network_copy.log");
    }

    private static void AddPushMoonlightGamesButton(Panel panel)
    {
        const string relativePath = @"scripts\maintenance\updateGames.bat";
        var btn = new Button
        {
            Content = "Push Moonlight Games to AWS",
            ToolTip = "Push current Moonlight apps to AWS using domain.txt",
            Padding = new Thickness(14, 10, 14, 10),
            Style = (Style)Application.Current.FindResource("PrimaryButton")
        };
        btn.Click += (_, _) =>
        {
            if (App.Session.Scripts is null || string.IsNullOrWhiteSpace(App.Session.RepoRoot))
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }

            var domain = DomainFileReader.Read(App.Session.RepoRoot);
            if (string.IsNullOrWhiteSpace(domain.ComputerName) || string.IsNullOrWhiteSpace(domain.PublicIp))
            {
                MessageBox.Show(
                    "domain.txt is missing COMPUTER_NAME or PUBLIC_IP.\n\n" +
                    "Run Register Machine setup first, or create domain.txt at the repo root.",
                    "NextGPU", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var confirm = $"Push Moonlight games to AWS?\n\n" +
                          $"computer_name: {domain.ComputerName}\n" +
                          $"publicIP: {domain.PublicIp}\n\n" +
                          "Requires Moonlight Web on localhost:8080.";
            if (MessageBox.Show(confirm, "NextGPU", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
                return;

            var r = App.Session.Scripts.RunBatchRelative(relativePath, elevated: true, arguments: "/UseDomainTxt", keepConsoleOpen: true);
            MessageBox.Show(r.Message, "NextGPU", MessageBoxButton.OK,
                r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
        };
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn,
                "Reads COMPUTER_NAME and PUBLIC_IP from domain.txt, fetches apps from Moonlight Web, and posts them to the AWS updateNewGame API.");
        else
            panel.Children.Add(btn);
    }
}
