using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using NextGPU.Core;
using NextGPU.Core.Models;

namespace NextGPU.App.Pages;

public partial class TaskSchedulerPage : Page
{
    private DispatcherTimer? _timer;

    public TaskSchedulerPage()
    {
        InitializeComponent();
        BuildRegisterPanel();
    }

    private void BuildRegisterPanel()
    {
        ActionPageTools.AddPrimaryPowerShellButton(RegisterPanel,
            "Register all tasks",
            RepoCatalog.TaskSchedulerOrchestratorRelativePath,
            keepConsoleOpen: true,
            helpText: "Runs scripts/tasks/TaskScheduler.ps1 — registers heartbeat, auto-repair, NVIDIA logon, EndSession, EndSession recovery (startup), auto game launch, and Playnite logon when available.");

        ActionPageTools.AddPowerShellButton(RegisterPanel,
            "Start NVIDIA now",
            @"scripts\provisioning\Start-Nvidia-InSession.ps1",
            keepConsoleOpen: true,
            helpText: "Starts NVIDIA App in the current session (same script the logon task runs).");

        ActionPageTools.AddPowerShellButton(RegisterPanel,
            "Verify task setup",
            RepoCatalog.TaskSchedulerVerifyRelativePath,
            keepConsoleOpen: true,
            helpText: "Runs Test-TaskSchedulerSetup.ps1 to validate scripts and paths. Add -Register when elevated to test live registration.");

        foreach (var template in RepoCatalog.KnownScheduledTasks)
        {
            if (string.IsNullOrWhiteSpace(template.RegisterScriptRelativePath))
                continue;
            ActionPageTools.AddPowerShellButton(RegisterPanel,
                $"Register: {template.DisplayName}",
                template.RegisterScriptRelativePath,
                keepConsoleOpen: true,
                helpText: $"Registers only {template.TaskName}.");
        }
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        var seconds = App.Session.Settings.RefreshIntervalSeconds;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(seconds) };
        _timer.Tick += async (_, _) => await RefreshAsync();
        _timer.Start();
        _ = RefreshAsync();
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e) => _timer?.Stop();

    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshAsync();

    private async Task RefreshAsync()
    {
        if (App.Session.ScheduledTasks is null)
        {
            SummaryLine.Text = "Repo not configured. Set repo path in Settings.";
            TaskCardsPanel.Children.Clear();
            return;
        }

        try
        {
            var tasks = await Task.Run(() => App.Session.ScheduledTasks!.CollectKnownTasks()).ConfigureAwait(true);
            var installed = tasks.Count(t => t.State != ScheduledTaskState.NotInstalled);
            var ready = tasks.Count(t => t.State is ScheduledTaskState.Ready or ScheduledTaskState.Running);
            SummaryLine.Text = $"{installed}/{tasks.Count} tasks registered  |  {ready} ready/running";
            RefreshedLine.Text = $"Last refresh: {DateTime.Now:yyyy-MM-dd HH:mm:ss}";
            BuildTaskCards(tasks);
        }
        catch (Exception ex)
        {
            SummaryLine.Text = $"Refresh failed: {ex.Message}";
        }
    }

    private void BuildTaskCards(IReadOnlyList<ScheduledTaskItem> tasks)
    {
        TaskCardsPanel.Children.Clear();
        var cardStyle = Application.Current.TryFindResource("CardBorder") as Style;
        foreach (var task in tasks)
        {
            var border = new Border
            {
                Style = cardStyle,
                Margin = new Thickness(0, 0, 10, 10),
                MinHeight = 220,
                Child = BuildTaskCardContent(task)
            };
            TaskCardsPanel.Children.Add(border);
        }
    }

    private UIElement BuildTaskCardContent(ScheduledTaskItem task)
    {
        var stack = new StackPanel();
        var title = new TextBlock
        {
            Text = task.DisplayName,
            FontWeight = FontWeights.SemiBold,
            FontSize = 14
        };
        var subtitle = new TextBlock
        {
            Text = $"{task.TaskName}  |  {task.IntervalSummary ?? "—"}",
            Foreground = (Brush)Application.Current.FindResource("SecondaryTextBrush"),
            FontSize = 11,
            Margin = new Thickness(0, 2, 0, 8)
        };

        var stateBrush = task.State switch
        {
            ScheduledTaskState.Ready => (Brush)Application.Current.FindResource("OkBrush"),
            ScheduledTaskState.Running => (Brush)Application.Current.FindResource("OkBrush"),
            ScheduledTaskState.Disabled => (Brush)Application.Current.FindResource("WarnBrush"),
            ScheduledTaskState.NotInstalled => (Brush)Application.Current.FindResource("ErrBrush"),
            _ => (Brush)Application.Current.FindResource("MutedBrush")
        };
        var state = new TextBlock
        {
            Text = task.State.ToString(),
            Foreground = stateBrush,
            FontWeight = FontWeights.Bold,
            Margin = new Thickness(0, 0, 0, 6)
        };

        stack.Children.Add(title);
        stack.Children.Add(subtitle);
        stack.Children.Add(state);

        if (!string.IsNullOrWhiteSpace(task.Description))
        {
            stack.Children.Add(new TextBlock
            {
                Text = task.Description,
                TextWrapping = TextWrapping.Wrap,
                Foreground = (Brush)Application.Current.FindResource("SecondaryTextBrush"),
                FontSize = 11,
                Margin = new Thickness(0, 0, 0, 8)
            });
        }

        var meta = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = (Brush)Application.Current.FindResource("SecondaryTextBrush"),
            FontSize = 11,
            Margin = new Thickness(0, 0, 0, 10)
        };
        var lines = new List<string>();
        if (!string.IsNullOrWhiteSpace(task.LastRunTime))
            lines.Add($"Last run: {task.LastRunTime}");
        if (!string.IsNullOrWhiteSpace(task.NextRunTime))
            lines.Add($"Next run: {task.NextRunTime}");
        if (task.LastResult.HasValue)
            lines.Add($"Last result: {task.LastResult.Value}");
        if (!string.IsNullOrWhiteSpace(task.Detail) && task.State == ScheduledTaskState.NotInstalled)
            lines.Add(task.Detail);
        meta.Text = lines.Count > 0 ? string.Join(Environment.NewLine, lines) : "No schedule info yet.";
        stack.Children.Add(meta);

        var secondary = Application.Current.TryFindResource("SecondaryButton") as Style;
        var controls = new WrapPanel();
        var taskName = task.TaskName;

        var run = new Button { Content = "Run now", Padding = new Thickness(10, 6, 10, 6), Style = secondary, Margin = new Thickness(0, 0, 6, 6) };
        run.Click += async (_, _) => await RunTaskActionAsync(() => App.Session.ScheduledTasks!.Run(taskName));
        controls.Children.Add(run);

        if (task.State != ScheduledTaskState.NotInstalled)
        {
            var enable = new Button { Content = "Enable", Padding = new Thickness(10, 6, 10, 6), Style = secondary, Margin = new Thickness(0, 0, 6, 6) };
            enable.Click += async (_, _) => await RunTaskActionAsync(() => App.Session.ScheduledTasks!.Enable(taskName));
            controls.Children.Add(enable);

            var disable = new Button { Content = "Disable", Padding = new Thickness(10, 6, 10, 6), Style = secondary, Margin = new Thickness(0, 0, 6, 6) };
            disable.Click += async (_, _) => await RunTaskActionAsync(() => App.Session.ScheduledTasks!.Disable(taskName));
            controls.Children.Add(disable);
        }

        if (!string.IsNullOrWhiteSpace(task.StdoutLogFileName) && App.Session.RepoRoot is not null)
        {
            var logBtn = new Button { Content = "View log", Padding = new Thickness(10, 6, 10, 6), Style = secondary, Margin = new Thickness(0, 0, 6, 6) };
            var logName = task.StdoutLogFileName;
            logBtn.Click += (_, _) => OpenLog(logName);
            controls.Children.Add(logBtn);
        }

        if (!string.IsNullOrWhiteSpace(task.StderrLogFileName) && App.Session.RepoRoot is not null)
        {
            var errBtn = new Button { Content = "View error log", Padding = new Thickness(10, 6, 10, 6), Style = secondary, Margin = new Thickness(0, 0, 6, 6) };
            var errName = task.StderrLogFileName;
            errBtn.Click += (_, _) => OpenLog(errName);
            controls.Children.Add(errBtn);
        }

        if (!string.IsNullOrWhiteSpace(task.ManualRunScriptRelativePath))
        {
            var startBtn = new Button { Content = "Start NVIDIA", Padding = new Thickness(10, 6, 10, 6), Style = secondary, Margin = new Thickness(0, 0, 6, 6) };
            var scriptPath = task.ManualRunScriptRelativePath;
            startBtn.Click += (_, _) =>
            {
                if (App.Session.Scripts is null)
                {
                    MessageBox.Show("Repo not configured.", "NextGPU");
                    return;
                }

                var result = App.Session.Scripts.RunPowerShellRelative(scriptPath, "", elevated: false, keepConsoleOpen: true);
                MessageBox.Show(result.Message, result.Success ? "NextGPU" : "NextGPU — error",
                    MessageBoxButton.OK, result.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
            };
            controls.Children.Add(startBtn);
        }

        stack.Children.Add(controls);
        return stack;
    }

    private async Task RunTaskActionAsync(Func<(bool Success, string Message)> action)
    {
        if (App.Session.ScheduledTasks is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var result = await Task.Run(action).ConfigureAwait(true);
        MessageBox.Show(result.Message, result.Success ? "NextGPU" : "NextGPU — error",
            MessageBoxButton.OK, result.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
        await RefreshAsync();
    }

    private static void OpenLog(string logFileName)
    {
        if (App.Session.RepoRoot is null)
            return;
        var path = Path.Combine(RepoRootResolver.LogsDirectory(App.Session.RepoRoot), logFileName);
        if (File.Exists(path))
        {
            Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            return;
        }

        if (Application.Current.MainWindow is MainWindow mw)
            mw.NavigateToLogs(logFileName);
        else
            MessageBox.Show($"Log not found yet: {path}", "NextGPU", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    private void OpenTaskSchedulerApp_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            Process.Start(new ProcessStartInfo("taskschd.msc") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "NextGPU", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }
}
