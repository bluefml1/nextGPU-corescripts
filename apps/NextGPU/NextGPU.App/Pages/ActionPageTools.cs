using System;
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

    public static void AddBatchButton(Panel panel, string label, string relativePath, bool keepConsoleOpen = false, string? confirm = null)
    {
        AddToPanel(panel, MakeButton(label, $"Runs {relativePath} elevated.", (_, _) =>
        {
            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            if (!Confirm(confirm)) return;
            var r = App.Session.Scripts.RunBatchRelative(relativePath, elevated: true, keepConsoleOpen: keepConsoleOpen);
            ShowResult(r);
        }));
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
