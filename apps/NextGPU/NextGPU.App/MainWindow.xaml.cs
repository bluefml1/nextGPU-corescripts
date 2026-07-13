using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using NextGPU.App.Pages;

namespace NextGPU.App;

public partial class MainWindow : Window
{
    private static readonly Dictionary<string, string> PageSubtitles = new()
    {
        ["Get Started"] = "Step-by-step provisioning and troubleshooting",
        ["Dashboard"] = "Machine health, services, and quick links",
        ["Task Scheduler"] = "Heartbeat, auto-repair, auto-update, NVIDIA logon, and registration",
        ["User Storage (U:)"] = "One-click S3 setup — auto-mount U: on nextGPU sign-in",
        ["Setup Games & Apps"] = "Host setup (sync, layout, push) and Clean Session folder rules",
        ["User Experience"] = "Wallpaper and desktop cleanup",
        ["Bypass"] = "RunAsTool bypass shortcuts for elevated Playnite game launches",
        ["Sunshine"] = "Streaming host, display binding, and diagnostics",
        ["PlayNite"] = "Playnite setup, allowlist, Sunshine export, and verify",
        ["Moonlight"] = "Moonlight Web and tunnel controls",
        ["VDD-VAD"] = "Virtual display and audio drivers",
        ["Disk Management"] = "CHKDSK repair and partition prep",
        ["Logs"] = "Live tail and log file tools",
        ["Settings"] = "Repo path and refresh interval"
    };

    private readonly List<Button> _navButtons;

    public MainWindow()
    {
        InitializeComponent();
        _navButtons =
        [
            NavGetStartedBtn,
            NavDashboardBtn,
            NavTaskSchedulerBtn,
            NavUserStorageBtn,
            NavSetupGamesAppsBtn,
            NavUserExperienceBtn,
            NavBypassBtn,
            NavSunshineBtn,
            NavPlayniteBtn,
            NavMoonlightBtn,
            NavVddVadBtn,
            NavDiskMgmtBtn,
            NavLogsBtn,
            NavSettingsBtn
        ];
        LoginFrame.Navigate(new LoginPage(OnLoginSuccess));
    }

    private void OnLoginSuccess()
    {
        try
        {
            App.Session.IsAuthenticated = true;
            LoginHost.Visibility = Visibility.Collapsed;
            MainHost.Visibility = Visibility.Visible;
            NavigateToPage(new DashboardPage(), NavDashboardBtn, "Dashboard");
        }
        catch (Exception ex)
        {
            MessageBox.Show(
                $"The app could not open the main window after sign-in.{Environment.NewLine}{Environment.NewLine}{ex.Message}",
                "NextGPU",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            App.Session.IsAuthenticated = false;
            MainHost.Visibility = Visibility.Collapsed;
            LoginHost.Visibility = Visibility.Visible;
        }
    }

    private void NavGetStarted_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new GetStartedPage(), NavGetStartedBtn, "Get Started");

    private void NavDashboard_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new DashboardPage(), NavDashboardBtn, "Dashboard");

    private void NavTaskScheduler_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new TaskSchedulerPage(), NavTaskSchedulerBtn, "Task Scheduler");

    private void NavUserStorage_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new UserStoragePage(), NavUserStorageBtn, "User Storage (U:)");

    private void NavSetupGamesApps_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new SetupGamesAppsPage(), NavSetupGamesAppsBtn, "Setup Games & Apps");

    private void NavUserExperience_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new UserExperiencePage(), NavUserExperienceBtn, "User Experience");

    private void NavBypass_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new BypassPage(), NavBypassBtn, "Bypass");

    private void NavSunshine_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new SunshinePage(), NavSunshineBtn, "Sunshine");

    private void NavPlaynite_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new PlaynitePage(), NavPlayniteBtn, "PlayNite");

    private void NavMoonlight_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new MoonlightPage(), NavMoonlightBtn, "Moonlight");

    private void NavVddVad_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new VddVadPage(), NavVddVadBtn, "VDD-VAD");

    private void NavDiskMgmt_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new DiskManagementPage(), NavDiskMgmtBtn, "Disk Management");

    private void NavLogs_Click(object sender, RoutedEventArgs e) => NavigateToLogs();

    public void NavigateToLogs(string? preferredLogFile = null) =>
        NavigateToPage(new LogsPage(preferredLogFile), NavLogsBtn, "Logs");

    public void NavigateTo(Page page) => NavigateToPage(page, null, page.Title);

    private void NavSettings_Click(object sender, RoutedEventArgs e) =>
        NavigateToPage(new SettingsPage(), NavSettingsBtn, "Settings");

    private void NavigateToPage(Page page, Button? navButton, string title)
    {
        ContentFrame.Navigate(page);
        CurrentPageText.Text = title;
        CurrentPageSubtitle.Text = PageSubtitles.TryGetValue(title, out var sub) ? sub : string.Empty;
        SetActiveNav(navButton);
    }

    private void SetActiveNav(Button? activeButton)
    {
        var activeStyle = (Style)FindResource("NavButtonActive");
        var normalStyle = (Style)FindResource("NavButton");
        foreach (var btn in _navButtons)
        {
            btn.Style = btn == activeButton ? activeStyle : normalStyle;
        }
    }

    private void SignOut_Click(object sender, RoutedEventArgs e)
    {
        App.Session.IsAuthenticated = false;
        MainHost.Visibility = Visibility.Collapsed;
        LoginHost.Visibility = Visibility.Visible;
        CurrentPageText.Text = "";
        CurrentPageSubtitle.Text = "";
        SetActiveNav(null);
        LoginFrame.Navigate(new LoginPage(OnLoginSuccess));
    }
}
