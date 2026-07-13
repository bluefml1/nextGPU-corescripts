using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using NextGPU.App;
using NextGPU.Core;

namespace NextGPU.App.Pages;

public partial class PlaynitePage : Page
{
    private sealed record AllowlistTypeDef(string Type, string Label, long Base, long MinId, long MaxId, int MaxSlots);

    private static readonly AllowlistTypeDef[] AllowlistTypes =
    [
        new("Adobe", "Adobe Applications", 10000000, 10000001, 10000100, 100),
        new("Autodesk", "Autodesk Applications", 10000100, 10000101, 10000200, 100),
        new("ThirdParty", "Third-Party Applications", 10000200, 10000201, 10000300, 100),
        new("Games", "Games", 10000300, 10000301, 10000999, 699),
    ];

    private readonly List<PlayniteAllowlistEntry> _allAllowlistEntries = [];
    private readonly List<PlayniteLibraryEntry> _allLibraryEntries = [];
    private bool _allowlistViewerVisible;
    private bool _allowlistAddFormVisible;
    private bool _libraryViewerVisible;
    private Button? _viewAllowlistBtn;

    public PlaynitePage()
    {
        InitializeComponent();
        Loaded += (_, _) => OnLoaded();
    }

    private void OnLoaded()
    {
        PopulateAllowlistTypeCombos();
        PopulateLibrarySourceFilter();
        BuildButtons();
        BuildAllowlistActionButtons();
        BuildLibraryActionButtons();
        BuildVerifyActionButtons();
        ApplyAllowlistAddFormVisibility();
        LoadAllowlistSummary();
        UpdateNameIdPreview();
    }

    private void ApplyAllowlistAddFormVisibility()
    {
        AllowlistAddFormPanel.Visibility = _allowlistAddFormVisible ? Visibility.Visible : Visibility.Collapsed;
        ToggleAllowlistFormBtn.Content = _allowlistAddFormVisible ? "Hide Add Form" : "Add App";
    }

    private void PopulateAllowlistTypeCombos()
    {
        AllowlistTypeCombo.Items.Clear();
        foreach (var t in AllowlistTypes)
            AllowlistTypeCombo.Items.Add(t.Label);
        AllowlistTypeCombo.SelectedIndex = 0;

        AllowlistTypeFilterCombo.Items.Clear();
        AllowlistTypeFilterCombo.Items.Add("All");
        foreach (var t in AllowlistTypes)
            AllowlistTypeFilterCombo.Items.Add(t.Type);
        AllowlistTypeFilterCombo.SelectedIndex = 0;
    }

