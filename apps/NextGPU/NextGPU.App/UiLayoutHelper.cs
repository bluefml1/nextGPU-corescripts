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
}
