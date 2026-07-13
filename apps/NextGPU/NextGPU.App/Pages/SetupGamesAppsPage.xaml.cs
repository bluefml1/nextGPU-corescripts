using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using NextGPU.App;
using NextGPU.Core;

namespace NextGPU.App.Pages;

public partial class SetupGamesAppsPage : Page
{
    private readonly List<SessionFolderRuleEntry> _allRules = [];
    private readonly ObservableCollection<SessionFolderRuleEntry> _rulesGridItems = [];
    private bool _suppressRulesGridSave;

    private static string ProgramDataNextGpu =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "nextGPU");

    private static string RulesConfigPath => Path.Combine(ProgramDataNextGpu, "session-folder-rules.json");

    private static string SessionTemplatesPath => Path.Combine(ProgramDataNextGpu, "session-templates");

    public SetupGamesAppsPage()
    {
        InitializeComponent();
        Loaded += (_, _) => OnLoaded();
    }

    private void OnLoaded()
    {
        RulesGrid.ItemsSource = _rulesGridItems;
        BuildHostSetupButtons();
        BuildRulesActionButtons();
        BuildCleanSessionButtons();
        LoadRulesSummary();
    }

    private void BuildHostSetupButtons()
    {
        HostSetupPanel.Children.Clear();

        ActionPageTools.AddNavigateButton(HostSetupPanel, "User Storage (U:) — setup & mount",
            "Open the dedicated User Storage page (Admin RDP + Moonlight workflow).",
            () =>
            {
                if (Application.Current.MainWindow is MainWindow mw)
                    mw.NavigateTo(new UserStoragePage());
            });
        ActionPageTools.AddBatchButton(HostSetupPanel, "Sync Game/Apps Officially",
            @"scripts\maintenance\sync-games-apps-official.bat", keepConsoleOpen: true);
        ActionPageTools.AddBatchButton(HostSetupPanel, "Setup Games & Apps",
            @"scripts\maintenance\arrange-games-apps.bat", keepConsoleOpen: true,
            helpText: "Runs arrange-games-apps.bat (one-time host layout). Does not touch session folder rules.");
        ActionPageTools.AddBatchButton(HostSetupPanel, "Push Zip to R2 Origin",
            @"scripts\maintenance\push-games-apps-to-r2.bat", keepConsoleOpen: true);
        AddPushMoonlightGamesButton(HostSetupPanel);
        ActionPageTools.AddBatchButton(HostSetupPanel, "Update Games API (Manual)",
            @"scripts\maintenance\updateGames.bat", keepConsoleOpen: true,
            helpText: "Same as Push to AWS but prompts for computer_name and publicIP in the console if domain.txt values are not accepted.");
        ActionPageTools.AddBatchButton(HostSetupPanel, "Network Copy", @"scripts\maintenance\copy.bat");
        ActionPageTools.AddBatchButton(HostSetupPanel, "Extract Archives", @"scripts\maintenance\extract.bat");
        ActionPageTools.AddOpenLogsButton(HostSetupPanel, "Open Network Copy Log", "network_copy.log");
    }

    private static void AddPushMoonlightGamesButton(Panel panel)
    {
        const string relativePath = @"scripts\maintenance\updateGames.bat";
        var btn = new Button
        {
            Content = "Push Moonlight Games to AWS",
            ToolTip = "Push current Moonlight apps to AWS using domain.txt",
            Padding = new Thickness(14, 10, 14, 10),
            Style = (Style)Application.Current.FindResource("PrimaryButton")
        };
        btn.Click += (_, _) =>
        {
            if (App.Session.Scripts is null || string.IsNullOrWhiteSpace(App.Session.RepoRoot))
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }

            var domain = DomainFileReader.Read(App.Session.RepoRoot);
            if (string.IsNullOrWhiteSpace(domain.ComputerName) || string.IsNullOrWhiteSpace(domain.PublicIp))
            {
                MessageBox.Show(
                    "domain.txt is missing COMPUTER_NAME or PUBLIC_IP.\n\n" +
                    "Run Register Machine setup first, or create domain.txt at the repo root.",
                    "NextGPU", MessageBoxButton.OK, MessageBoxImage.Warning);
                return;
            }

            var confirm = $"Push Moonlight games to AWS?\n\n" +
                          $"computer_name: {domain.ComputerName}\n" +
                          $"publicIP: {domain.PublicIp}\n\n" +
                          "Requires Moonlight Web on localhost:8080.";
            if (MessageBox.Show(confirm, "NextGPU", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes)
                return;

            var r = App.Session.Scripts.RunBatchRelative(relativePath, elevated: true, arguments: "/UseDomainTxt", keepConsoleOpen: true);
            MessageBox.Show(r.Message, "NextGPU", MessageBoxButton.OK,
                r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
        };
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn,
                "Reads COMPUTER_NAME and PUBLIC_IP from domain.txt, fetches apps from Moonlight Web, and posts them to the AWS updateNewGame API.");
        else
            panel.Children.Add(btn);
    }

    private void BuildRulesActionButtons()
    {
        RulesFormActionsPanel.Children.Clear();
        RulesGridActionsPanel.Children.Clear();

        AddInlineButton(RulesFormActionsPanel, "Add / Update Rule", AddOrUpdateRule_Click, "PrimaryButton");
        AddInlineButton(RulesFormActionsPanel, "Import JSON", ImportRules_Click, "SecondaryButton");
        AddInlineButton(RulesFormActionsPanel, "Export JSON", ExportRules_Click, "SecondaryButton");
        AddInlineButton(RulesFormActionsPanel, "Open Rules JSON", OpenRulesJson_Click, "GhostButton");

        RulesGridActionsPanel.Children.Add(RulesFilterBox);
        AddInlineButton(RulesGridActionsPanel, "Refresh", RefreshRules_Click, "GhostButton");
        AddInlineButton(RulesGridActionsPanel, "Delete Selected", DeleteSelectedRules_Click, "SecondaryButton");
    }

    private void BuildCleanSessionButtons()
    {
        CleanSessionActionsPanel.Children.Clear();

        ActionPageTools.AddPowerShellButton(CleanSessionActionsPanel, "Register Session Folder Tasks",
            @"scripts\runtime\Register-SessionFolderRulesTasks.ps1", keepConsoleOpen: true,
            helpText: "Registers nextGPU-SessionFolderRulesLogoff and nextGPU-SessionFolderRulesLogon scheduled tasks.");
        ActionPageTools.AddPowerShellButton(CleanSessionActionsPanel, "Seed Garena Template",
            @"scripts\runtime\Seed-SessionFolderTemplates.ps1", "-SeedGarena", keepConsoleOpen: true,
            helpText: "Copies gxx from the on-disk Garena bundle into ProgramData\\nextGPU\\session-templates\\garena-gxx.");
        ActionPageTools.AddOpenExplorerButton(CleanSessionActionsPanel, "Open session-templates Folder",
            () => EnsureDirectory(SessionTemplatesPath),
            helpText: "Golden replace sources live under C:\\ProgramData\\nextGPU\\session-templates\\{rule-id}\\.");
        ActionPageTools.AddPowerShellButton(CleanSessionActionsPanel, "Run Logoff Rules (test)",
            @"scripts\runtime\Invoke-SessionFolderRules.ps1", "-Phase Logoff", keepConsoleOpen: true,
            helpText: "Manual test of logoff-phase rules (same as endSession STEP 0).");
        AddOpenProgramDataLogButton();
    }

    private void AddOpenProgramDataLogButton()
    {
        var logPath = Path.Combine(ProgramDataNextGpu, "logs", RepoCatalog.SessionFolderRulesLog);
        var btn = ActionPageTools.MakeButton("Open Session Rules Log", "Open session-folder-rules.log",
            (_, _) =>
            {
                var dir = Path.GetDirectoryName(logPath);
                if (!string.IsNullOrWhiteSpace(dir))
                    Directory.CreateDirectory(dir);
                if (!File.Exists(logPath))
                    File.WriteAllText(logPath, "");
                try
                {
                    Process.Start(new ProcessStartInfo("notepad.exe", $"\"{logPath}\"") { UseShellExecute = true });
                }
                catch (Exception ex)
                {
                    MessageBox.Show(ex.Message, "NextGPU");
                }
            });
        if (CleanSessionActionsPanel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn, "Runtime log at C:\\ProgramData\\nextGPU\\logs\\session-folder-rules.log");
        else
            CleanSessionActionsPanel.Children.Add(btn);
    }

    private static void AddInlineButton(Panel panel, string label, RoutedEventHandler onClick, string styleKey)
    {
        var btn = new Button
        {
            Content = label,
            Style = (Style)Application.Current.FindResource(styleKey),
            Padding = new Thickness(styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10,
                styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10),
            Margin = new Thickness(0, 0, 8, 8)
        };
        btn.Click += onClick;
        panel.Children.Add(btn);
    }

    private static string EnsureDirectory(string path)
    {
        if (!Directory.Exists(path))
            Directory.CreateDirectory(path);
        return path;
    }

    private void EnsureRulesConfigFile()
    {
        var dir = Path.GetDirectoryName(RulesConfigPath);
        if (!string.IsNullOrWhiteSpace(dir) && !Directory.Exists(dir))
            Directory.CreateDirectory(dir);

        if (File.Exists(RulesConfigPath))
            return;

        var repo = App.Session.RepoRoot;
        if (!string.IsNullOrWhiteSpace(repo))
        {
            var template = Path.Combine(repo, "config", "session-folder-rules.json.template");
            if (File.Exists(template))
            {
                File.Copy(template, RulesConfigPath);
                return;
            }
        }

        File.WriteAllText(RulesConfigPath,
            """
            {
              "_comment": "Logoff runs all rules. Logon re-runs rules with logonFallback when verification fails.",
              "rules": []
            }
            """);
    }

    private void LoadRulesSummary()
    {
        ReloadRules();
        RulesCountText.Text = _allRules.Count == 0
            ? "No session folder rules yet."
            : $"{_allRules.Count} rule(s) in {RulesConfigPath}";
        ApplyRulesFilter();
    }

    private void ReloadRules()
    {
        _allRules.Clear();
        EnsureRulesConfigFile();

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(RulesConfigPath));
            if (!doc.RootElement.TryGetProperty("rules", out var rules) || rules.ValueKind != JsonValueKind.Array)
                return;

            foreach (var rule in rules.EnumerateArray())
            {
                var preserve = ReadStringArray(rule, "preserve");
                var stopProcesses = ReadStringArray(rule, "stopProcesses");
                _allRules.Add(new SessionFolderRuleEntry
                {
                    OriginalId = rule.TryGetProperty("id", out var idEl) ? idEl.GetString() ?? "" : "",
                    Id = rule.TryGetProperty("id", out var id) ? id.GetString() ?? "" : "",
                    Title = rule.TryGetProperty("title", out var title) ? title.GetString() ?? "" : "",
                    Action = rule.TryGetProperty("action", out var action) ? action.GetString() ?? "" : "",
                    Target = rule.TryGetProperty("target", out var target) ? target.GetString() ?? "" : "",
                    Source = rule.TryGetProperty("source", out var source) ? source.GetString() ?? "" : "",
                    Preserve = preserve,
                    StopProcesses = stopProcesses,
                    PreserveText = FormatEditableList(preserve),
                    StopProcessesText = FormatEditableList(stopProcesses),
                    LogonFallback = !rule.TryGetProperty("logonFallback", out var lf) || lf.ValueKind == JsonValueKind.True
                });
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not read session folder rules: {ex.Message}", "Clean Session");
        }
    }

    private static string[] ReadStringArray(JsonElement parent, string name)
    {
        if (!parent.TryGetProperty(name, out var arr) || arr.ValueKind != JsonValueKind.Array)
            return [];
        return arr.EnumerateArray()
            .Select(e => e.GetString() ?? "")
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .ToArray();
    }

    private static string FormatEditableList(string[] items)
    {
        if (items.Length == 0)
            return "";
        return string.Join(", ", items);
    }

    private void RuleTargetBrowse_Click(object sender, RoutedEventArgs e)
    {
        var picked = FolderPicker.PickFolder(RuleTargetBox.Text, "Select target folder to reset each session");
        if (!string.IsNullOrWhiteSpace(picked))
            RuleTargetBox.Text = picked;
    }

    private void RuleSourceBrowse_Click(object sender, RoutedEventArgs e)
    {
        var picked = FolderPicker.PickFolder(RuleSourceBox.Text, "Select golden template source folder");
        if (!string.IsNullOrWhiteSpace(picked))
            RuleSourceBox.Text = picked;
    }

    private void RulesGrid_BeginningEdit(object sender, DataGridBeginningEditEventArgs e)
    {
        if (_suppressRulesGridSave)
            return;

        var header = e.Column.Header?.ToString();
        if (header is not ("target" or "source"))
            return;
        if (e.Row.Item is not SessionFolderRuleEntry entry)
            return;

        e.Cancel = true;

        var current = header == "target" ? entry.Target : entry.Source;
        var description = header == "target"
            ? "Select target folder to reset each session"
            : "Select golden template source folder";
        var picked = FolderPicker.PickFolder(current, description);
        if (string.IsNullOrWhiteSpace(picked))
            return;

        var unchanged = string.Equals(current, picked, StringComparison.OrdinalIgnoreCase);
        if (header == "target")
            entry.Target = picked;
        else
            entry.Source = picked;

        if (!unchanged)
            DeferRulesGridSave(entry);
    }

    private void RulesGrid_CellEditEnding(object sender, DataGridCellEditEndingEventArgs e)
    {
        if (_suppressRulesGridSave || e.EditAction != DataGridEditAction.Commit)
            return;
        if (e.Row.Item is not SessionFolderRuleEntry entry)
            return;

        Dispatcher.BeginInvoke(() => DeferRulesGridSave(entry), DispatcherPriority.ApplicationIdle);
    }

    private void DeferRulesGridSave(SessionFolderRuleEntry entry)
    {
        RulesGrid.CommitEdit(DataGridEditingUnit.Row, true);

        if (!SaveRuleEntry(entry, showSuccess: false))
            LoadRulesSummary();
    }

    private bool SaveRuleEntry(SessionFolderRuleEntry entry, bool showSuccess = true)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return false;
        }

        var id = (entry.Id ?? "").Trim();
        var title = (entry.Title ?? "").Trim();
        var action = (entry.Action ?? "").Trim().ToLowerInvariant();
        var target = (entry.Target ?? "").Trim();

        if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(title) ||
            string.IsNullOrWhiteSpace(action) || string.IsNullOrWhiteSpace(target))
        {
            MessageBox.Show("Id, Title, Action, and Target are required.", "Clean Session");
            return false;
        }

        if (action is not ("delete" or "replace"))
        {
            MessageBox.Show("Action must be delete or replace.", "Clean Session");
            return false;
        }

        var preserve = SplitCsv(NormalizeEditableList(entry.PreserveText));
        var stopProcesses = SplitCsv(NormalizeEditableList(entry.StopProcessesText));
        var preserveCsv = string.Join(";", preserve);
        var stopCsv = string.Join(";", stopProcesses);
        var logonFallback = entry.LogonFallback ? "true" : "false";
        var source = (entry.Source ?? "").Trim();

        var originalId = (entry.OriginalId ?? "").Trim();
        if (!string.IsNullOrWhiteSpace(originalId) &&
            !string.Equals(originalId, id, StringComparison.OrdinalIgnoreCase))
        {
            var delArgs = $"-DeleteId \"{EscapePsArg(originalId)}\"";
            var del = App.Session.Scripts.RunPowerShellCapture(@"scripts\runtime\Merge-SessionFolderRules.ps1", delArgs);
            if (!del.Success)
            {
                MessageBox.Show(del.Message, "Clean Session", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }
        }

        var onDup = string.IsNullOrWhiteSpace(originalId) ||
                    string.Equals(originalId, id, StringComparison.OrdinalIgnoreCase)
            ? "Replace"
            : "Skip";

        var args =
            $"-Id \"{EscapePsArg(id)}\" -Title \"{EscapePsArg(title)}\" -Action \"{EscapePsArg(action)}\" " +
            $"-Target \"{EscapePsArg(target)}\" -Source \"{EscapePsArg(source)}\" " +
            $"-Preserve \"{EscapePsArg(preserveCsv)}\" -StopProcesses \"{EscapePsArg(stopCsv)}\" " +
            $"-LogonFallback \"{logonFallback}\" -OnDuplicate {onDup}";

        var r = App.Session.Scripts.RunPowerShellCapture(@"scripts\runtime\Merge-SessionFolderRules.ps1", args);
        if (!r.Success)
        {
            MessageBox.Show(r.Message, "Clean Session", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }

        if (showSuccess)
            ShowMergeResult(r, clearOnSuccess: false);
        else
            entry.OriginalId = id;

        return true;
    }

    private void ReloadRulesQuiet()
    {
        _suppressRulesGridSave = true;
        try
        {
            LoadRulesSummary();
        }
        finally
        {
            _suppressRulesGridSave = false;
        }
    }

    private static string NormalizeEditableList(string? text)
    {
        var t = (text ?? "").Trim();
        return t == "—" ? "" : t;
    }

    private void ApplyRulesFilter()
    {
        var query = (RulesFilterBox.Text ?? "").Trim();
        IEnumerable<SessionFolderRuleEntry> filtered = _allRules;
        if (!string.IsNullOrWhiteSpace(query))
        {
            filtered = filtered.Where(r =>
                r.Id.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Target.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                r.Source.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        var list = filtered.ToList();
        _rulesGridItems.Clear();
        foreach (var item in list)
            _rulesGridItems.Add(item);
        RulesGridFooter.Text = list.Count == _allRules.Count
            ? $"{_allRules.Count} rules"
            : $"Showing {list.Count} of {_allRules.Count} rules";
    }

    private void RulesFilter_Changed(object sender, RoutedEventArgs e) => ApplyRulesFilter();

    private void RefreshRules_Click(object sender, RoutedEventArgs e) => LoadRulesSummary();

    private void AddOrUpdateRule_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var id = (RuleIdBox.Text ?? "").Trim();
        var title = (RuleTitleBox.Text ?? "").Trim();
        var action = (RuleActionBox.SelectedItem as ComboBoxItem)?.Content?.ToString()?.Trim() ?? "replace";
        var target = (RuleTargetBox.Text ?? "").Trim();
        var source = (RuleSourceBox.Text ?? "").Trim();

        if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(title) ||
            string.IsNullOrWhiteSpace(action) || string.IsNullOrWhiteSpace(target))
        {
            MessageBox.Show("Id, Title, Action, and Target are required.", "Clean Session");
            return;
        }

        var preserve = SplitCsv(RulePreserveBox.Text);
        var stopProcesses = SplitCsv(RuleStopProcessesBox.Text);

        var dup = _allRules.FirstOrDefault(r => string.Equals(r.Id, id, StringComparison.OrdinalIgnoreCase));
        if (dup is not null)
        {
            var choice = MessageBox.Show(
                $"Rule '{id}' already exists. Replace it?",
                "Clean Session", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
            if (choice == MessageBoxResult.Cancel)
                return;
            if (choice != MessageBoxResult.Yes)
                return;
        }

        var entry = new SessionFolderRuleEntry
        {
            Id = id,
            Title = title,
            Action = action,
            Target = target,
            Source = source,
            PreserveText = string.Join(", ", preserve),
            StopProcessesText = string.Join(", ", stopProcesses),
            LogonFallback = RuleLogonFallbackBox.IsChecked == true,
            OriginalId = dup?.OriginalId ?? id
        };

        if (!SaveRuleEntry(entry, showSuccess: true))
            return;

        RuleIdBox.Clear();
        RuleTitleBox.Clear();
        RuleTargetBox.Clear();
        RuleSourceBox.Clear();
        RulePreserveBox.Clear();
        RuleStopProcessesBox.Clear();
        RuleLogonFallbackBox.IsChecked = true;
        RuleActionBox.SelectedIndex = 1;
    }

    private void ImportRules_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var dlg = new OpenFileDialog
        {
            Filter = "JSON (*.json)|*.json",
            Title = "Import Session Folder Rules"
        };
        if (dlg.ShowDialog() != true)
            return;

        var policy = MessageBox.Show(
            "Import with Skip duplicates (recommended)?\n\nYes = Skip duplicates\nNo = Replace existing entries",
            "Clean Session", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (policy == MessageBoxResult.Cancel)
            return;

        var onDup = policy == MessageBoxResult.Yes ? "Skip" : "Replace";
        var args = $"-ImportPath \"{dlg.FileName}\" -OnDuplicate {onDup}";
        var r = App.Session.Scripts.RunPowerShellCapture(@"scripts\runtime\Merge-SessionFolderRules.ps1", args);
        ShowMergeResult(r, clearOnSuccess: false);
    }

    private void ExportRules_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var dlg = new SaveFileDialog
        {
            Filter = "JSON (*.json)|*.json",
            FileName = "session-folder-rules.json",
            Title = "Export Session Folder Rules"
        };
        if (dlg.ShowDialog() != true)
            return;

        var args = $"-ExportPath \"{dlg.FileName}\"";
        var r = App.Session.Scripts.RunPowerShellCapture(@"scripts\runtime\Merge-SessionFolderRules.ps1", args);
        ShowMergeResult(r, clearOnSuccess: false);
    }

    private void DeleteSelectedRules_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        if (RulesGrid.ItemsSource is not IEnumerable<SessionFolderRuleEntry> visible)
            return;

        var selected = visible.Where(r => r.IsSelected).ToList();
        if (selected.Count == 0)
        {
            MessageBox.Show("Select one or more rules using the checkboxes.", "Clean Session");
            return;
        }

        if (MessageBox.Show(
                $"Remove {selected.Count} rule(s)?",
                "Clean Session", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;

        foreach (var entry in selected)
        {
            var args = $"-DeleteId \"{EscapePsArg(entry.Id)}\"";
            var r = App.Session.Scripts.RunPowerShellCapture(@"scripts\runtime\Merge-SessionFolderRules.ps1", args);
            if (!r.Success)
            {
                MessageBox.Show(r.Message, "Clean Session", MessageBoxButton.OK, MessageBoxImage.Warning);
                break;
            }
        }

        LoadRulesSummary();
    }

    private void OpenRulesJson_Click(object sender, RoutedEventArgs e)
    {
        EnsureRulesConfigFile();
        try
        {
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{RulesConfigPath}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "NextGPU");
        }
    }

    private void ShowMergeResult((bool Success, string Message) r, bool clearOnSuccess)
    {
        if (!r.Success)
        {
            MessageBox.Show(r.Message, "Clean Session", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(r.Message);
            var root = doc.RootElement;
            var msg = root.TryGetProperty("Message", out var m) ? m.GetString() : r.Message;
            MessageBox.Show(msg ?? "Saved.", "Clean Session", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch
        {
            MessageBox.Show(r.Message, "Clean Session", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        if (clearOnSuccess)
        {
            RuleIdBox.Clear();
            RuleTitleBox.Clear();
            RuleTargetBox.Clear();
            RuleSourceBox.Clear();
            RulePreserveBox.Clear();
            RuleStopProcessesBox.Clear();
            RuleLogonFallbackBox.IsChecked = true;
            RuleActionBox.SelectedIndex = 1;
        }

        LoadRulesSummary();
    }

    private static string[] SplitCsv(string? text) =>
        (text ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(s => !string.IsNullOrWhiteSpace(s))
            .ToArray();

    private static string EscapePsArg(string value) => value.Replace("\"", "`\"");
}