    private void BuildButtons()
    {
        SetupPanel.Children.Clear();
        ExportPanel.Children.Clear();

        ActionPageTools.AddPrimaryBatchButton(SetupPanel, "Run Full PlayNite Setup",
            @"PlayNiteWatcher\Setup-PlayniteSteam.bat", keepConsoleOpen: true,
            helpText: "End-to-end first-time setup: installs portable Playnite, grants BUILTIN\\Users Modify on the Playnite folder (rental ACL), configures Steam/Epic disk scan, updates libraries, exports to Sunshine, installs PlayNiteWatcher, and pushes Moonlight games to AWS. Run elevated after RegisterMachine when Sunshine is present.");
        ActionPageTools.AddPowerShellButton(SetupPanel, "Grant Playnite Rental Access",
            @"PlayNiteWatcher\Grant-PlayniteRentalAccess.ps1", "", keepConsoleOpen: true,
            helpText: "Grants BUILTIN\\Users Modify on the portable Playnite install folder so the nextGPU rental user can write games.db and config. Run elevated after setup or when Verify shows P7 Rental write access failed.");
        ActionPageTools.AddPowerShellButton(SetupPanel, "Setup Playnite Only",
            @"PlayNiteWatcher\Setup-PlayniteSteam.ps1", "-PickInstallFolder", keepConsoleOpen: true,
            helpText: "Installs or configures portable Playnite only (includes rental ACL grant). Prompts for install folder. Does not run the full Sunshine export + watcher pipeline.");
        ActionPageTools.AddPowerShellButton(SetupPanel, "Re-run Setup (Skip Install)",
            @"PlayNiteWatcher\Setup-PlayniteSteam.ps1", "-PickInstallFolder -WithSunshine -SkipInstall", keepConsoleOpen: true,
            helpText: "Re-applies Playnite configuration, rental ACL, and Sunshine integration without re-downloading Playnite. Use when extensions, library config, games.db, or rental ACL need repair.");
        ActionPageTools.AddBatchButton(SetupPanel, "Update Libraries",
            @"PlayNiteWatcher\Update-PlayniteLibraries.bat", keepConsoleOpen: true,
            helpText: "Scans installed Steam and Epic games on disk and imports them into Playnite's games.db. Run after new games are installed or when library is empty.");
        ActionPageTools.AddPowerShellButton(SetupPanel, "Update Libraries (Skip Metadata)",
            @"PlayNiteWatcher\Update-PlayniteLibraries.ps1", "-SkipMetadata", keepConsoleOpen: true,
            helpText: "Same as Update Libraries but skips metadata enrichment for a faster refresh when only game presence needs updating.");
        ActionPageTools.AddBatchButton(SetupPanel, "Import Desktop Apps",
            @"PlayNiteWatcher\Import-PlayniteDesktopApps.bat", ImportDesktopAppsHeadlessArgs, keepConsoleOpen: true,
            elevated: false,
            helpText: "Imports allowlisted desktop apps (Adobe, Autodesk, etc.) into Playnite using Everything (es.exe) to locate executables. Run after editing the allowlist.");
        ActionPageTools.AddBatchButton(SetupPanel, "Import Desktop Apps (Directory Walk)",
            @"PlayNiteWatcher\Import-PlayniteDesktopApps.bat", ImportDesktopAppsDirectoryWalkArgs, keepConsoleOpen: true,
            elevated: false,
            helpText: "Imports allowlisted desktop apps without Everything by walking install directories. Slower but works when es.exe is unavailable.");

        AddSetupActionButton(SetupPanel, "Launch Playnite", (_, _) => LaunchPlaynite(),
            "Opens Playnite.DesktopApp.exe from the saved portable install path for manual inspection or troubleshooting.");
        ActionPageTools.AddOpenExplorerButton(SetupPanel, "Open Playnite Install Folder", GetPlayniteInstallFolder,
            helpText: "Opens the portable Playnite install folder in Explorer (Playnite.DesktopApp.exe, games.db, Extensions).");
        ActionPageTools.AddOpenExplorerButton(SetupPanel, "Open PlayNiteWatcher Folder",
            () => Path.Combine(App.Session.RepoRoot ?? "", RepoCatalog.PlayNiteWatcherRelativeDir),
            helpText: "Opens the PlayNiteWatcher scripts folder in the repo for logs, config, and manual script runs.");

        AddConfirmedPowerShellButton(ExportPanel, "Export to Sunshine",
            @"PlayNiteWatcher\Export-SunshineFromPlaynite.ps1", "",
            "This exports to Sunshine, installs PlayNiteWatcher, and restarts Sunshine. Active Moonlight sessions may end. Continue?",
            "Writes Playnite games and allowlisted desktop apps into Sunshine apps.json, then installs PlayNiteWatcher prep-cmd hooks. Restarts Sunshine.");
        AddConfirmedPowerShellButton(ExportPanel, "Export (Steam/Epic Only)",
            @"PlayNiteWatcher\Export-SunshineFromPlaynite.ps1", "-SkipDesktopApps",
            "This exports to Sunshine, installs PlayNiteWatcher, and restarts Sunshine. Active Moonlight sessions may end. Continue?",
            "Exports only Steam and Epic games to Sunshine, then installs PlayNiteWatcher hooks. Skips desktop allowlist entries.");
        AddConfirmedPowerShellButton(ExportPanel, "Install Watcher (Skip Re-Export)",
            @"PlayNiteWatcher\Install-PlayniteWatcher.ps1", "-SkipExport",
            "This restarts Sunshine and may terminate active Moonlight sessions. Continue?",
            "Applies watcher hooks to the current apps.json without re-exporting from Playnite. Use export buttons to refresh apps.json first.");
        AddConfirmedPowerShellButton(ExportPanel, "Uninstall PlayNiteWatcher",
            @"PlayNiteWatcher\Install-PlayniteWatcher.ps1", "-Uninstall",
            "Remove PlayNiteWatcher hooks and Playnite-managed Sunshine apps?",
            "Removes PlayNiteWatcher prep-cmd hooks and Playnite-managed entries from Sunshine apps.json.");

        AddOpenPlayniteLogButton(ExportPanel, "Open Setup Log", RepoCatalog.PlayniteSetupLog,
            "Opens Setup-PlayniteSteam.log — install path, extension setup, and first library import details.");
        AddOpenPlayniteLogButton(ExportPanel, "Open Export Log", RepoCatalog.PlayniteExportLog,
            "Opens Export-SunshineFromPlaynite.log — which games were exported and any Sunshine write errors.");
        AddOpenPlayniteLogButton(ExportPanel, "Open Watcher Install Log", RepoCatalog.PlayniteWatcherInstallLog,
            "Opens Install-PlayniteWatcher.log — prep-cmd injection and Sunshine restart results.");
        AddOpenPlayniteLogButton(ExportPanel, "Open Library Update Log", RepoCatalog.PlayniteLibraryUpdateLog,
            "Opens Update-PlayniteLibraries.log — Steam/Epic disk scan and import completion lines.");
        AddOpenPlayniteLogButton(ExportPanel, "Open Desktop Import Log", RepoCatalog.PlayniteDesktopImportLog,
            "Opens Import-PlayniteDesktopApps.log — allowlist scan, Everything search, and games.db sync results.");
        AddOpenPlayniteLogButton(ExportPanel, "Open Watcher Runtime Log", RepoCatalog.PlayniteWatcherRuntimeLog,
            "Opens PlayNiteWatcher runtime log — session start/stop and cleanup events during Moonlight streaming.");
    }

    private const string ImportDesktopAppsHeadlessArgs = "-Headless -DesktopImportScanMode AllDrives";
    private const string ImportDesktopAppsDirectoryWalkArgs = "-Headless -DesktopImportScanMode AllDrives -SkipEverythingInstall";

    private void BuildAllowlistActionButtons()
    {
        AllowlistActionsPanel.Children.Clear();
        AllowlistViewerActionsPanel.Children.Clear();
        AllowlistGridActionsPanel.Children.Clear();

        AddPlainInlineActionButton(AllowlistActionsPanel, "Add to Allowlist", AddToAllowlist_Click, "PrimaryButton");
        AddPlainInlineActionButton(AllowlistActionsPanel, "Import Allowlist File", ImportAllowlist_Click, "SecondaryButton");
        AddPlainInlineActionButton(AllowlistActionsPanel, "Export Allowlist File", ExportAllowlist_Click, "SecondaryButton");

        _viewAllowlistBtn = CreateInlineActionButton("View Allowlist", ViewAllowlist_Click, "SecondaryButton", "View allowlist");
        _viewAllowlistBtn.Margin = new Thickness(0, 0, 8, 0);
        AllowlistViewerActionsPanel.Children.Add(_viewAllowlistBtn);
        AddPlainInlineActionButton(AllowlistViewerActionsPanel, "Open Allowlist in Notepad", OpenAllowlistNotepad_Click, "GhostButton");

        AllowlistGridActionsPanel.Children.Add(AllowlistFilterBox);
        AllowlistGridActionsPanel.Children.Add(AllowlistTypeFilterCombo);
        AddPlainInlineActionButton(AllowlistGridActionsPanel, "Refresh", RefreshAllowlistGrid_Click, "GhostButton");
        AddPlainInlineActionButton(AllowlistGridActionsPanel, "Delete Selected", DeleteSelectedAllowlist_Click, "SecondaryButton");
    }

