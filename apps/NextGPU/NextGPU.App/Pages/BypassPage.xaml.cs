using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using System.Windows.Media;
using Microsoft.Win32;
using NextGPU.App;
using NextGPU.Core;

namespace NextGPU.App.Pages;

public partial class BypassPage : Page
{
    private readonly List<BypassSyncListEntry> _allSyncListEntries = [];
    private readonly ObservableCollection<BypassSyncListEntry> _syncListGridItems = [];
    private readonly ObservableCollection<BypassSeedShortcutRow> _seedPreviewItems = [];
    private readonly List<PreLaunchRowUi> _preLaunchRows = [];
    private bool _suppressSyncListGridSave;
    private bool _suppressSeedSelectionSave;

    private sealed class PreLaunchRowUi
    {
        public required Border Container { get; init; }
        public required TextBox PathBox { get; init; }
        public required TextBox DelayBox { get; init; }
    }

    public static BypassSyncDraft PendingDraft { get; } = new();

    public BypassPage()
    {
        InitializeComponent();
        Loaded += (_, _) => OnLoaded();
    }

    private void OnLoaded()
    {
        SyncListGrid.ItemsSource = _syncListGridItems;
        SeedPreviewGrid.ItemsSource = _seedPreviewItems;
        BuildButtons();
        BuildSyncListActionButtons();
        BuildSeedPreviewActionButtons();
        LoadSyncListSummary();
        ApplyPendingDraft();
    }

    private void BuildButtons()
    {
        SetupPanel.Children.Clear();
        SyncPanel.Children.Clear();
        ToolsPanel.Children.Clear();
        UninstallPanel.Children.Clear();
        AdminSetupPanel.Children.Clear();

        BuildAdminSetupButtons();
        BuildSetupButtons();
        BuildSyncButtons();
        BuildToolsButtons();
        BuildUninstallButtons();
    }

    private void BuildAdminSetupButtons()
    {
        var btn = new Button
        {
            Content = "Setup NextGPU-Admin",
            Style = (Style)Application.Current.FindResource("SecondaryButton"),
            Padding = new Thickness(14, 10, 14, 10)
        };
        btn.Click += (_, _) => ShowAdminSetupDialog();
        AdminSetupPanel.Children.Add(btn);
    }

    private void ShowAdminSetupDialog()
    {
        var dlg = new Window
        {
            Title = "Setup NextGPU-Admin",
            Width = 420,
            Height = 620,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Owner = Window.GetWindow(this),
            ResizeMode = ResizeMode.NoResize
        };

        var panel = new StackPanel { Margin = new Thickness(20) };

        // Status panel - shows both user account and credential status
        var userStatusPanel = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };
        var userStatusLabel = new TextBlock { Text = "User Account:", Margin = new Thickness(0, 0, 8, 0), FontWeight = FontWeights.Bold };
        var userStatusValue = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        var userStatusRow = new StackPanel { Orientation = Orientation.Horizontal };
        userStatusRow.Children.Add(userStatusLabel);
        userStatusRow.Children.Add(userStatusValue);
        userStatusPanel.Children.Add(userStatusRow);

        var credStatusPanel = new StackPanel { Margin = new Thickness(0, 0, 0, 16) };
        var credStatusLabel = new TextBlock { Text = "Credential:", Margin = new Thickness(0, 0, 8, 0), FontWeight = FontWeights.Bold };
        var credStatusValue = new TextBlock { VerticalAlignment = VerticalAlignment.Center };
        var credStatusRow = new StackPanel { Orientation = Orientation.Horizontal };
        credStatusRow.Children.Add(credStatusLabel);
        credStatusRow.Children.Add(credStatusValue);
        credStatusPanel.Children.Add(credStatusRow);

        // Check current state
        bool userExists = false;
        bool userIsAdmin = false;
        bool credExists = false;
        string userStatusText = "Unknown";
        string credStatusText = "Unknown";

        if (App.Session.Scripts is not null)
        {
            // Check user account and credential status in one call
            var statusR = App.Session.Scripts.RunPowerShellCapture(
                @"scripts\provisioning\Store-NextGpuAdminCredential.ps1",
                @"-StatusOnly");
            
            if (statusR.Success && TryParseAdminSetupStatus(statusR.Message, out userExists, out userIsAdmin, out credExists))
            {
                // Parsed from Store-NextGpuAdminCredential.ps1 -StatusOnly JSON.
            }
            else if (statusR.Success)
            {
                credExists = statusR.Message.Contains("\"CredExists\":true", StringComparison.Ordinal);
            }
        }

        // Set status texts and colors
        if (!userExists)
        {
            userStatusText = "Not Found (will be created)";
            userStatusValue.Foreground = Brushes.Orange;
        }
        else if (!userIsAdmin)
        {
            userStatusText = "Not Admin (will be added)";
            userStatusValue.Foreground = Brushes.Orange;
        }
        else
        {
            userStatusText = "Ready";
            userStatusValue.Foreground = Brushes.Green;
        }
        userStatusValue.Text = userStatusText;

        credStatusText = credExists ? "Stored" : "Not Stored";
        credStatusValue.Text = credStatusText;
        credStatusValue.Foreground = credExists ? Brushes.Green : Brushes.Orange;

        var desc = new TextBlock
        {
            Text = "Enter a password for the NextGPU-Admin account.\nThis will create the Windows user if needed and add to Administrators.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 16)
        };

        var passLabel = new TextBlock { Text = "Password:", Margin = new Thickness(0, 0, 0, 4) };
        var passBox = new PasswordBox { Margin = new Thickness(0, 0, 0, 16) };

        var confirmLabel = new TextBlock { Text = "Confirm Password:", Margin = new Thickness(0, 0, 0, 4) };
        var confirmBox = new PasswordBox { Margin = new Thickness(0, 0, 0, 16) };

        var errorText = new TextBlock
        {
            Foreground = Brushes.Red,
            Visibility = Visibility.Collapsed,
            Margin = new Thickness(0, 0, 0, 8)
        };

