using System.Windows;
using System.Windows.Controls;

namespace NextGPU.App.Pages;

public partial class SettingsPage : Page
{
    public SettingsPage()
    {
        InitializeComponent();
        Loaded += (_, _) =>
        {
            RepoBox.Text = App.Session.Settings.RepoRootOverride ?? "";
            var sec = App.Session.Settings.RefreshIntervalSeconds;
            IntervalCombo.SelectedItem = IntervalCombo.Items.Cast<ComboBoxItem>()
                .FirstOrDefault(i => i.Content?.ToString() == sec.ToString())
                ?? IntervalCombo.Items[1];
        };
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var repo = RepoBox.Text.Trim();
        App.Session.Settings.RepoRootOverride = string.IsNullOrWhiteSpace(repo) ? null : repo;
        if (IntervalCombo.SelectedItem is ComboBoxItem item &&
            int.TryParse(item.Content?.ToString(), out var seconds))
        {
            App.Session.Settings.RefreshIntervalSeconds = seconds;
        }

        App.Session.Settings.Save();
        App.Session.ResolveRepo();
        StatusText.Text = App.Session.RepoRoot is null
            ? "Saved. Repo still not found — check path or set NEXTGPU_REPO_ROOT."
            : $"Saved. Repo: {App.Session.RepoRoot}";
        MessageBox.Show("Settings saved. Re-open Dashboard to apply refresh interval.", "NextGPU");
    }

    private void OpenGetStarted_Click(object sender, RoutedEventArgs e)
    {
        if (Application.Current.MainWindow is MainWindow mw)
            mw.NavigateTo(new GetStartedPage());
    }
}