    private static void AddPlainInlineActionButton(Panel panel, string label, RoutedEventHandler onClick, string styleKey)
    {
        var btn = CreateInlineActionButton(label, onClick, styleKey, label);
        btn.Margin = new Thickness(0, 0, 8, 8);
        panel.Children.Add(btn);
    }

    private void BuildVerifyActionButtons()
    {
        VerifyActionsPanel.Children.Clear();
        AddInlineActionButton(VerifyActionsPanel, "Verify PlayNite Status", VerifyStatus_Click, "PrimaryButton",
            "Runs Test-PlayniteHostStatus.ps1 and shows a checklist: Playnite install, rental ACL (P7), Steam/Epic library, allowlist, Sunshine export, and watcher hooks. Failed rows include fix actions.");
        AddInlineActionButton(VerifyActionsPanel, "Re-verify", VerifyStatus_Click, "GhostButton",
            "Runs the same host status check again after you apply fixes.");
    }

    private static void AddSetupActionButton(Panel panel, string label, RoutedEventHandler onClick, string helpText)
    {
        var btn = ActionPageTools.MakeButton(label, label, onClick);
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn, helpText);
        else
            panel.Children.Add(btn);
    }

    private void AddInlineActionButton(Panel panel, string label, RoutedEventHandler onClick, string styleKey, string helpText)
    {
        var btn = CreateInlineActionButton(label, onClick, styleKey, helpText);
        panel.Children.Add(UiLayoutHelper.WrapInlineActionWithHelp(btn, helpText));
    }

    private static Button CreateInlineActionButton(string label, RoutedEventHandler onClick, string styleKey, string helpText)
    {
        var btn = new Button
        {
            Content = label,
            Style = (Style)Application.Current.FindResource(styleKey),
            Padding = new Thickness(styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10,
                styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10),
            ToolTip = helpText
        };
        btn.Click += onClick;
        return btn;
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

    private string GetPlayniteInstallFolder()
    {
        var repo = App.Session.RepoRoot;
        if (string.IsNullOrWhiteSpace(repo))
            return "";
        var pathFile = Path.Combine(repo, RepoCatalog.PlayNiteWatcherRelativeDir, RepoCatalog.PlayniteInstallPathFile);
        if (!File.Exists(pathFile))
            return "";
        var saved = File.ReadAllText(pathFile).Trim();
        if (string.IsNullOrWhiteSpace(saved))
            return "";
        // PlayniteInstall.path stores the full portable folder (e.g. Z:\Playnite), not the parent.
        return saved.TrimEnd('\\', '/');
    }

    private void LaunchPlaynite()
    {
        var dir = GetPlayniteInstallFolder();
        var exe = string.IsNullOrWhiteSpace(dir) ? "" : Path.Combine(dir, "Playnite.DesktopApp.exe");
        if (!File.Exists(exe))
        {
            MessageBox.Show("Playnite is not configured. Run Full PlayNite Setup first.", "NextGPU");
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "NextGPU");
        }
    }

    private string GetAllowlistPath()
    {
        var repo = App.Session.RepoRoot;
        return string.IsNullOrWhiteSpace(repo) ? "" : Path.Combine(repo, RepoCatalog.PlayniteAllowlistRelativePath);
    }

    private AllowlistTypeDef? GetSelectedTypeDef()
    {
        if (AllowlistTypeCombo.SelectedIndex < 0 || AllowlistTypeCombo.SelectedIndex >= AllowlistTypes.Length)
            return AllowlistTypes[0];
        return AllowlistTypes[AllowlistTypeCombo.SelectedIndex];
    }

    private const long AllowlistSuffixBase = 10000000;

    private static string? TryResolveNameId(AllowlistTypeDef def, string input)
    {
        var digits = new string(input.Where(char.IsDigit).ToArray());
        if (string.IsNullOrWhiteSpace(digits))
            return null;

        if (!long.TryParse(digits, out var numeric))
            return null;

        if (digits.Length >= 8 && numeric >= def.MinId && numeric <= def.MaxId)
            return numeric.ToString();

        var slot = (int)(numeric % 1000);
        if (!IsSlotInShortInputRange(def, slot))
            return null;

        return TryResolveNameIdFromSlot(def, slot)?.ToString();
    }

    private static bool IsSlotInShortInputRange(AllowlistTypeDef def, int slot)
    {
        if (string.Equals(def.Type, "Games", StringComparison.OrdinalIgnoreCase))
            return slot >= 1 && slot <= def.MaxSlots;

        var minSlot = (int)(def.MinId - AllowlistSuffixBase);
        var maxSlot = (int)(def.MaxId - AllowlistSuffixBase);
        return slot >= minSlot && slot <= maxSlot;
    }

    private static long? TryResolveNameIdFromSlot(AllowlistTypeDef def, int slot)
    {
        var suffixCandidate = AllowlistSuffixBase + slot;
        if (suffixCandidate >= def.MinId && suffixCandidate <= def.MaxId)
            return suffixCandidate;

        // Games only: allow ordinal slot 1..699 → 10000301+ when suffix is below range.
        if (string.Equals(def.Type, "Games", StringComparison.OrdinalIgnoreCase))
        {
            var offsetCandidate = def.Base + slot;
            if (offsetCandidate >= def.MinId && offsetCandidate <= def.MaxId)
                return offsetCandidate;
        }

        return null;
    }

    private static string DescribeSlotRange(AllowlistTypeDef def) =>
        def.Type switch
        {
            "Adobe" => "1–100",
            "Autodesk" => "101–200",
            "ThirdParty" => "201–300",
            "Games" => "301–999 (or ordinal 1–699)",
            _ => $"{def.MinId}–{def.MaxId}"
        };

    private static string FormatSlotInputForNameId(AllowlistTypeDef def, long nameId)
    {
        var suffixSlot = nameId - AllowlistSuffixBase;
        if (suffixSlot is >= 1 and <= 999)
        {
            var resolved = TryResolveNameIdFromSlot(def, (int)suffixSlot);
            if (resolved == nameId)
                return suffixSlot.ToString();
        }

        return (nameId - def.Base).ToString();
    }

    private void ToggleAllowlistForm_Click(object sender, RoutedEventArgs e)
    {
        _allowlistAddFormVisible = !_allowlistAddFormVisible;
        ApplyAllowlistAddFormVisibility();
        if (_allowlistAddFormVisible && string.IsNullOrWhiteSpace(AllowlistSlotBox.Text))
            SuggestNextSlot();
    }

    private void AllowlistHelp_Click(object sender, RoutedEventArgs e) =>
        MessageBox.Show(AllowlistSectionHelpText, "Desktop App Allowlist", MessageBoxButton.OK, MessageBoxImage.Information);

    private const string AllowlistSectionHelpText =
        """
        The Desktop App Allowlist tells PlayNite which non-Steam/Epic desktop programs to add to your library and export to Sunshine for Moonlight streaming.

        For each app you provide:
        • Executable — filename only (e.g. Photoshop.exe), not the full install path. Everything or a directory walk finds the real path.
        • Slot / Name ID — type a short ID in range (Adobe 1–100, Autodesk 101–200, Third-Party 201–300, Games 301–999). Preview shows the final 8-digit nameId.
        • Type — Adobe, Autodesk, ThirdParty, or Games (each has its own ID range).

        Typical workflow:
        1. Add entries here (or Import from JSON/CSV)
        2. Run Import Desktop Apps
        3. Run Export to Sunshine

        Use Export Allowlist File to back up or move your list to another machine. Import merges entries with Skip or Replace for duplicates.
        """;

    private void AllowlistForm_Changed(object sender, RoutedEventArgs e)
    {
        if (sender == AllowlistTypeCombo)
        {
            AllowlistSlotBox.Clear();
            SuggestNextSlot();
        }

        UpdateNameIdPreview();
    }

    private void UpdateNameIdPreview()
    {
        var def = GetSelectedTypeDef();
        if (def is null)
        {
            NameIdPreviewText.Text = "";
            return;
        }

        var resolved = TryResolveNameId(def, AllowlistSlotBox.Text ?? "");
        NameIdPreviewText.Text = resolved is null
            ? $"→ invalid slot ({def.Label}: {DescribeSlotRange(def)})"
            : $"→ will save as: {resolved}";
    }

    private void LoadAllowlistSummary()
    {
        ReloadAllowlistEntries();
        var counts = AllowlistTypes.ToDictionary(t => t.Type, _ => 0);
        foreach (var e in _allAllowlistEntries)
        {
            if (counts.ContainsKey(e.Type))
                counts[e.Type]++;
        }

        AllowlistCountText.Text = string.Join(" · ", AllowlistTypes.Select(t => $"{t.Type} {counts[t.Type]}"));
        if (_allowlistAddFormVisible && string.IsNullOrWhiteSpace(AllowlistSlotBox.Text))
            SuggestNextSlot();
    }

    private void SuggestNextSlot()
    {
        var def = GetSelectedTypeDef();
        if (def is null || !string.IsNullOrWhiteSpace(AllowlistSlotBox.Text))
            return;

        var used = new HashSet<long>(_allAllowlistEntries
            .Where(e => string.Equals(e.Type, def.Type, StringComparison.OrdinalIgnoreCase))
            .Select(e => long.TryParse(e.NameId, out var id) ? id : 0L));

        for (var id = def.MinId; id <= def.MaxId; id++)
        {
            if (used.Contains(id))
                continue;

            AllowlistSlotBox.Text = FormatSlotInputForNameId(def, id);
            UpdateNameIdPreview();
            return;
        }
    }

    private void ReloadAllowlistEntries()
    {
        _allAllowlistEntries.Clear();
        var path = GetAllowlistPath();
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            ApplyAllowlistFilter();
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("apps", out var apps))
            {
                ApplyAllowlistFilter();
                return;
            }

            foreach (var app in apps.EnumerateArray())
            {
                var exe = app.TryGetProperty("exe", out var exeEl) ? exeEl.GetString() ?? "" : "";
                var nameId = app.TryGetProperty("nameId", out var idEl) ? idEl.GetString() ?? "" : "";
                var title = app.TryGetProperty("title", out var titleEl) ? titleEl.GetString() ?? "" : "";
                var type = app.TryGetProperty("type", out var typeEl) ? typeEl.GetString() ?? "" : "";
                if (string.IsNullOrWhiteSpace(type) && long.TryParse(nameId, out var nid))
                    type = InferTypeFromNameId(nid) ?? "";
                _allAllowlistEntries.Add(new PlayniteAllowlistEntry
                {
                    Exe = exe,
                    NameId = nameId,
                    Title = title,
                    Type = type
                });
            }
        }
        catch
        {
            // Grid stays empty; merge script validates on write.
        }

        ApplyAllowlistFilter();
    }

    private static string? InferTypeFromNameId(long nameId)
    {
        foreach (var t in AllowlistTypes)
        {
            if (nameId >= t.MinId && nameId <= t.MaxId)
                return t.Type;
        }
        return null;
    }

    private void ApplyAllowlistFilter()
    {
        var query = (AllowlistFilterBox.Text ?? "").Trim();
        var typeFilter = AllowlistTypeFilterCombo.SelectedItem as string ?? "All";

        IEnumerable<PlayniteAllowlistEntry> filtered = _allAllowlistEntries;
        if (!string.Equals(typeFilter, "All", StringComparison.OrdinalIgnoreCase))
            filtered = filtered.Where(e => string.Equals(e.Type, typeFilter, StringComparison.OrdinalIgnoreCase));

        if (!string.IsNullOrWhiteSpace(query))
        {
            filtered = filtered.Where(e =>
                e.Exe.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.Title.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.NameId.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.Type.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        var list = filtered.ToList();
        AllowlistGrid.ItemsSource = new ObservableCollection<PlayniteAllowlistEntry>(list);
        AllowlistGridFooter.Text = list.Count == _allAllowlistEntries.Count
            ? $"{_allAllowlistEntries.Count} apps"
            : $"Showing {list.Count} of {_allAllowlistEntries.Count} apps";
    }

    private void AllowlistFilter_Changed(object sender, RoutedEventArgs e) => ApplyAllowlistFilter();

    private void RefreshAllowlistGrid_Click(object sender, RoutedEventArgs e)
    {
        LoadAllowlistSummary();
    }

    private void DeleteSelectedAllowlist_Click(object sender, RoutedEventArgs e)
    {
        if (AllowlistGrid.ItemsSource is not IEnumerable<PlayniteAllowlistEntry> visible)
        {
            MessageBox.Show("Open the allowlist viewer first.", "Allowlist");
            return;
        }

        var selected = visible.Where(entry => entry.IsSelected).ToList();
        if (selected.Count == 0)
        {
            MessageBox.Show("Select one or more apps using the checkboxes, then click Delete Selected.", "Allowlist");
            return;
        }

        var preview = string.Join(Environment.NewLine, selected.Take(5).Select(e => $"• {e.Exe} ({e.NameId})"));
        if (selected.Count > 5)
            preview += $"{Environment.NewLine}• … and {selected.Count - 5} more";

        if (MessageBox.Show(
                $"Remove {selected.Count} app(s) from the allowlist?{Environment.NewLine}{Environment.NewLine}{preview}",
                "Delete Selected", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
            return;

        var ids = selected.Select(e => e.NameId).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var remaining = _allAllowlistEntries.Where(e => !ids.Contains(e.NameId)).ToList();

        try
        {
            SaveAllowlistToDisk(remaining);
            _allAllowlistEntries.Clear();
            _allAllowlistEntries.AddRange(remaining);
            LoadAllowlistSummary();
            MessageBox.Show(
                $"Removed {selected.Count} app(s).{Environment.NewLine}{Environment.NewLine}Run Import Desktop Apps then Export to Sunshine to apply changes.",
                "Allowlist", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Allowlist", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void SaveAllowlistToDisk(IReadOnlyList<PlayniteAllowlistEntry> entries)
    {
        var path = GetAllowlistPath();
        if (string.IsNullOrWhiteSpace(path))
            throw new InvalidOperationException("Repo not configured.");

        var dir = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(dir) && !Directory.Exists(dir))
            Directory.CreateDirectory(dir);

        if (!File.Exists(path))
        {
            var template = Path.Combine(dir!, "desktop-apps.allowlist.json.template");
            if (File.Exists(template))
                File.Copy(template, path);
        }

        var payload = new
        {
            _comment = "List executable filenames only (exe), not install paths. Setup uses voidtools es.exe to find the real path and writes it into Playnite.",
            apps = entries.Select(e => new
            {
                exe = e.Exe,
                nameId = e.NameId,
                title = e.Title,
                type = e.Type
            }).ToArray()
        };

        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }

    private void ViewAllowlist_Click(object sender, RoutedEventArgs e)
    {
        _allowlistViewerVisible = !_allowlistViewerVisible;
        AllowlistViewerPanel.Visibility = _allowlistViewerVisible ? Visibility.Visible : Visibility.Collapsed;
        if (_viewAllowlistBtn is not null)
            _viewAllowlistBtn.Content = _allowlistViewerVisible ? "Hide Allowlist" : "View Allowlist";
        if (_allowlistViewerVisible)
            LoadAllowlistSummary();
    }

    private void OpenAllowlistNotepad_Click(object sender, RoutedEventArgs e)
    {
        var path = GetAllowlistPath();
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
            var template = Path.Combine(Path.GetDirectoryName(path)!, "desktop-apps.allowlist.json.template");
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

    private void AddToAllowlist_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var def = GetSelectedTypeDef();
        if (def is null)
            return;

        var exe = (AllowlistExeBox.Text ?? "").Trim();
        var slot = (AllowlistSlotBox.Text ?? "").Trim();
        var title = (AllowlistTitleBox.Text ?? "").Trim();
        if (string.IsNullOrWhiteSpace(exe) || string.IsNullOrWhiteSpace(slot))
        {
            MessageBox.Show("Executable and Slot / Name ID are required.", "NextGPU");
            return;
        }

        var resolved = TryResolveNameId(def, slot);
        if (resolved is null)
        {
            MessageBox.Show($"Slot is invalid for {def.Label}. Use {DescribeSlotRange(def)} (nameId {def.MinId}–{def.MaxId}).", "NextGPU");
            return;
        }

        if (_allAllowlistEntries.Any(a => a.NameId == resolved))
        {
            var choice = MessageBox.Show(
                $"nameId {resolved} already exists. Replace the existing entry?",
                "NextGPU", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
            if (choice == MessageBoxResult.Cancel)
                return;
            if (choice == MessageBoxResult.No)
                return;
        }

        var args = $"-Exe \"{exe}\" -NameIdInput \"{slot}\" -Title \"{title}\" -Type {def.Type} -OnDuplicateNameId Replace";
        var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Merge-DesktopAppAllowlist.ps1", args);
        ShowMergeResult(r, clearOnSuccess: true);
    }

    private void ImportAllowlist_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var dlg = new OpenFileDialog
        {
            Filter = "Allowlist files|*.json;*.csv|JSON (*.json)|*.json|CSV (*.csv)|*.csv",
            Title = "Import Allowlist File"
        };
        if (dlg.ShowDialog() != true)
            return;

        var policy = MessageBox.Show(
            "Import with Skip duplicates (recommended)?\n\nYes = Skip duplicates\nNo = Replace existing entries",
            "NextGPU", MessageBoxButton.YesNoCancel, MessageBoxImage.Question);
        if (policy == MessageBoxResult.Cancel)
            return;

        var onDup = policy == MessageBoxResult.Yes ? "Skip" : "Replace";
        var args = $"-ImportPath \"{dlg.FileName}\" -OnDuplicateNameId {onDup}";
        var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Merge-DesktopAppAllowlist.ps1", args);
        ShowMergeResult(r, clearOnSuccess: false);
    }

    private void ExportAllowlist_Click(object sender, RoutedEventArgs e)
    {
        ReloadAllowlistEntries();
        var path = GetAllowlistPath();
        if (string.IsNullOrWhiteSpace(path) || !File.Exists(path))
        {
            MessageBox.Show("Allowlist file not found. Add entries or create the allowlist first.", "NextGPU");
            return;
        }

        if (_allAllowlistEntries.Count == 0)
        {
            MessageBox.Show("Allowlist is empty. Add entries before exporting.", "NextGPU");
            return;
        }

        var dlg = new SaveFileDialog
        {
            Filter = "JSON (*.json)|*.json|CSV (*.csv)|*.csv",
            Title = "Export Allowlist File",
            FileName = "desktop-apps.allowlist.json"
        };
        if (dlg.ShowDialog() != true)
            return;

        try
        {
            if (dlg.FileName.EndsWith(".csv", StringComparison.OrdinalIgnoreCase))
                WriteAllowlistCsv(dlg.FileName, _allAllowlistEntries);
            else
                WriteAllowlistJson(dlg.FileName);

            MessageBox.Show(
                $"Exported {_allAllowlistEntries.Count} entries to:\n{dlg.FileName}",
                "Allowlist", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Allowlist", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void WriteAllowlistJson(string destinationPath)
    {
        var apps = _allAllowlistEntries.Select(e => new
        {
            exe = e.Exe,
            nameId = e.NameId,
            title = e.Title,
            type = e.Type
        }).ToArray();

        var payload = new { apps };
        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(destinationPath, json);
    }

    private static void WriteAllowlistCsv(string destinationPath, IEnumerable<PlayniteAllowlistEntry> entries)
    {
        using var writer = new StreamWriter(destinationPath);
        writer.WriteLine("exe,nameId,title,type");
        foreach (var entry in entries)
        {
            writer.WriteLine($"{CsvEscape(entry.Exe)},{CsvEscape(entry.NameId)},{CsvEscape(entry.Title)},{CsvEscape(entry.Type)}");
        }
    }

    private static string CsvEscape(string value)
    {
        if (value.Contains('"') || value.Contains(',') || value.Contains('\n') || value.Contains('\r'))
            return $"\"{value.Replace("\"", "\"\"")}\"";
        return value;
    }

    private void ShowMergeResult((bool Success, string Message) r, bool clearOnSuccess)
    {
        if (!r.Success)
        {
            MessageBox.Show(r.Message, "Allowlist", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        try
        {
            using var doc = JsonDocument.Parse(r.Message);
            var root = doc.RootElement;
            var msg = root.TryGetProperty("Message", out var m) ? m.GetString() : r.Message;
            MessageBox.Show(
                $"{msg}{Environment.NewLine}{Environment.NewLine}Run Import Desktop Apps then Export to Sunshine to apply changes.",
                "Allowlist", MessageBoxButton.OK, MessageBoxImage.Information);

            if (clearOnSuccess)
            {
                AllowlistExeBox.Clear();
                AllowlistTitleBox.Clear();
                AllowlistSlotBox.Clear();
            }

            LoadAllowlistSummary();
        }
        catch
        {
            MessageBox.Show(r.Message, "Allowlist", MessageBoxButton.OK, MessageBoxImage.Information);
            LoadAllowlistSummary();
        }
    }

    private void VerifyStatus_Click(object sender, RoutedEventArgs e)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Test-PlayniteHostStatus.ps1", "");
        if (!r.Success && string.IsNullOrWhiteSpace(r.Message))
        {
            MessageBox.Show("Verify script failed.", "NextGPU");
            return;
        }

        RenderVerifyResults(r.Message);
    }

    private static string ExtractVerifyJson(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return raw;

        var start = raw.IndexOf('{');
        var end = raw.LastIndexOf('}');
        if (start >= 0 && end > start)
            return raw[start..(end + 1)];

        return raw.Trim();
    }

    private void RenderVerifyResults(string json)
    {
        VerifyChecksPanel.Children.Clear();
        VerifyResultsPanel.Visibility = Visibility.Visible;

        try
        {
            using var doc = JsonDocument.Parse(ExtractVerifyJson(json));
            var root = doc.RootElement;
            var overall = root.TryGetProperty("overall", out var o) ? o.GetString() : "Unknown";
            var requiredFailed = root.TryGetProperty("requiredFailed", out var rf) ? rf.GetInt32() : 0;
            var warnings = root.TryGetProperty("warnings", out var w) ? w.GetInt32() : 0;

            VerifySummaryText.Text = overall switch
            {
                "Healthy" => "PlayNite Status: Healthy",
                "Degraded" => $"PlayNite Status: Degraded ({warnings} warning(s))",
                _ => $"PlayNite Status: Not ready ({requiredFailed} required failure(s), {warnings} warning(s))"
            };

            StatusBadgeText.Text = overall switch
            {
                "Healthy" => "Status: Healthy",
                "Degraded" => "Status: Degraded",
                _ => "Status: Not ready"
            };
            StatusBadgeText.Foreground = overall switch
            {
                "Healthy" => (Brush)FindResource("OkBrush"),
                "Degraded" => (Brush)FindResource("WarnBrush"),
                _ => (Brush)FindResource("ErrBrush")
            };

            if (!root.TryGetProperty("checks", out var checks))
                return;

            foreach (var check in checks.EnumerateArray())
            {
                var id = check.TryGetProperty("id", out var idEl) ? idEl.GetString() : "";
                var name = check.TryGetProperty("name", out var nameEl) ? nameEl.GetString() : "";
                var status = check.TryGetProperty("status", out var stEl) ? stEl.GetString() : "";
                var detail = check.TryGetProperty("detail", out var detEl) ? detEl.GetString() : "";
                var fixAction = check.TryGetProperty("fixAction", out var faEl) ? faEl.GetString() : "";
                var fixLabel = check.TryGetProperty("fixLabel", out var flEl) ? flEl.GetString() : "";

                var line = new TextBlock
                {
                    TextWrapping = TextWrapping.Wrap,
                    Margin = new Thickness(0, 0, 0, 6),
                    Foreground = status switch
                    {
                        "Pass" => (Brush)FindResource("OkBrush"),
                        "Warn" => (Brush)FindResource("WarnBrush"),
                        "Skip" => (Brush)FindResource("MutedBrush"),
                        _ => (Brush)FindResource("ErrBrush")
                    },
                    Text = $"[{status?.ToUpperInvariant()}] {id} {name} — {detail}"
                };
                VerifyChecksPanel.Children.Add(line);

                if (!string.IsNullOrWhiteSpace(fixAction) && !string.IsNullOrWhiteSpace(fixLabel) &&
                    status is "Fail" or "Warn")
                {
                    var action = fixAction;
                    var label = fixLabel;
                    var link = new Button
                    {
                        Content = $"→ Run: {label}",
                        Style = (Style)FindResource("GhostButton"),
                        HorizontalAlignment = HorizontalAlignment.Left,
                        Padding = new Thickness(8, 2, 8, 2),
                        Margin = new Thickness(12, 0, 0, 8),
                        Foreground = (Brush)FindResource("LinkAccentBrush")
                    };
                    link.Click += (_, _) => ExecuteFixAction(action);
                    VerifyChecksPanel.Children.Add(link);
                }
            }
        }
        catch (Exception ex)
        {
            VerifySummaryText.Text = "Could not parse verify results.";
            VerifyChecksPanel.Children.Add(new TextBlock { Text = ex.Message, TextWrapping = TextWrapping.Wrap });
        }
    }

    public void ExecuteFixAction(string? fixAction)
    {
        if (App.Session.Scripts is null)
            return;

        switch (fixAction)
        {
            case "FullSetup":
                App.Session.Scripts.RunBatchRelative(@"PlayNiteWatcher\Setup-PlayniteSteam.bat", elevated: true, keepConsoleOpen: true);
                break;
            case "RerunSetupSkipInstall":
                App.Session.Scripts.RunPowerShellRelative(@"PlayNiteWatcher\Setup-PlayniteSteam.ps1",
                    "-PickInstallFolder -WithSunshine -SkipInstall", elevated: true, keepConsoleOpen: true);
                break;
            case "UpdateLibraries":
                App.Session.Scripts.RunBatchRelative(@"PlayNiteWatcher\Update-PlayniteLibraries.bat", elevated: true, keepConsoleOpen: true);
                break;
            case "GrantPlayniteRentalAccess":
                App.Session.Scripts.RunPowerShellRelative(@"PlayNiteWatcher\Grant-PlayniteRentalAccess.ps1", "", elevated: true, keepConsoleOpen: true);
                break;
            case "ImportDesktopApps":
                App.Session.Scripts.RunBatchRelative(@"PlayNiteWatcher\Import-PlayniteDesktopApps.bat",
                    elevated: false, arguments: ImportDesktopAppsHeadlessArgs, keepConsoleOpen: true);
                break;
            case "ExportSunshine":
                App.Session.Scripts.RunPowerShellRelative(@"PlayNiteWatcher\Export-SunshineFromPlaynite.ps1", "", elevated: true, keepConsoleOpen: true);
                break;
            case "InstallWatcher":
                App.Session.Scripts.RunPowerShellRelative(@"PlayNiteWatcher\Install-PlayniteWatcher.ps1", "", elevated: true, keepConsoleOpen: true);
                break;
            case "AddAllowlist":
                AllowlistExeBox.Focus();
                break;
            case "OpenAllowlistNotepad":
                OpenAllowlistNotepad_Click(this, new RoutedEventArgs());
                break;
            case "RestartSunshine":
                if (App.Session.Services is not null)
                    _ = App.Session.Services.Restart(RepoCatalog.SunshineServiceName);
                break;
            case "StartSunshineSession":
                App.Session.Scripts.RunPowerShellRelative(@"scripts\provisioning\Start-Sunshine-InSession.ps1", "", elevated: true, keepConsoleOpen: true);
                break;
            case "OpenSetupLog":
                OpenPlayniteLog(RepoCatalog.PlayniteSetupLog);
                break;
            default:
                break;
        }
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

    private void PopulateLibrarySourceFilter()
    {
        LibrarySourceFilterCombo.Items.Clear();
        LibrarySourceFilterCombo.Items.Add("All");
        foreach (var source in new[] { "Steam", "Epic", "Manual" })
            LibrarySourceFilterCombo.Items.Add(source);
        LibrarySourceFilterCombo.SelectedIndex = 0;
    }

    private void BuildLibraryActionButtons()
    {
        LibraryActionsPanel.Children.Clear();
        LibraryGridActionsPanel.Children.Clear();

        LibraryGridActionsPanel.Children.Add(LibraryFilterBox);
        LibraryGridActionsPanel.Children.Add(LibrarySourceFilterCombo);
        AddPlainInlineActionButton(LibraryGridActionsPanel, "Refresh Library", RefreshLibraryGrid_Click, "GhostButton");
        AddPlainInlineActionButton(LibraryActionsPanel, "Add to Bypass Sync", AddSelectedToBypassSync_Click, "PrimaryButton");
    }

    private void LibraryHelp_Click(object sender, RoutedEventArgs e) =>
        MessageBox.Show(LibraryHelpText, "Playnite Library", MessageBoxButton.OK, MessageBoxImage.Information);

    private const string LibraryHelpText =
        """
        Browse all games in Playnite games.db (Steam, Epic, Manual).

        If Playnite is open, Refresh Library closes it briefly to read games.db, then you can reopen Playnite.

        Source is read-only. gameId is set for store games; nameId is resolved from the desktop allowlist for Manual entries.

        Select a row and click Add to Bypass Sync to pre-fill the Bypass tab sync-list form. You still set shortcutName there.
        """;

    private void ToggleLibraryViewer_Click(object sender, RoutedEventArgs e)
    {
        _libraryViewerVisible = !_libraryViewerVisible;
        LibraryViewerPanel.Visibility = _libraryViewerVisible ? Visibility.Visible : Visibility.Collapsed;
        ToggleLibraryViewerBtn.Content = _libraryViewerVisible ? "Hide Library" : "View Library";
        if (_libraryViewerVisible)
            LoadLibrarySummary();
    }

    private void LoadLibrarySummary()
    {
        ReloadLibraryEntries();
        LibraryCountText.Text = _allLibraryEntries.Count == 0
            ? (_libraryLoadError ?? "Library not loaded or Playnite install missing.")
            : $"{_allLibraryEntries.Count} games in Playnite library";
        ApplyLibraryFilter();
    }

    private string? _libraryLoadError;

    private void ReloadLibraryEntries()
    {
        _allLibraryEntries.Clear();
        _libraryLoadError = null;
        if (App.Session.Scripts is null)
        {
            _libraryLoadError = "Repo not configured.";
            return;
        }

        var r = App.Session.Scripts.RunPowerShellCapture(@"PlayNiteWatcher\Get-PlayniteLibraryCatalog.ps1", "");
        if (!r.Success)
        {
            _libraryLoadError = string.IsNullOrWhiteSpace(r.Message)
                ? "Failed to read Playnite library."
                : r.Message.Trim();
            return;
        }

        if (string.IsNullOrWhiteSpace(r.Message))
        {
            _libraryLoadError = "Library catalog returned no data.";
            return;
        }

        try
        {
            var json = ExtractJsonPayload(r.Message);
            if (string.IsNullOrWhiteSpace(json))
            {
                _libraryLoadError = "Library catalog returned no JSON payload.";
                return;
            }

            using var doc = JsonDocument.Parse(json);
            if (!doc.RootElement.TryGetProperty("games", out var games) || games.ValueKind != JsonValueKind.Array)
            {
                _libraryLoadError = "Library catalog JSON is missing a games array.";
                return;
            }

            foreach (var game in games.EnumerateArray())
            {
                _allLibraryEntries.Add(new PlayniteLibraryEntry
                {
                    Name = game.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "",
                    Source = game.TryGetProperty("source", out var s) ? s.GetString() ?? "" : "",
                    GameId = game.TryGetProperty("gameId", out var g) ? g.GetString() ?? "" : "",
                    NameId = game.TryGetProperty("nameId", out var id) ? id.GetString() ?? "" : "",
                    PlayniteId = game.TryGetProperty("playniteId", out var p) ? p.GetString() ?? "" : "",
                    PlayPath = game.TryGetProperty("playPath", out var pp) ? pp.GetString() ?? "" : "",
                    Exe = game.TryGetProperty("exe", out var e) ? e.GetString() ?? "" : ""
                });
            }
        }
        catch (Exception ex)
        {
            _libraryLoadError = $"Could not parse library catalog: {ex.Message}";
        }
    }

    private static string? ExtractJsonPayload(string text)
    {
        if (string.IsNullOrWhiteSpace(text))
            return null;

        var trimmed = text.Trim();
        if (trimmed.StartsWith('{') || trimmed.StartsWith('['))
            return trimmed;

        var start = trimmed.IndexOf('{');
        var end = trimmed.LastIndexOf('}');
        if (start < 0 || end <= start)
            return null;

        return trimmed[start..(end + 1)];
    }

    private void ApplyLibraryFilter()
    {
        var query = (LibraryFilterBox.Text ?? "").Trim();
        var sourceFilter = LibrarySourceFilterCombo.SelectedItem as string ?? "All";

        IEnumerable<PlayniteLibraryEntry> filtered = _allLibraryEntries;
        if (!string.Equals(sourceFilter, "All", StringComparison.OrdinalIgnoreCase))
            filtered = filtered.Where(e => string.Equals(e.Source, sourceFilter, StringComparison.OrdinalIgnoreCase));

        if (!string.IsNullOrWhiteSpace(query))
        {
            filtered = filtered.Where(e =>
                e.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.GameId.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.NameId.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.Source.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.Exe.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                e.PlayPath.Contains(query, StringComparison.OrdinalIgnoreCase));
        }

        var list = filtered.ToList();
        LibraryGrid.ItemsSource = new ObservableCollection<PlayniteLibraryEntry>(list);
        LibraryGridFooter.Text = list.Count == _allLibraryEntries.Count
            ? $"{_allLibraryEntries.Count} games"
            : $"Showing {list.Count} of {_allLibraryEntries.Count} games";
    }

    private void LibraryFilter_Changed(object sender, RoutedEventArgs e) => ApplyLibraryFilter();

    private void RefreshLibraryGrid_Click(object sender, RoutedEventArgs e) => LoadLibrarySummary();

    private void AddSelectedToBypassSync_Click(object sender, RoutedEventArgs e)
    {
        if (LibraryGrid.ItemsSource is not IEnumerable<PlayniteLibraryEntry> visible)
        {
            MessageBox.Show("Open the library viewer and refresh first.", "Playnite Library");
            return;
        }

        var selected = visible.Where(entry => entry.IsSelected).ToList();
        if (selected.Count == 0)
        {
            var current = LibraryGrid.SelectedItem as PlayniteLibraryEntry;
            if (current is not null)
                selected = [current];
        }

        if (selected.Count != 1)
        {
            MessageBox.Show("Select exactly one library row to add to bypass sync.", "Playnite Library");
            return;
        }

        var game = selected[0];
        var draft = BypassPage.PendingDraft;
        draft.Title = game.Name;
        draft.GameId = game.GameId;
        draft.NameId = game.NameId;
        draft.SuggestedShortcutName = game.Name;

        if (Application.Current.MainWindow is MainWindow mw)
            mw.NavigateTo(new BypassPage());

        MessageBox.Show(
            $"Pre-filled Bypass sync list for '{game.Name}'. Set Shortcut Name on the Bypass tab, then Add / Update Entry.",
            "Playnite Library", MessageBoxButton.OK, MessageBoxImage.Information);
    }
}