        var buttonPanel = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };

        var okBtn = new Button { Content = "Create & Store", Style = (Style)Application.Current.FindResource("PrimaryButton"), Padding = new Thickness(16, 8, 16, 8), Margin = new Thickness(0, 0, 8, 0) };
        var cancelBtn = new Button { Content = "Cancel", Style = (Style)Application.Current.FindResource("SecondaryButton"), Padding = new Thickness(16, 8, 16, 8) };

        okBtn.Click += (_, _) =>
        {
            errorText.Visibility = Visibility.Collapsed;
            var password = passBox.Password;
            var confirm = confirmBox.Password;

            if (string.IsNullOrWhiteSpace(password))
            {
                errorText.Text = "Password cannot be empty.";
                errorText.Visibility = Visibility.Visible;
                return;
            }

            if (password.Length < 12)
            {
                errorText.Text = "Password must be at least 12 characters.";
                errorText.Visibility = Visibility.Visible;
                return;
            }

            if (password != confirm)
            {
                errorText.Text = "Passwords do not match.";
                errorText.Visibility = Visibility.Visible;
                return;
            }

            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }

            try
            {
                var encrypted = EncryptWithDpapi(password);

                // Call with -CreateUser to ensure the user account exists
                var r = App.Session.Scripts.RunPowerShellCapture(
                    @"scripts\provisioning\Store-NextGpuAdminCredential.ps1",
                    $"-EncryptedPassword \"{encrypted}\" -CreateUser");

                // Verify the credential was actually stored
                var verifyR = App.Session.Scripts.RunPowerShellCapture(
                    @"scripts\provisioning\Store-NextGpuAdminCredential.ps1",
                    @"-StatusOnly");
                var userReady = false;
                var adminReady = false;
                var credStored = false;
                bool verified = verifyR.Success
                    && TryParseAdminSetupStatus(verifyR.Message, out userReady, out adminReady, out credStored)
                    && credStored;

                if (r.Success && verified)
                {
                    if (userReady && adminReady)
                    {
                        userStatusValue.Text = "Ready";
                        userStatusValue.Foreground = Brushes.Green;
                    }
                    else if (userReady)
                    {
                        userStatusValue.Text = "Not Admin (will be added)";
                        userStatusValue.Foreground = Brushes.Orange;
                    }
                    else
                    {
                        userStatusValue.Text = "Not Found (will be created)";
                        userStatusValue.Foreground = Brushes.Orange;
                    }
                    credStatusValue.Text = "Stored";
                    credStatusValue.Foreground = Brushes.Green;
                    MessageBox.Show("NextGPU-Admin user account created/configured and password stored successfully.\n\nCredential file: %ProgramData%\\nextGPU\\admincred.dat", "NextGPU", MessageBoxButton.OK, MessageBoxImage.Information);
                    dlg.DialogResult = true;
                }
                else if (r.Success && !verified)
                {
                    errorText.Text = "User may be created but credential file not found. Check PowerShell permissions.";
                    errorText.Visibility = Visibility.Visible;
                }
                else
                {
                    MessageBox.Show($"Failed to setup NextGPU-Admin:\n{r.Message}", "NextGPU", MessageBoxButton.OK, MessageBoxImage.Error);
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show($"Failed to setup NextGPU-Admin: {ex.Message}", "NextGPU", MessageBoxButton.OK, MessageBoxImage.Error);
            }
        };

        cancelBtn.Click += (_, _) => dlg.DialogResult = false;

        buttonPanel.Children.Add(okBtn);
        buttonPanel.Children.Add(cancelBtn);

        panel.Children.Add(userStatusPanel);
        panel.Children.Add(credStatusPanel);
        panel.Children.Add(desc);
        panel.Children.Add(passLabel);
        panel.Children.Add(passBox);
        panel.Children.Add(confirmLabel);
        panel.Children.Add(confirmBox);
        panel.Children.Add(errorText);
        panel.Children.Add(buttonPanel);

        dlg.Content = panel;
        dlg.ShowDialog();
    }

    private static bool TryParseAdminSetupStatus(string? message, out bool userExists, out bool userIsAdmin, out bool credExists)
    {
        userExists = userIsAdmin = credExists = false;
        if (string.IsNullOrWhiteSpace(message) || !message.Contains("UserExists", StringComparison.Ordinal))
            return false;

        userExists = message.Contains("\"UserExists\":true", StringComparison.Ordinal)
            || message.Contains("\"Name\":\"NextGPU-Admin\"", StringComparison.Ordinal);
        userIsAdmin = message.Contains("\"IsAdmin\":true", StringComparison.Ordinal);
        credExists = message.Contains("\"CredExists\":true", StringComparison.Ordinal);
        return true;
    }

    private static string EncryptWithDpapi(string plainText)
    {
        var bytes = Encoding.UTF8.GetBytes(plainText);
        var protectedBytes = ProtectedData.Protect(bytes, null, DataProtectionScope.CurrentUser);
        return Convert.ToBase64String(protectedBytes);
    }

    private void BuildSetupButtons()
    {
        ActionPageTools.AddPowerShellButton(SetupPanel, "1. Setup Bypass (Automated)",
            @"PlayNiteWatcher\Setup-PlayniteBypassAutomated.ps1", keepConsoleOpen: true,
            helpText: "Pick parent folder, copy checked seed .lnk shortcuts, import filtered RunAsTool list. Requires sync-list entries and at least one selected Ready shortcut.");
        ActionPageTools.AddPowerShellButton(SetupPanel, "2. Launch RunAsTool",
            @"PlayNiteWatcher\Sync-PlayniteBypassShortcuts.ps1", "-RunAsToolOnly", keepConsoleOpen: true,
            helpText: "Optional — open RunAsTool to verify which games/apps were imported.");
    }

    private void BuildSyncButtons()
    {
        ActionPageTools.AddPowerShellButton(SyncPanel, "3. Review and Sync",
            @"PlayNiteWatcher\Sync-PlayniteBypassShortcuts.ps1", "-Interactive", keepConsoleOpen: true,
            helpText: "Processes sync-list entries only; updates Playnite launch paths by gameId or nameId. Does not export to Sunshine.");
        ActionPageTools.AddPowerShellButton(SyncPanel, "Re-sync Shortcuts",
            @"PlayNiteWatcher\Sync-PlayniteBypassShortcuts.ps1", "-SyncOnly", keepConsoleOpen: true,
            helpText: "Re-apply sync-list launch paths without review UI. Extra .lnk files in Game Shortcuts are ignored.");
    }

    private void BuildToolsButtons()
    {
        ActionPageTools.AddPowerShellButton(ToolsPanel, "Install Steam Extensions",
            @"PlayNiteWatcher\Install-SteamExtensions.ps1", keepConsoleOpen: true,
            helpText: "Install or repair SteamLibrary_NextGPU + NextGPUBypassGuard from repo build output.");
        ActionPageTools.AddPowerShellButton(ToolsPanel, "Launch RunAsTool (Maintenance)",
            @"PlayNiteWatcher\Launch-RunAsTool.ps1", keepConsoleOpen: true,
            helpText: "Download/install RunAsTool if missing and open it for troubleshooting.");
        ActionPageTools.AddOpenExplorerButton(ToolsPanel, "Open Game Shortcuts Folder", GetGameShortcutsFolder,
            helpText: "Opens the configured Game Shortcuts folder in Explorer (from bypass-shortcuts.json).");
        AddOpenPlayniteLogButton(ToolsPanel, "Open Bypass Sync Log", RepoCatalog.PlayniteBypassSyncLog,
            "Opens Sync-PlayniteBypassShortcuts.log — sync-list processing and Playnite binding steps.");
        AddOpenSyncListNotepadButton();
    }

    private void BuildUninstallButtons()
    {
        AddConfirmedPowerShellButton(UninstallPanel, "Uninstall Game Shortcuts + RunAsTool",
            @"PlayNiteWatcher\Uninstall-PlayniteBypass.ps1", "-Force",
            "Remove RunAsTool, delete Game Shortcuts folders, clear bypass config, and revert bypass play paths in Playnite. The Playnite install folder is kept. Continue?",
            "Removes bypass/RunAsTool only — does not delete the portable Playnite folder.");
        AddConfirmedPowerShellButton(UninstallPanel, "Uninstall Portable Playnite",
            @"PlayNiteWatcher\Uninstall-PlayniteBypass.ps1", "-Force -RemovePlayniteInstall",
            "Remove RunAsTool, bypass config, AND delete the entire portable Playnite install folder (games.db, extensions, config). Continue?",
            "Full Playnite removal. Use only when you want to delete the portable install entirely. Re-run setup afterward to reinstall.");
    }

    private void BuildSyncListActionButtons()
    {
        SyncListFormActionsPanel.Children.Clear();
        SyncListGridActionsPanel.Children.Clear();

        AddPlainInlineActionButton(SyncListFormActionsPanel, "Add / Update Entry", AddSyncListEntry_Click, "PrimaryButton");
        AddPlainInlineActionButton(SyncListFormActionsPanel, "Import Sync List", ImportSyncList_Click, "SecondaryButton");
        AddPlainInlineActionButton(SyncListFormActionsPanel, "Export Sync List", ExportSyncList_Click, "SecondaryButton");
        AddPlainInlineActionButton(SyncListFormActionsPanel, "Open in Notepad", OpenSyncListNotepad_Click, "GhostButton");

        SyncListGridActionsPanel.Children.Add(SyncListFilterBox);
        AddPlainInlineActionButton(SyncListGridActionsPanel, "Refresh", RefreshSyncListGrid_Click, "GhostButton");
        AddPlainInlineActionButton(SyncListGridActionsPanel, "Delete Selected", DeleteSelectedSyncList_Click, "SecondaryButton");
    }

    private void BuildSeedPreviewActionButtons()
    {
        SeedPreviewActionsPanel.Children.Clear();
        AddPlainInlineActionButton(SeedPreviewActionsPanel, "Select All Ready", SelectAllReadySeed_Click, "GhostButton");
        AddPlainInlineActionButton(SeedPreviewActionsPanel, "Select None", SelectNoneSeed_Click, "GhostButton");
        AddPlainInlineActionButton(SeedPreviewActionsPanel, "Export Selection", ExportSeedSelection_Click, "SecondaryButton");
        AddPlainInlineActionButton(SeedPreviewActionsPanel, "Import Selection", ImportSeedSelection_Click, "SecondaryButton");
    }

    private static void AddPlainInlineActionButton(Panel panel, string label, RoutedEventHandler onClick, string styleKey)
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

    private void ApplyPendingDraft()
    {
        if (!PendingDraft.HasPending)
            return;

        SyncListTitleBox.Text = PendingDraft.Title;
        SyncListGameIdBox.Text = PendingDraft.GameId;
        SyncListNameIdBox.Text = PendingDraft.NameId;
        if (string.IsNullOrWhiteSpace(SyncListShortcutNameBox.Text))
            SyncListShortcutNameBox.Text = PendingDraft.SuggestedShortcutName;

        PendingDraft.Clear();
    }

    private void AddPreLaunch_Click(object sender, RoutedEventArgs e)
    {
        AddPreLaunchRow("", 2);
    }

    private void AddPreLaunchRow(string path, int delaySec)
    {
        var index = _preLaunchRows.Count + 1;
        var grid = new Grid { Margin = new Thickness(0, 0, 0, 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(72) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var label = new TextBlock
        {
            Text = $"Pre-launch {index}",
            Foreground = (Brush)Application.Current.FindResource("SecondaryTextBrush"),
            Margin = new Thickness(0, 0, 0, 4)
        };
        Grid.SetColumnSpan(label, 3);

        var pathBox = new TextBox { Text = path, Margin = new Thickness(0, 0, 8, 0) };
        Grid.SetRow(pathBox, 1);
        Grid.SetColumn(pathBox, 0);

        var delayBox = new TextBox { Text = delaySec.ToString(), Margin = new Thickness(0, 0, 8, 0), ToolTip = "Delay seconds after this launch" };
        Grid.SetRow(delayBox, 1);
        Grid.SetColumn(delayBox, 1);

        var removeBtn = new Button
        {
            Content = "Remove",
            Style = (Style)Application.Current.FindResource("GhostButton"),
            Padding = new Thickness(8, 4, 8, 4),
            VerticalAlignment = VerticalAlignment.Center
        };
        Grid.SetRow(removeBtn, 1);
        Grid.SetColumn(removeBtn, 2);

        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(label);
        grid.Children.Add(pathBox);
        grid.Children.Add(delayBox);
        grid.Children.Add(removeBtn);

        var rowUi = new PreLaunchRowUi
        {
            Container = new Border { Child = grid },
            PathBox = pathBox,
            DelayBox = delayBox
        };
        removeBtn.Click += (_, _) =>
        {
            SyncListPreLaunchesPanel.Children.Remove(rowUi.Container);
            _preLaunchRows.Remove(rowUi);
            RenumberPreLaunchLabels();
        };

        _preLaunchRows.Add(rowUi);
        SyncListPreLaunchesPanel.Children.Add(rowUi.Container);
    }

    private void RenumberPreLaunchLabels()
    {
        for (var i = 0; i < _preLaunchRows.Count; i++)
        {
            if (_preLaunchRows[i].Container.Child is Grid grid && grid.Children[0] is TextBlock label)
                label.Text = $"Pre-launch {i + 1}";
        }
    }

    private void ClearPreLaunchRows()
    {
        _preLaunchRows.Clear();
        SyncListPreLaunchesPanel.Children.Clear();
    }

    private List<BypassSyncLaunchItem> GetPreLaunchesFromForm()
    {
        var items = new List<BypassSyncLaunchItem>();
        foreach (var row in _preLaunchRows)
        {
            var path = (row.PathBox.Text ?? "").Trim();
            if (string.IsNullOrWhiteSpace(path))
                continue;
            var delay = 2;
            if (int.TryParse((row.DelayBox.Text ?? "").Trim(), out var parsed) && parsed >= 0)
                delay = parsed;
            items.Add(new BypassSyncLaunchItem { Path = path, DelaySec = delay });
        }
        return items;
    }

    private static string FormatPreLaunchesText(IReadOnlyList<BypassSyncLaunchItem> launches)
    {
        if (launches.Count == 0)
            return "";
        return string.Join(", ", launches.Select(l =>
            l.DelaySec == 2 ? l.Path : $"{l.Path} (+{l.DelaySec}s)"));
    }

    private static string FormatPreLaunchesCli(IReadOnlyList<BypassSyncLaunchItem> launches)
    {
        if (launches.Count == 0)
            return "";

        return string.Join(";", launches.Select(l =>
        {
            var path = TrimLaunchPath(l.Path ?? "").Replace("\"", "\\\"");
            return l.DelaySec == 2 ? path : $"{path}|{l.DelaySec}";
        }));
    }

    private static string BuildPreLaunchesArg(IReadOnlyList<BypassSyncLaunchItem> launches)
    {
        var cli = FormatPreLaunchesCli(launches);
        return string.IsNullOrWhiteSpace(cli) ? "" : $" -PreLaunches \"{cli}\"";
    }

    private static string BuildSyncListMergeArgs(
        string title,
        string shortcutName,
        string gameId,
        string nameId,
        IReadOnlyList<BypassSyncLaunchItem> launches,
        string onDuplicate)
    {
        var args = $"-Title \"{EscapePsArg(title)}\" -ShortcutName \"{EscapePsArg(shortcutName)}\" -OnDuplicate {onDuplicate}";
        args += BuildPreLaunchesArg(launches);
        if (!string.IsNullOrWhiteSpace(gameId))
            args += $" -GameId \"{EscapePsArg(gameId)}\"";
        else
            args += $" -NameId \"{EscapePsArg(nameId)}\"";
        return args;
    }

    private static List<BypassSyncLaunchItem> ParsePreLaunchesText(string? text)
    {
        var items = new List<BypassSyncLaunchItem>();
        var raw = (text ?? "").Trim();
        if (string.IsNullOrWhiteSpace(raw) || raw == "—")
            return items;

        foreach (var part in raw.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var segment = part.Trim();
            if (string.IsNullOrWhiteSpace(segment))
                continue;

            var delay = 2;
            var path = segment;
            var open = segment.LastIndexOf(" (+", StringComparison.Ordinal);
            if (open >= 0 && segment.EndsWith(')'))
            {
                var close = segment.LastIndexOf(')');
                var delayText = segment[(open + 3)..close].Trim().TrimEnd('s');
                if (int.TryParse(delayText, out var parsed) && parsed >= 0)
                    delay = parsed;
                path = segment[..open].Trim();
            }

            if (!string.IsNullOrWhiteSpace(path))
                items.Add(new BypassSyncLaunchItem { Path = TrimLaunchPath(path), DelaySec = delay });
        }

        return items;
    }

    private static string TrimLaunchPath(string path)
    {
        var p = (path ?? "").Trim();
        while (p.Length >= 2)
        {
            if ((p.StartsWith('\'') && p.EndsWith('\'')) || (p.StartsWith('"') && p.EndsWith('"')))
            {
                p = p[1..^1].Trim();
                continue;
            }
            break;
        }
        return p;
    }

    private string GetSyncListPath()
    {
        var repo = App.Session.RepoRoot;
        if (string.IsNullOrWhiteSpace(repo))
            return "";
        return Path.Combine(repo, RepoCatalog.PlayniteBypassSyncListRelativePath.Replace('/', Path.DirectorySeparatorChar));
    }

    private void LoadSyncListSummary()
    {
        ReloadSyncListEntries();
        SyncListCountText.Text = _allSyncListEntries.Count == 0
            ? "No sync-list entries yet. Add entries before Setup Bypass."
            : $"{_allSyncListEntries.Count} sync-list entries";
        ApplySyncListFilter();
        LoadSeedPreview();
    }

    private string GetSeedCopySelectionPath()
    {
        var repo = App.Session.RepoRoot;
        if (string.IsNullOrWhiteSpace(repo))
            return "";
        return Path.Combine(repo, RepoCatalog.PlayniteBypassSeedCopySelectionRelativePath.Replace('/', Path.DirectorySeparatorChar));
    }

    private void RefreshSeedPreview_Click(object sender, RoutedEventArgs e) => LoadSyncListSummary();

    private string GetShortcutsSeedFolder()
    {
        var repo = App.Session.RepoRoot;
        if (string.IsNullOrWhiteSpace(repo))
            return "";
        return Path.Combine(repo, RepoCatalog.PlayNiteWatcherRelativeDir, "templates", "bypass", "Game Shortcuts");
    }

    private void LoadSeedPreview()
    {
        _suppressSeedSelectionSave = true;
        try
        {
            _seedPreviewItems.Clear();
            var seedFolder = GetShortcutsSeedFolder();
            var syncRefs = BuildSyncListShortcutRefs();
            var savedSelection = LoadSavedSeedSelection();
            var hasSavedSelection = savedSelection is not null;

            var leafOrder = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

            if (!string.IsNullOrWhiteSpace(seedFolder) && Directory.Exists(seedFolder))
            {
                foreach (var path in Directory.EnumerateFiles(seedFolder, "*.lnk")
                             .OrderBy(p => Path.GetFileName(p), StringComparer.OrdinalIgnoreCase))
                {
                    var leaf = Path.GetFileName(path);
                    if (string.IsNullOrWhiteSpace(leaf) || !seen.Add(leaf))
                        continue;
                    leafOrder.Add(leaf);
                }
            }

            foreach (var leaf in syncRefs.Keys.OrderBy(k => k, StringComparer.OrdinalIgnoreCase))
            {
                if (seen.Add(leaf))
                    leafOrder.Add(leaf);
            }

            foreach (var leaf in leafOrder)
            {
                syncRefs.TryGetValue(leaf, out var syncRef);
                var status = ResolveSeedStatus(seedFolder, leaf);
                var defaultSelected = syncRef is not null && status == "Ready";
                var selected = hasSavedSelection
                    ? savedSelection!.Contains(leaf)
                    : defaultSelected;

                _seedPreviewItems.Add(new BypassSeedShortcutRow
                {
                    Shortcut = leaf,
                    Role = syncRef?.Role ?? "Available",
                    ForTitle = syncRef?.ForTitle ?? "—",
                    SeedStatus = status,
                    IsSelected = selected
                });
            }

            UpdateSeedPreviewSummary();
        }
        finally
        {
            _suppressSeedSelectionSave = false;
        }

        // Persist defaults the first time so Setup Bypass sees the same selection as the UI.
        if (!File.Exists(GetSeedCopySelectionPath()) && _seedPreviewItems.Any(r => r.IsSelected))
            SaveSeedSelection();
    }

    private sealed class SyncShortcutRef
    {
        public required string Role { get; init; }
        public required string ForTitle { get; init; }
    }

    private Dictionary<string, SyncShortcutRef> BuildSyncListShortcutRefs()
    {
        var map = new Dictionary<string, SyncShortcutRef>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in _allSyncListEntries)
        {
            var title = (entry.Title ?? "").Trim();
            var shortcutName = (entry.ShortcutName ?? "").Trim();
            if (!string.IsNullOrWhiteSpace(shortcutName))
            {
                var leaf = $"{shortcutName}.lnk";
                if (!map.ContainsKey(leaf))
                {
                    map[leaf] = new SyncShortcutRef
                    {
                        Role = "Primary",
                        ForTitle = string.IsNullOrWhiteSpace(title) ? "—" : title
                    };
                }
            }

            foreach (var launch in entry.Launches)
            {
                var path = (launch.Path ?? "").Trim();
                if (string.IsNullOrWhiteSpace(path) ||
                    !path.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
                    continue;

                var leaf = Path.GetFileName(path);
                if (string.IsNullOrWhiteSpace(leaf) || map.ContainsKey(leaf))
                    continue;

                map[leaf] = new SyncShortcutRef
                {
                    Role = "Pre-launch",
                    ForTitle = string.IsNullOrWhiteSpace(title) ? "—" : title
                };
            }
        }

        return map;
    }

    private HashSet<string>? LoadSavedSeedSelection()
    {
        var path = GetSeedCopySelectionPath();
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
            return null;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("shortcuts", out var shortcuts) ||
                shortcuts.ValueKind != JsonValueKind.Array)
                return null;

            var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in shortcuts.EnumerateArray())
            {
                var leaf = (item.GetString() ?? "").Trim();
                if (string.IsNullOrWhiteSpace(leaf))
                    continue;
                if (!leaf.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
                    leaf += ".lnk";
                set.Add(Path.GetFileName(leaf));
            }

            return set;
        }
        catch
        {
            return null;
        }
    }

    private void SaveSeedSelection()
    {
        var path = GetSeedCopySelectionPath();
        if (string.IsNullOrWhiteSpace(path))
            return;

        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(dir) && !Directory.Exists(dir))
            Directory.CreateDirectory(dir);

        var shortcuts = _seedPreviewItems
            .Where(r => r.IsSelected)
            .Select(r => r.Shortcut)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderBy(s => s, StringComparer.OrdinalIgnoreCase)
            .ToArray();

        var payload = new Dictionary<string, object>
        {
            ["_comment"] = "Selected seed .lnk files copied during Setup Bypass. Edit via Bypass Setup tab.",
            ["shortcuts"] = shortcuts
        };
        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }

    private void UpdateSeedPreviewSummary()
    {
        var selected = _seedPreviewItems.Count(r => r.IsSelected);
        var readySelected = _seedPreviewItems.Count(r => r.IsSelected && r.SeedStatus == "Ready");
        var missingSelected = _seedPreviewItems.Count(r => r.IsSelected && r.SeedStatus == "Missing");
        var available = _seedPreviewItems.Count(r => r.SeedStatus == "Ready");

        if (_seedPreviewItems.Count == 0)
        {
            SeedPreviewSummaryText.Text =
                "No seed shortcuts found. Add .lnk files under PlayNiteWatcher\\templates\\bypass\\Game Shortcuts.";
            return;
        }

        SeedPreviewSummaryText.Text =
            $"{selected} selected for copy ({readySelected} ready, {missingSelected} missing) · {_seedPreviewItems.Count} listed · {available} available in seed";
    }

    private void SeedSelection_Changed(object sender, RoutedEventArgs e)
    {
        if (_suppressSeedSelectionSave)
            return;
        UpdateSeedPreviewSummary();
        SaveSeedSelection();
    }

    private void SelectAllReadySeed_Click(object sender, RoutedEventArgs e)
    {
        _suppressSeedSelectionSave = true;
        try
        {
            foreach (var row in _seedPreviewItems)
                row.IsSelected = row.SeedStatus == "Ready";
        }
        finally
        {
            _suppressSeedSelectionSave = false;
        }

        UpdateSeedPreviewSummary();
        SaveSeedSelection();
    }

    private void SelectNoneSeed_Click(object sender, RoutedEventArgs e)
    {
        _suppressSeedSelectionSave = true;
        try
        {
            foreach (var row in _seedPreviewItems)
                row.IsSelected = false;
        }
        finally
        {
            _suppressSeedSelectionSave = false;
        }

        UpdateSeedPreviewSummary();
        SaveSeedSelection();
    }

    private void ExportSeedSelection_Click(object sender, RoutedEventArgs e)
    {
        SaveSeedSelection();
        var selected = _seedPreviewItems.Where(r => r.IsSelected).Select(r => r.Shortcut).ToList();
        if (selected.Count == 0)
        {
            MessageBox.Show("Select at least one shortcut before exporting.", "Seed Selection");
            return;
        }

        var dlg = new SaveFileDialog
        {
            Filter = "JSON (*.json)|*.json",
            Title = "Export Seed Copy Selection",
            FileName = "bypass-seed-copy-selection.json"
        };
        if (dlg.ShowDialog() != true)
            return;

        try
        {
            var payload = new Dictionary<string, object>
            {
                ["_comment"] = "Selected seed .lnk files copied during Setup Bypass.",
                ["shortcuts"] = selected.ToArray()
            };
            var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(dlg.FileName, json);
            MessageBox.Show(
                $"Exported {selected.Count} shortcut(s) to:\n{dlg.FileName}",
                "Seed Selection", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Seed Selection", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void ImportSeedSelection_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new OpenFileDialog
        {
            Filter = "JSON (*.json)|*.json",
            Title = "Import Seed Copy Selection"
        };
        if (dlg.ShowDialog() != true)
            return;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(dlg.FileName));
            if (!doc.RootElement.TryGetProperty("shortcuts", out var shortcuts) ||
                shortcuts.ValueKind != JsonValueKind.Array)
            {
                MessageBox.Show("Invalid selection file. Expected a JSON object with a \"shortcuts\" array.", "Seed Selection");
                return;
            }

            var imported = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var item in shortcuts.EnumerateArray())
            {
                var leaf = (item.GetString() ?? "").Trim();
                if (string.IsNullOrWhiteSpace(leaf))
                    continue;
                if (!leaf.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
                    leaf += ".lnk";
                imported.Add(Path.GetFileName(leaf));
            }

            if (imported.Count == 0)
            {
                MessageBox.Show("Import file contained no shortcuts.", "Seed Selection");
                return;
            }

            _suppressSeedSelectionSave = true;
            try
            {
                foreach (var row in _seedPreviewItems)
                    row.IsSelected = imported.Contains(row.Shortcut);

                foreach (var leaf in imported)
                {
                    if (_seedPreviewItems.Any(r => string.Equals(r.Shortcut, leaf, StringComparison.OrdinalIgnoreCase)))
                        continue;

                    _seedPreviewItems.Add(new BypassSeedShortcutRow
                    {
                        Shortcut = leaf,
                        Role = "Available",
                        ForTitle = "—",
                        SeedStatus = ResolveSeedStatus(GetShortcutsSeedFolder(), leaf),
                        IsSelected = true
                    });
                }
            }
            finally
            {
                _suppressSeedSelectionSave = false;
            }

            UpdateSeedPreviewSummary();
            SaveSeedSelection();

            var matched = _seedPreviewItems.Count(r => r.IsSelected);
            MessageBox.Show(
                $"Imported selection ({imported.Count} name(s) in file, {matched} checked in the list).",
                "Seed Selection", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Seed Selection", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private static string ResolveSeedStatus(string seedFolder, string leaf)
    {
        if (string.IsNullOrWhiteSpace(seedFolder) || !Directory.Exists(seedFolder))
            return "Missing";
        return File.Exists(Path.Combine(seedFolder, leaf)) ? "Ready" : "Missing";
    }

    private void ReloadSyncListEntries()
    {
        _allSyncListEntries.Clear();
        var path = GetSyncListPath();
        if (string.IsNullOrWhiteSpace(path))
            return;

        if (!File.Exists(path))
        {
            var template = path + ".template";
            if (!File.Exists(template))
                template = Path.Combine(Path.GetDirectoryName(path)!, "bypass-sync-list.json.template");
            if (File.Exists(template))
            {
                var dir = Path.GetDirectoryName(path);
                if (!string.IsNullOrWhiteSpace(dir) && !Directory.Exists(dir))
                    Directory.CreateDirectory(dir);
                File.Copy(template, path);
            }
            else
            {
                return;
            }
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("apps", out var apps) || apps.ValueKind != JsonValueKind.Array)
                return;

            foreach (var app in apps.EnumerateArray())
            {
                var launches = new List<BypassSyncLaunchItem>();
                if (app.TryGetProperty("launches", out var launchesEl) && launchesEl.ValueKind == JsonValueKind.Array)
                {
                    foreach (var launch in launchesEl.EnumerateArray())
                    {
                        var launchPath = launch.TryGetProperty("path", out var p) ? p.GetString() ?? "" : "";
                        if (string.IsNullOrWhiteSpace(launchPath))
                            continue;
                        var delay = 2;
                        if (launch.TryGetProperty("delaySec", out var d) && d.TryGetInt32(out var parsed))
                            delay = parsed;
                        launches.Add(new BypassSyncLaunchItem { Path = launchPath, DelaySec = delay });
                    }
                }
                else if (app.TryGetProperty("helperPath", out var legacyHelper))
                {
                    var helper = legacyHelper.GetString() ?? "";
                    if (!string.IsNullOrWhiteSpace(helper))
                        launches.Add(new BypassSyncLaunchItem { Path = helper, DelaySec = 2 });
                }

                var shortcutName = app.TryGetProperty("shortcutName", out var s) ? s.GetString() ?? "" : "";
                _allSyncListEntries.Add(new BypassSyncListEntry
                {
                    OriginalShortcutName = shortcutName,
                    Title = app.TryGetProperty("title", out var t) ? t.GetString() ?? "" : "",
                    GameId = app.TryGetProperty("gameId", out var g) ? g.GetString() ?? "" : "",
                    NameId = app.TryGetProperty("nameId", out var n) ? n.GetString() ?? "" : "",
                    ShortcutName = shortcutName,
                    Launches = launches,
                    PreLaunchesText = FormatPreLaunchesText(launches)
                });
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not read sync list: {ex.Message}", "Bypass Sync List");
        }
    }

    private void ApplySyncListFilter()
    {
        var query = (SyncListFilterBox.Text ?? "").Trim();
        IEnumerable<BypassSyncListEntry> filtered = _allSyncListEntries;
        if (!string.IsNullOrWhiteSpace(query))
        {
            filtered = filtered.Where(e =>
                e.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.GameId.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.NameId.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.ShortcutName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.PreLaunchesText.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        var list = filtered.ToList();
        _syncListGridItems.Clear();
        foreach (var item in list)
            _syncListGridItems.Add(item);
        SyncListGridFooter.Text = list.Count == _allSyncListEntries.Count
            ? $"{_allSyncListEntries.Count} entries"
            : $"Showing {list.Count} of {_allSyncListEntries.Count} entries";
    }

    private void SyncListFilter_Changed(object sender, RoutedEventArgs e) => ApplySyncListFilter();

    private void SyncListGrid_CellEditEnding(object sender, DataGridCellEditEndingEventArgs e)
    {
        if (_suppressSyncListGridSave || e.EditAction != DataGridEditAction.Commit)
            return;
        if (e.Row.Item is not BypassSyncListEntry entry)
            return;

        Dispatcher.BeginInvoke(() => DeferSyncListGridSave(entry), DispatcherPriority.ApplicationIdle);
    }

    private void DeferSyncListGridSave(BypassSyncListEntry entry)
    {
        SyncListGrid.CommitEdit(DataGridEditingUnit.Row, true);

        if (!SaveSyncListEntry(entry, showSuccess: false))
            LoadSyncListSummary();
    }

    private bool SaveSyncListEntry(BypassSyncListEntry entry, bool showSuccess = true)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return false;
        }

        var title = (entry.Title ?? "").Trim();
        var shortcutName = (entry.ShortcutName ?? "").Trim();
        var gameId = (entry.GameId ?? "").Trim();
        var nameId = (entry.NameId ?? "").Trim();

        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(shortcutName))
        {
            MessageBox.Show("Title and Shortcut Name are required.", "Bypass Sync List");
            return false;
        }

        var hasGameId = !string.IsNullOrWhiteSpace(gameId);
        var hasNameId = !string.IsNullOrWhiteSpace(nameId);
        if (hasGameId == hasNameId)
        {
            MessageBox.Show("Set exactly one of GameId (Steam/Epic) or NameId (Manual).", "Bypass Sync List");
            return false;
        }

        var launches = ParsePreLaunchesText(entry.PreLaunchesText);
        entry.Launches = launches;

        var originalShortcut = (entry.OriginalShortcutName ?? "").Trim();
        if (!string.IsNullOrWhiteSpace(originalShortcut) &&
            !string.Equals(originalShortcut, shortcutName, StringComparison.OrdinalIgnoreCase))
        {
            var delArgs = $"-DeleteShortcutName \"{EscapePsArg(originalShortcut)}\"";
            var del = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Merge-BypassSyncList.ps1", delArgs);
            if (!del.Success)
            {
                MessageBox.Show(del.Message, "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Warning);
                return false;
            }
        }

        var onDup = string.IsNullOrWhiteSpace(originalShortcut) ||
                    string.Equals(originalShortcut, shortcutName, StringComparison.OrdinalIgnoreCase)
            ? "Replace"
            : "Skip";

        var args = BuildSyncListMergeArgs(title, shortcutName, gameId, nameId, launches, onDup);

        var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Merge-BypassSyncList.ps1", args);
        if (!r.Success)
        {
            MessageBox.Show(r.Message, "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }

        if (showSuccess)
            ShowSyncListMergeResult(r, clearOnSuccess: false);
        else
            entry.OriginalShortcutName = shortcutName;

        return true;
    }

    private void ReloadSyncListQuiet()
    {
        _suppressSyncListGridSave = true;
        try
        {
            LoadSyncListSummary();
        }
        finally
        {
            _suppressSyncListGridSave = false;
        }
    }

    private void RefreshSyncListGrid_Click(object sender, RoutedEventArgs e) => LoadSyncListSummary();

    private void AddSyncListEntry_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var title = (SyncListTitleBox.Text ?? "").Trim();
        var shortcutName = (SyncListShortcutNameBox.Text ?? "").Trim();
        var gameId = (SyncListGameIdBox.Text ?? "").Trim();
        var nameId = (SyncListNameIdBox.Text ?? "").Trim();
        var preLaunches = GetPreLaunchesFromForm();

        if (string.IsNullOrWhiteSpace(title) || string.IsNullOrWhiteSpace(shortcutName))
        {
            MessageBox.Show("Title and Shortcut Name are required.", "Bypass Sync List");
            return;
        }

        var hasGameId = !string.IsNullOrWhiteSpace(gameId);
        var hasNameId = !string.IsNullOrWhiteSpace(nameId);
        if (hasGameId == hasNameId)
        {
            MessageBox.Show("Set exactly one of GameId (Steam/Epic) or NameId (Manual).", "Bypass Sync List");
            return;
        }

        var dup = _allSyncListEntries.FirstOrDefault(e =>
            (!string.IsNullOrWhiteSpace(gameId) && string.Equals(e.GameId, gameId, StringComparison.OrdinalIgnoreCase)) ||
            (!string.IsNullOrWhiteSpace(nameId) && string.Equals(e.NameId, nameId, StringComparison.OrdinalIgnoreCase)) ||
            string.Equals(e.ShortcutName, shortcutName, StringComparison.OrdinalIgnoreCase));

        var onDup = "Skip";
        if (dup is not null)
        {
            var choice = MessageBox.Show(
                $"An entry already exists for this ID or shortcut ({dup.Title}). Replace it?",
                "Bypass Sync List", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
            if (choice == MessageBoxResult.Cancel)
                return;
            if (choice == MessageBoxResult.Yes)
                onDup = "Replace";
            else
                return;
        }

        var args = BuildSyncListMergeArgs(title, shortcutName, gameId, nameId, preLaunches, onDup);

        var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Merge-BypassSyncList.ps1", args);
        ShowSyncListMergeResult(r, clearOnSuccess: onDup == "Replace" || dup is null);
    }

    private void ImportSyncList_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var dlg = new OpenFileDialog
        {
            Filter = "JSON (*.json)|*.json",
            Title = "Import Bypass Sync List"
        };
        if (dlg.ShowDialog() != true)
            return;

        var policy = MessageBox.Show(
            "Import with Skip duplicates (recommended)?\n\nYes = Skip duplicates\nNo = Replace existing entries",
            "Bypass Sync List", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (policy == MessageBoxResult.Cancel)
            return;

        var onDup = policy == MessageBoxResult.Yes ? "Skip" : "Replace";
        var args = $"-ImportPath \"{dlg.FileName}\" -OnDuplicate {onDup}";
        var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Merge-BypassSyncList.ps1", args);
        ShowSyncListMergeResult(r, clearOnSuccess: false);
    }

    private void ExportSyncList_Click(object sender, RoutedEventArgs e)
    {
        var path = GetSyncListPath();
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            MessageBox.Show("Sync list file not found. Add entries or create the sync list first.", "Bypass Sync List");
            return;
        }

        if (_allSyncListEntries.Count == 0)
        {
            MessageBox.Show("Sync list is empty. Add entries before exporting.", "Bypass Sync List");
            return;
        }

        var dlg = new SaveFileDialog
        {
            Filter = "JSON (*.json)|*.json",
            Title = "Export Bypass Sync List",
            FileName = "bypass-sync-list.json"
        };
        if (dlg.ShowDialog() != true)
            return;

        try
        {
            File.Copy(path, dlg.FileName, overwrite: true);
            MessageBox.Show(
                $"Exported {_allSyncListEntries.Count} entries to:\n{dlg.FileName}",
                "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void DeleteSelectedSyncList_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        if (SyncListGrid.ItemsSource is not IEnumerable<BypassSyncListEntry> visible)
            return;

        var selected = visible.Where(entry => entry.IsSelected).ToList();
        if (selected.Count == 0)
        {
            MessageBox.Show("Select one or more entries using the checkboxes.", "Bypass Sync List");
            return;
        }

        if (MessageBox.Show(
                $"Remove {selected.Count} sync-list entry(ies)?",
                "Bypass Sync List", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;

        foreach (var entry in selected)
        {
            var args = $"-DeleteShortcutName \"{EscapePsArg(entry.ShortcutName)}\"";
            var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Merge-BypassSyncList.ps1", args);
            if (!r.Success)
            {
                MessageBox.Show(r.Message, "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Warning);
                break;
            }
        }

        LoadSyncListSummary();
    }

    private void OpenSyncListNotepad_Click(object sender, RoutedEventArgs e) => OpenSyncListInNotepad();

    private void AddOpenSyncListNotepadButton()
    {
        var btn = ActionPageTools.MakeButton("Open Sync List in Notepad", "Open bypass-sync-list.json in Notepad", (_, _) => OpenSyncListInNotepad());
        if (ToolsPanel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn, "Opens bypass-sync-list.json for manual edits.");
        else
            ToolsPanel.Children.Add(btn);
    }

    private void OpenSyncListInNotepad()
    {
        var path = GetSyncListPath();
        if (string.IsNullOrWhiteSpace(path))
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(dir) && !Directory.Exists(dir))
            Directory.CreateDirectory(dir);

        if (!File.Exists(path))
        {
            var template = Path.Combine(dir ?? "", "bypass-sync-list.json.template");
            if (File.Exists(template))
                File.Copy(template, path);
        }

        try
        {
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "NextGPU");
        }
    }

    private void ShowSyncListMergeResult((bool Success, string Message) r, bool clearOnSuccess)
    {
        if (!r.Success)
        {
            MessageBox.Show(r.Message, "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(r.Message);
            var root = doc.RootElement;
            var msg = root.TryGetProperty("Message", out var m) ? m.GetString() : r.Message;
            MessageBox.Show(msg ?? "Saved.", "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch
        {
            MessageBox.Show(r.Message, "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Information);
        }

        if (clearOnSuccess)
        {
            SyncListTitleBox.Clear();
            SyncListGameIdBox.Clear();
            SyncListNameIdBox.Clear();
            SyncListShortcutNameBox.Clear();
            ClearPreLaunchRows();
        }

        LoadSyncListSummary();
    }

    private static string EscapePsArg(string value) => value.Replace("\"", "`\"");

    private void SyncListHelp_Click(object sender, RoutedEventArgs e) =>
        MessageBox.Show(SyncListHelpText, "Bypass Sync List", MessageBoxButton.OK, MessageBoxImage.Information);

    private const string SyncListHelpText =
        """
        The bypass sync list declares which shortcuts setup/sync may touch.

        Each entry needs:
        - title
        - shortcutName — RunAsTool .lnk base name; always the final launch step
        - gameId (Steam/Epic) OR nameId (Manual allowlist id) — exactly one
        - launches[] (optional) — ordered pre-launch paths with delaySec, then the shortcut

        Setup copies the checked seed shortcuts from the Setup tab (defaults to sync-list primary + pre-launch .lnk names).
        Sync generates a .cmd that runs pre-launches then the primary .lnk.
        """;

    private void BypassHelp_Click(object sender, RoutedEventArgs e) =>
        MessageBox.Show(BypassSectionHelpText, "Bypass Shortcuts", MessageBoxButton.OK, MessageBoxImage.Information);

    private const string BypassSectionHelpText =
        """
        Bypass shortcuts let Playnite launch elevated games through RunAsTool .lnk files.

        Typical workflow:
        1. Add games to bypass-sync-list.json (from PlayNite library or the Sync tab form)
        2. On Setup, review available seed .lnk files and check which ones to copy (Export/Import selection supported)
        3. Setup Bypass (Automated) — copies checked seed shortcuts and imports filtered RunAsTool apps
        4. Review and Sync — updates Playnite launch paths for sync-list entries only (no Sunshine export)

        After Steam library updates, run Re-sync Shortcuts so play paths stay on the bypass launchers.

        NextGPUBypassGuard publishes bypass-bindings.json so paths survive --updatelibraries.
        """;

    private string GetGameShortcutsFolder()
    {
        var repo = App.Session.RepoRoot;
        if (string.IsNullOrWhiteSpace(repo))
            return "";

        var configPath = Path.Combine(repo, RepoCatalog.PlayNiteWatcherRelativeDir, @"config\playnite\bypass-shortcuts.json");
        if (!File.Exists(configPath))
            return "";

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(configPath));
            if (!doc.RootElement.TryGetProperty("bypassesPath", out var pathEl))
                return "";

            var path = pathEl.GetString()?.Trim();
            if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
                return "";

            return path.TrimEnd('\\', '/');
        }
        catch
        {
            return "";
        }
    }

    private void AddConfirmedPowerShellButton(Panel panel, string label, string relativePath, string args, string confirm, string helpText)
    {
        var btn = ActionPageTools.MakeButton(label, helpText, (_, _) =>
        {
            if (MessageBox.Show(confirm, "NextGPU", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                return;
            if (App.Session.Scripts is null)
            {
                MessageBox.Show("Repo not configured.", "NextGPU");
                return;
            }
            var r = App.Session.Scripts.RunPowerShellRelative(relativePath, args, elevated: true, keepConsoleOpen: true);
            MessageBox.Show(r.Message, "NextGPU", MessageBoxButton.OK,
                r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
        });
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn, helpText);
        else
            panel.Children.Add(btn);
    }

    private void AddOpenPlayniteLogButton(Panel panel, string label, string fileName, string helpText)
    {
        var btn = ActionPageTools.MakeButton(label, helpText, (_, _) => OpenPlayniteLog(fileName));
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn, helpText);
        else
            panel.Children.Add(btn);
    }

    private void OpenPlayniteLog(string fileName)
    {
        var repo = App.Session.RepoRoot;
        if (string.IsNullOrWhiteSpace(repo))
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var path = Path.Combine(repo, RepoCatalog.PlayNiteWatcherRelativeDir, fileName);
        if (!File.Exists(path))
        {
            MessageBox.Show($"Log not found yet:\n{path}", "NextGPU");
            return;
        }

        try
        {
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "NextGPU");
        }
    }
}

public sealed class BypassSyncDraft
{
    public string Title { get; set; } = "";
    public string GameId { get; set; } = "";
    public string NameId { get; set; } = "";
    public string SuggestedShortcutName { get; set; } = "";

    public bool HasPending =>
        !string.IsNullOrWhiteSpace(Title) ||
        !string.IsNullOrWhiteSpace(GameId) ||
        !string.IsNullOrWhiteSpace(NameId);

    public void Clear()
    {
        Title = "";
        GameId = "";
        NameId = "";
        SuggestedShortcutName = "";
    }
}
