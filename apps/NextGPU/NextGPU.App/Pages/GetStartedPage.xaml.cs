using System.Collections.Generic;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using NextGPU.App;

namespace NextGPU.App.Pages;

public partial class GetStartedPage : Page
{
    private sealed record StepItem(
        string Number,
        string Title,
        string Description,
        string PrimaryLabel,
        Action PrimaryAction,
        string? SecondaryLabel = null,
        Action? SecondaryAction = null);
    private sealed record TroubleItem(
        string Problem,
        string Fix,
        string ActionLabel,
        Action Action);

    public GetStartedPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            BuildSteps();
            BuildTroubleshooting();
        };
    }

    private void BuildSteps()
    {
        StepsPanel.Children.Clear();
        foreach (var step in CreateSteps())
        {
            StepsPanel.Children.Add(CreateStepCard(step));
        }
    }

    private IEnumerable<StepItem> CreateSteps()
    {
        return new[]
        {
            new StepItem(
                "01",
                "Validate Environment",
                "Confirm repo layout and required scripts before provisioning.",
                "Run Layout Test",
                () => RunCapture(@"scripts\maintenance\Test-NextGpuLayout.ps1", ""),
                "Open Settings",
                () => NavigateTo(new SettingsPage())),
            new StepItem(
                "02",
                "Disk Prep",
                "Run CHKDSK repair, then shrink a drive and extend existing Z: (or create a new data volume) before sync.",
                "Open Disk Management",
                () => NavigateTo(new DiskManagementPage()),
                "Run CHKDSK Repair",
                () => RunPowerShell(@"scripts\maintenance\Run-ChkDsk-Repair.ps1", "", keepConsoleOpen: true)),
            new StepItem(
                "03",
                "Sync Official Game Data",
                "Install rclone dependencies, verify remote access, then fetch official S3 data with logs/speed/ETA.",
                "Sync Game/Apps",
                () => RunBatch(@"scripts\maintenance\sync-games-apps-official.bat", keepConsoleOpen: true),
                "Open User Experience",
                () => NavigateTo(new UserExperiencePage())),
            new StepItem(
                "04",
                "Provision Full Host",
                "Run the complete NextGPU provisioning flow (services, tasks, Sunshine/Moonlight/tunnel integration).",
                "Run RegisterMachine",
                () => RunBatch(@"RegisterMachine_Beta.bat", keepConsoleOpen: true),
                "Open Provisioning Logs",
                () => NavigateLogs("sunshine-bind.log")),
            new StepItem(
                "05",
                "Verify Host Is Ready",
                "Verify with this checklist: (1) Sunshine session starts, (2) wallpaper policy is applied, (3) required drivers exist, (4) key services are healthy, (5) logs show no critical errors.",
                "Run Wallpaper Verification",
                () => RunCapture(@"scripts\desktop\Test-WallpaperPolicy.ps1", ""),
                "Open Logs Page",
                () => NavigateTo(new LogsPage()))
        };
    }

    private void BuildTroubleshooting()
    {
        TroubleshootingPanel.Children.Clear();
        foreach (var item in CreateTroubleshootingItems())
        {
            TroubleshootingPanel.Children.Add(CreateTroubleshootingCard(item));
        }
    }

    private IEnumerable<TroubleItem> CreateTroubleshootingItems()
    {
        return new[]
        {
            new TroubleItem(
                "Black screen in Moonlight/session stream",
                "Usually display stack is not fully ready yet. Start Sunshine in user session, then run API restart/display refresh, and re-apply wallpaper after display ready.",
                "Open Sunshine Page",
                () => NavigateTo(new SunshinePage())),
            new TroubleItem(
                "VDD virtual display not detected",
                "Reinstall VDD driver, then run display device probe and verify Sunshine output binding matches detected display device ID.",
                "Open VDD-VAD Page",
                () => NavigateTo(new VddVadPage())),
            new TroubleItem(
                "VAD virtual audio not detected / no stream audio",
                "Reinstall VAD package and validate Windows playback device selection. Re-run full host provisioning if audio services are incomplete.",
                "Install VDD/VAD",
                () => RunBatch(@"scripts\drivers\InstallVDD-VAD.bat")),
            new TroubleItem(
                "rclone/WinFsp install shows warning even after success",
                "winget can return non-zero exit while package is already installed. Continue if tools are detected, then rerun sync.",
                "Run Sync Again",
                () => RunBatch(@"scripts\maintenance\sync-games-apps-official.bat", keepConsoleOpen: true)),
            new TroubleItem(
                "Remote preflight fails but S3 items are listed",
                "This is now treated as warning when output is present. Verify credentials and bucket name if listing is empty.",
                "Open Sync Logs",
                () => NavigateTo(new LogsPage())),
            new TroubleItem(
                "Wallpaper is cropped or desktop icons still visible",
                "Re-apply wallpaper policy and run verification. For Moonlight/VDD cases, start Sunshine in-session so delayed wallpaper apply can run.",
                "Run Wallpaper Verification",
                () => RunCapture(@"scripts\desktop\Test-WallpaperPolicy.ps1", "")),
            new TroubleItem(
                "Sunshine API restart/TLS error",
                "Use the in-session launcher and API restart helper; self-signed localhost TLS can cause false failures in raw curl calls.",
                "Start Sunshine In-Session",
                () => RunPowerShell(@"scripts\provisioning\Start-Sunshine-InSession.ps1", "", keepConsoleOpen: true)),
            new TroubleItem(
                "Cannot shrink partition during disk prep",
                "Disable hibernation/pagefile/restore points, reboot, and retry partition creation from Disk Management page.",
                "Open Disk Management",
                () => NavigateTo(new DiskManagementPage()))
        };
    }

    private UIElement CreateStepCard(StepItem step)
    {
        var border = new Border
        {
            Style = (Style)FindResource("CardBorder"),
            Margin = new Thickness(0, 0, 12, 12),
            MinHeight = 200
        };

        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = $"STEP {step.Number}",
            Foreground = (Brush)FindResource("LinkAccentBrush"),
            FontWeight = FontWeights.Bold,
            FontSize = 11
        });
        stack.Children.Add(new TextBlock
        {
            Text = step.Title,
            FontSize = 17,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 4, 0, 6),
            TextWrapping = TextWrapping.Wrap
        });
        stack.Children.Add(new TextBlock
        {
            Text = step.Description,
            Foreground = (Brush)FindResource("SecondaryTextBrush"),
            Margin = new Thickness(0, 0, 0, 12),
            TextWrapping = TextWrapping.Wrap,
            LineHeight = 20
        });

        var buttonRow = new StackPanel();
        var primary = new Button
        {
            Content = step.PrimaryLabel,
            Style = (Style)FindResource("PrimaryButton")
        };
        primary.Click += (_, _) => step.PrimaryAction();
        UiLayoutHelper.AddStretchedAction(buttonRow, primary);

        if (step.SecondaryLabel is not null && step.SecondaryAction is not null)
        {
            var sec = new Button
            {
                Content = step.SecondaryLabel,
                Style = (Style)FindResource("SecondaryButton")
            };
            sec.Click += (_, _) => step.SecondaryAction();
            UiLayoutHelper.AddStretchedAction(buttonRow, sec);
        }

        stack.Children.Add(buttonRow);
        border.Child = stack;
        return border;
    }

    private UIElement CreateTroubleshootingCard(TroubleItem item)
    {
        var border = new Border
        {
            Style = (Style)FindResource("CardBorder"),
            Margin = new Thickness(0, 0, 0, 12)
        };

        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = item.Problem,
            FontSize = 16,
            FontWeight = FontWeights.SemiBold,
            TextWrapping = TextWrapping.Wrap
        });
        stack.Children.Add(new TextBlock
        {
            Text = item.Fix,
            Foreground = (Brush)FindResource("SecondaryTextBrush"),
            Margin = new Thickness(0, 6, 0, 10),
            TextWrapping = TextWrapping.Wrap
        });

        var actionButton = new Button
        {
            Content = item.ActionLabel,
            Style = (Style)FindResource("SecondaryButton"),
            HorizontalAlignment = HorizontalAlignment.Left,
            MinWidth = 200
        };
        actionButton.Click += (_, _) => item.Action();
        stack.Children.Add(actionButton);

        border.Child = stack;
        return border;
    }

    private void NavigateTo(Page page)
    {
        if (Application.Current.MainWindow is MainWindow mw)
            mw.NavigateTo(page);
    }

    private void NavigateLogs(string? preferred = null)
    {
        if (Application.Current.MainWindow is MainWindow mw)
            mw.NavigateToLogs(preferred);
    }

    private void RunBatch(string relativePath, bool keepConsoleOpen = false)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }
        var r = App.Session.Scripts.RunBatchRelative(relativePath, elevated: true, keepConsoleOpen: keepConsoleOpen);
        ShowResult(r);
    }

    private void RunPowerShell(string relativePath, string args, bool keepConsoleOpen = false)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }
        var r = App.Session.Scripts.RunPowerShellRelative(relativePath, args, elevated: true, keepConsoleOpen: keepConsoleOpen);
        ShowResult(r);
    }

    private void RunCapture(string relativePath, string args)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }
        var r = App.Session.Scripts.RunPowerShellCapture(relativePath, args);
        MessageBox.Show(r.Message, r.Success ? "Output" : "Error", MessageBoxButton.OK,
            r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }

    private static void ShowResult((bool Success, string Message) result)
    {
        MessageBox.Show(result.Message, "NextGPU", MessageBoxButton.OK,
            result.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }
}
