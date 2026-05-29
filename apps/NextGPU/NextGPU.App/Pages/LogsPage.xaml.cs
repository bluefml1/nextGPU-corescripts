using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using NextGPU.Core;

namespace NextGPU.App.Pages;

public partial class LogsPage : Page
{
    private string _fullText = "";
    private string? _selectedFile;
    private readonly string? _preferredLogFile;

    public LogsPage(string? preferredLogFile = null)
    {
        InitializeComponent();
        _preferredLogFile = preferredLogFile;
    }

    private void Page_Loaded(object sender, RoutedEventArgs e)
    {
        if (App.Session.RepoRoot is null || App.Session.LogTail is null)
        {
            LogText.Text = "Repo not found. Configure repo path in Settings.";
            return;
        }

        LogCombo.Items.Clear();
        foreach (var f in App.Session.LogTail.ListLogFiles())
            LogCombo.Items.Add(f);

        SelectPreferredLog();

        if (LogCombo.Items.Count > 0 && LogCombo.SelectedIndex < 0)
            LogCombo.SelectedIndex = 0;

        LogCombo.SelectionChanged += LogCombo_SelectionChanged;
    }

    private void SelectPreferredLog()
    {
        if (string.IsNullOrWhiteSpace(_preferredLogFile))
            return;
        foreach (var item in LogCombo.Items)
        {
            if (item is string s && string.Equals(s, _preferredLogFile, StringComparison.OrdinalIgnoreCase))
            {
                LogCombo.SelectedItem = item;
                return;
            }
        }
    }

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        App.Session.LogTail?.StopWatch();
        LogCombo.SelectionChanged -= LogCombo_SelectionChanged;
    }

    private void LogCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (LogCombo.SelectedItem is not string file)
            return;
        _selectedFile = file;
        ReloadContent();
        ApplyTail();
    }

    private void Tail_Changed(object sender, RoutedEventArgs e) => ApplyTail();

    private void ApplyTail()
    {
        if (App.Session.LogTail is null || _selectedFile is null)
            return;

        App.Session.LogTail.StopWatch();
        if (TailCheck.IsChecked == true)
        {
            App.Session.LogTail.ContentUpdated -= OnTail;
            App.Session.LogTail.ContentUpdated += OnTail;
            App.Session.LogTail.Watch(_selectedFile);
        }
    }

    private void OnTail(string chunk)
    {
        Dispatcher.Invoke(() =>
        {
            _fullText += chunk;
            if (_fullText.Length > 500_000)
                _fullText = _fullText[^400_000..];
            ApplyFilter();
            LogText.ScrollToEnd();
        });
    }

    private void Reload_Click(object sender, RoutedEventArgs e) => ReloadContent();

    private void ReloadContent()
    {
        if (App.Session.LogTail is null || _selectedFile is null)
            return;
        _fullText = App.Session.LogTail.ReadAll(_selectedFile, maxLines: 15_000);
        ApplyFilter();
    }

    private void ApplyFilter()
    {
        var filter = FilterBox.Text?.Trim();
        if (string.IsNullOrEmpty(filter))
        {
            LogText.Text = _fullText;
            return;
        }

        var lines = _fullText.Split(new[] { "\r\n", "\n" }, StringSplitOptions.None);
        LogText.Text = string.Join(Environment.NewLine,
            lines.Where(l => l.Contains(filter, StringComparison.OrdinalIgnoreCase)));
    }

    private void OpenLogsFolder_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.LogTail is null)
            return;
        Process.Start(new ProcessStartInfo
        {
            FileName = "explorer.exe",
            Arguments = App.Session.LogTail.LogsDirectory,
            UseShellExecute = true
        });
    }

    private void OpenEditor_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.RepoRoot is null || _selectedFile is null)
            return;
        var path = App.Session.LogTail!.GetLogPath(_selectedFile);
        if (!File.Exists(path))
        {
            MessageBox.Show("Log file does not exist yet.", "NextGPU");
            return;
        }
        Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    private void CopyAll_Click(object sender, RoutedEventArgs e)
    {
        Clipboard.SetText(LogText.Text);
        MessageBox.Show("Copied to clipboard.", "NextGPU");
    }

    private void FilterBox_TextChanged(object sender, TextChangedEventArgs e) => ApplyFilter();
}
