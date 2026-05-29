using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using NextGPU.Core;
using NextGPU.Core.Models;

namespace NextGPU.App.Pages;

public partial class DashboardPage : Page
{
    private DispatcherTimer? _timer;

    public DashboardPage()
    {
        InitializeComponent();
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        var seconds = App.Session.Settings.RefreshIntervalSeconds;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        _timer.Tick += async (_, _) => await RefreshAsync();
        _timer.Start();
        _ = RefreshAsync();
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        _timer?.Stop();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private async Task RefreshAsync()
    {
        if (App.Session.RepoRoot is null)
        {
            RepoBanner.Text = "Repo not found. Set NEXTGPU_REPO_ROOT or place NextGPU beside nextGPU-corescripts (RegisterMachine_Beta.bat).";
            StatusLine.Text = $"Machine: {Environment.MachineName}";
            ServiceCardsPanel.Children.Clear();
            return;
        }

        RepoBanner.Text = $"Repo: {App.Session.RepoRoot}";
        if (App.Session.Health is null)
            return;

        try
        {
            var repoRoot = App.Session.RepoRoot;
            var health = App.Session.Health;
            var report = await Task.Run(async () =>
                await health.CollectAsync(repoRoot).ConfigureAwait(false)).ConfigureAwait(true);
            StatusLine.Text =
                $"Machine: {report.MachineName}  |  Domain: {report.Domain.Domain ?? "—"}  |  Public IP: {report.Domain.PublicIp ?? "—"}  |  Status: {report.Domain.Status ?? "—"}";

            var moon = report.MoonlightHttpOk ? $"OK ({report.MoonlightHttpStatus})" : "DOWN";
            var sun = report.SunshineHttpOk ? $"OK ({report.SunshineHttpStatus})" : "DOWN";
            HttpLine.Text = $"Moonlight http://127.0.0.1:8080 → {moon}    |    Sunshine https://localhost:47990 → {sun}";

            var vdd = report.VddReady ? "OK" : "WARN";
            var vad = report.VadReady ? "OK" : "optional / not ready";
            DriverLine.Text = $"VDD: {vdd} ({report.VddDetail})    |    VAD: {vad} ({report.VadDetail})";
            RefreshedLine.Text = $"Last refresh: {report.RefreshedAt:yyyy-MM-dd HH:mm:ss}";

            if (!string.IsNullOrWhiteSpace(report.Domain.Domain))
            {
                OpenPublicBtn.Visibility = Visibility.Visible;
                OpenPublicBtn.Tag = $"https://{report.Domain.Domain}";
            }
            else
            {
                OpenPublicBtn.Visibility = Visibility.Collapsed;
            }

            BuildServiceCards(report.Services);
        }
        catch (Exception ex)
        {
            StatusLine.Text = $"Refresh failed: {ex.Message}";
        }
    }

    private void BuildServiceCards(List<ServiceHealthItem> services)
    {
        ServiceCardsPanel.Children.Clear();
        var cardStyle = Application.Current.TryFindResource("CardBorder") as Style;
        foreach (var svc in services)
        {
            var border = new Border
            {
                Style = cardStyle,
                Margin = new Thickness(0, 0, 10, 10),
                MinHeight = 140,
                Child = BuildServiceCardContent(svc)
            };
            ServiceCardsPanel.Children.Add(border);
        }
    }

    private UIElement BuildServiceCardContent(ServiceHealthItem svc)
    {
        var stack = new StackPanel();
        var title = new TextBlock { Text = svc.DisplayName, FontWeight = FontWeights.SemiBold, FontSize = 14 };
        var stateBrush = svc.State switch
        {
            ServiceRunState.Running => (Brush)Application.Current.FindResource("OkBrush"),
            ServiceRunState.Stopped => (Brush)Application.Current.FindResource("ErrBrush"),
            ServiceRunState.NotInstalled => (Brush)Application.Current.FindResource("WarnBrush"),
            _ => (Brush)Application.Current.FindResource("MutedBrush")
        };
        var state = new TextBlock
        {
            Text = svc.State.ToString(),
            Foreground = stateBrush,
            FontWeight = FontWeights.Bold,
            Margin = new Thickness(0, 4, 0, 10)
        };
        stack.Children.Add(title);
        stack.Children.Add(state);

        var btnRow = new StackPanel();
        var secondary = Application.Current.TryFindResource("SecondaryButton") as Style;
        var start = new Button { Content = "Start", Padding = new Thickness(10, 6, 10, 6), Style = secondary };
        var stop = new Button { Content = "Stop", Padding = new Thickness(10, 6, 10, 6), Style = secondary };
        var restart = new Button { Content = "Restart", Padding = new Thickness(10, 6, 10, 6), Style = secondary };
        var name = svc.ServiceName;
        start.Click += (_, _) => RunServiceAction(() => App.Session.Services!.Start(name));
        stop.Click += (_, _) => RunServiceAction(() => App.Session.Services!.Stop(name));
        restart.Click += (_, _) => RunServiceAction(() => App.Session.Services!.Restart(name));
        var controls = new WrapPanel { Margin = new Thickness(0, 0, 0, 4) };
        start.Margin = new Thickness(0, 0, 6, 6);
        stop.Margin = new Thickness(0, 0, 6, 6);
        restart.Margin = new Thickness(0, 0, 6, 6);
        controls.Children.Add(start);
        controls.Children.Add(stop);
        controls.Children.Add(restart);
        btnRow.Children.Add(controls);

        if (string.Equals(name, RepoCatalog.SunshineServiceName, StringComparison.OrdinalIgnoreCase))
        {
            var interactive = new Button
            {
                Content = "Restart (interactive)",
                ToolTip = "Use if Sunshine web UI shows raw {{ $t(...) }} template text after service install.",
                Margin = new Thickness(0, 0, 0, 0),
                Padding = new Thickness(10, 6, 10, 6),
                Style = secondary,
                HorizontalAlignment = HorizontalAlignment.Left
            };
            interactive.Click += (_, _) => RunServiceAction(() => App.Session.Services!.RestartSunshineInteractive());
            btnRow.Children.Add(interactive);
        }

        stack.Children.Add(btnRow);

        if (!string.IsNullOrWhiteSpace(svc.LogFileName) && App.Session.RepoRoot is not null)
        {
            var logBtn = new Button
            {
                Content = "View log",
                Margin = new Thickness(0, 8, 0, 0),
                Padding = new Thickness(10, 4, 10, 4),
                Style = secondary
            };
            var logName = svc.LogFileName;
            logBtn.Click += (_, _) =>
            {
                var w = Application.Current.MainWindow as MainWindow;
                w?.GetType(); // navigate via finding frame - simpler: open file
                var path = Path.Combine(RepoRootResolver.LogsDirectory(App.Session.RepoRoot), logName);
                if (File.Exists(path))
                    Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
                else
                    MessageBox.Show($"Log not found yet: {path}", "NextGPU", MessageBoxButton.OK, MessageBoxImage.Information);
            };
            stack.Children.Add(logBtn);
        }

        return stack;
    }

    private async void RunServiceAction(Func<(bool Success, string Message)> action)
    {
        var result = await Task.Run(action);
        MessageBox.Show(result.Message, result.Success ? "NextGPU" : "NextGPU — error",
            MessageBoxButton.OK, result.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
        await RefreshAsync();
    }

    private static void OpenUrl(string url)
    {
        try
        {
            Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "NextGPU", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void OpenSunshine_Click(object sender, RoutedEventArgs e) => OpenUrl("https://localhost:47990");
    private void OpenMoonlight_Click(object sender, RoutedEventArgs e) => OpenUrl("http://127.0.0.1:8080");
    private void OpenPublic_Click(object sender, RoutedEventArgs e)
    {
        if (OpenPublicBtn.Tag is string url)
            OpenUrl(url);
    }
}
