using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;

namespace NextGPU.App.Pages;

internal static class ActionPageTools
{
    public static Button MakeButton(string label, string tooltip, RoutedEventHandler onClick)
    {
        var btn = new Button
        {
            Content = label,
            ToolTip = tooltip,
            Padding = new Thickness(14, 10, 14, 10),
            Style = (Style)Application.Current.FindResource("SecondaryButton")
        };
        btn.Click += onClick;
        return btn;
    }

    private static void AddToPanel(Panel panel, Button btn)
    {
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedAction(stack, btn);
        else
            panel.Children.Add(btn);
    }

    public static void AddPrimaryPowerShellButton(
        Panel panel,
        string label,
        string relativePath,
        string args = "",
        bool keepConsoleOpen = false,
        string? tooltip = null)
    {
        var btn = new Button
        {
            Content = label,
            ToolTip = tooltip ?? $"Runs {relativePath}",
            Padding = new Thickness(14, 10, 14, 10),
            Style = (Style)Application.Current.FindResource("PrimaryButton")
        };
        btn.Click += (_, _) =>
        {
            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = App.Session.Scripts.RunPowerShellRelative(relativePath, args, elevated: true, keepConsoleOpen: keepConsoleOpen);
            ShowResult(r);
        };
        AddToPanel(panel, btn);
    }

    public static void AddOpenExplorerButton(Panel panel, string label, string folderPath, string? tooltip = null)
    {
        AddOpenExplorerButton(panel, label, () => folderPath, tooltip);
    }

    public static void AddOpenExplorerButton(Panel panel, string label, Func<string> folderPathFactory, string? tooltip = null)
    {
        AddToPanel(panel, MakeButton(label, tooltip ?? "Open folder in Explorer", (_, _) =>
        {
            var folder = folderPathFactory();
            if (string.IsNullOrWhiteSpace(folder))
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            try
            {
                if (!Directory.Exists(folder))
                    Directory.CreateDirectory(folder);
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Could not create folder:\n{folder}\n{ex.Message}", "NextGPU",
                    MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }
            Process.Start(new ProcessStartInfo
            {
                FileName = "explorer.exe",
                Arguments = folder,
                UseShellExecute = true
            });
        }));
    }

    public static void AddPrimaryBatchButton(
        Panel panel,
        string label,
        string relativePath,
        string? arguments = null,
        bool keepConsoleOpen = false,
        string? confirm = null,
        string? tooltip = null)
    {
        var btn = new Button
        {
            Content = label,
            ToolTip = tooltip ?? $"Runs {relativePath} elevated.",
            Padding = new Thickness(14, 10, 14, 10),
            Style = (Style)Application.Current.FindResource("PrimaryButton")
        };
        btn.Click += (_, _) => RunBatch(panel, relativePath, arguments, keepConsoleOpen, confirm);
        AddToPanel(panel, btn);
    }

    public static void AddBatchButton(
        Panel panel,
        string label,
        string relativePath,
        string? arguments = null,
        bool keepConsoleOpen = false,
        string? confirm = null,
        string? tooltip = null)
    {
        AddToPanel(panel, MakeButton(label, tooltip ?? $"Runs {relativePath} elevated.", (_, _) =>
            RunBatch(panel, relativePath, arguments, keepConsoleOpen, confirm)));
    }

    private static void RunBatch(Panel panel, string relativePath, string? arguments, bool keepConsoleOpen, string? confirm)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }
        if (!Confirm(confirm)) return;
        var r = App.Session.Scripts.RunBatchRelative(relativePath, elevated: true, arguments: arguments, keepConsoleOpen: keepConsoleOpen);
        ShowResult(r);
    }

    public static void AddPowerShellButton(Panel panel, string label, string relativePath, string args = "", bool keepConsoleOpen = false, string? tooltip = null)
    {
        AddToPanel(panel, MakeButton(label, tooltip ?? $"Runs {relativePath}", (_, _) =>
        {
            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = App.Session.Scripts.RunPowerShellRelative(relativePath, args, elevated: true, keepConsoleOpen: keepConsoleOpen);
            ShowResult(r);
        }));
    }

    public static void AddCaptureButton(Panel panel, string label, string relativePath, string args = "")
    {
        AddToPanel(panel, MakeButton(label, $"Runs and captures output: {relativePath}", (_, _) =>
        {
            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = App.Session.Scripts.RunPowerShellCapture(relativePath, args);
            MessageBox.Show(r.Message, r.Success ? label : "Error", MessageBoxButton.OK,
                r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
        }));
    }

    public static void AddServiceButton(Panel panel, string label, Func<(bool Success, string Message)> action, string tooltip)
    {
        AddToPanel(panel, MakeButton(label, tooltip, async (_, _) =>
        {
            if (App.Session.Services is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = await Task.Run(action);
            ShowResult(r);
        }));
    }

    public static void AddNavigateButton(Panel panel, string label, string tooltip, Action navigate)
    {
        AddToPanel(panel, MakeButton(label, tooltip, (_, _) => navigate()));
    }

    public static void AddOpenLogsButton(Panel panel, string label, string? preferredLog)
    {
        AddToPanel(panel, MakeButton(label, "Open Logs tab with selected log file.", (_, _) =>
        {
            if (Application.Current.MainWindow is MainWindow mw)
                mw.NavigateToLogs(preferredLog);
        }));
    }

    private static bool Confirm(string? message)
    {
        if (string.IsNullOrWhiteSpace(message))
            return true;
        return MessageBox.Show(message, "NextGPU", MessageBoxButton.YesNo, MessageBoxImage.Warning) == MessageBoxResult.Yes;
    }

    private static void ShowResult((bool Success, string Message) r)
    {
        MessageBox.Show(r.Message, "NextGPU", MessageBoxButton.OK,
            r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }
}
