using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace NextGPU.App;

internal static class UiLayoutHelper
{
    public static Style? GetStyle(string key) =>
        Application.Current.TryFindResource(key) as Style;

    public static Brush GetBrush(string key) =>
        (Brush)Application.Current.FindResource(key);

    public static void StyleAsCard(Border border, bool elevated = false)
    {
        border.Style = GetStyle(elevated ? "PageHeaderCard" : "CardBorder");
    }

    public static StackPanel CreateVerticalActionPanel() => new();

    public static void AddStretchedAction(StackPanel panel, Button button)
    {
        button.HorizontalAlignment = HorizontalAlignment.Stretch;
        button.HorizontalContentAlignment = HorizontalAlignment.Left;
        button.Margin = new Thickness(0, 0, 0, 8);
        panel.Children.Add(button);
    }

    public static void AddStretchedActionWithHelp(StackPanel panel, Button button, string helpText, string? title = null)
    {
        var row = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        button.HorizontalAlignment = HorizontalAlignment.Stretch;
        button.HorizontalContentAlignment = HorizontalAlignment.Left;
        button.Margin = new Thickness(0);
        Grid.SetColumn(button, 0);
        row.Children.Add(button);

        var help = CreateHelpButton(helpText, title ?? button.Content?.ToString() ?? "Help");
        Grid.SetColumn(help, 1);
        row.Children.Add(help);

        panel.Children.Add(row);
    }

    public static FrameworkElement WrapInlineActionWithHelp(Button button, string helpText, string? title = null, Thickness? margin = null)
    {
        var row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Margin = margin ?? new Thickness(0, 0, 8, 8)
        };
        row.Children.Add(button);
        row.Children.Add(CreateHelpButton(helpText, title ?? button.Content?.ToString() ?? "Help"));
        return row;
    }

    public static Button CreateHelpButton(string helpText, string title)
    {
        var btn = new Button
        {
            Content = "?",
            Style = GetStyle("HelpIconButton"),
            ToolTip = "What does this do?",
            Margin = new Thickness(6, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center
        };
        btn.Click += (_, _) => MessageBox.Show(helpText, title, MessageBoxButton.OK, MessageBoxImage.Information);
        return btn;
    }
}
