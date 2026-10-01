using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Microsoft.Win32;
using NextGPU.Core;
using NextGPU.Core.Models;

namespace NextGPU.App.Pages;

public partial class NextGPUServicePage : Page
{
    private readonly ObservableCollection<LaunchCompanionEntry> _companions = [];

    private static string ProgramDataNextGpu =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "nextGPU");

    private static string CompanionsConfigPath => Path.Combine(ProgramDataNextGpu, "launch-companions.json");

    private const string NextGpuServiceName = "NextGPUService";
    private const string NextGpuServiceInstallRoot = @"C:\Program Files\NextGPU\Service";
    private const string NextGpuServiceBinaryName = "NextGPUService.exe";
    private const string NextGpuServiceInstallScript = @"apps\NextGPU\NextGPU.Service\Install-NextGPUService.ps1";
    private const string NextGpuServiceUninstallScript = @"apps\NextGPU\NextGPU.Service\Uninstall-NextGPUService.ps1";
    private const string NextGpuServiceSmokeTestScript = @"scripts\runtime\Test-NextGPUService.ps1";
    private const string NextGpuPipeName = "NextGPUControl";
    private const string UpdateCompanionsScript = @"scripts\runtime\Update-LaunchCompanions.ps1";
    private const string CompanionsStatusMarker = "@@LAUNCH_COMPANIONS_STATUS@@";

    public NextGPUServicePage()
    {
        InitializeComponent();
        Loaded += (_, _) => OnLoaded();
    }

    private void OnLoaded()
    {
        CompanionsGrid.ItemsSource = _companions;
        BuildServiceUi();
        BuildCompanionsButtons();
        BuildLogsButtons();
        _ = ReloadCompanionsAsync();
    }

    // -----------------------------------------------------------------------
    // Service
    // -----------------------------------------------------------------------

    private void BuildServiceUi()
    {
        ServiceActionsPanel.Children.Clear();
        _ = RefreshServiceAsync(showProgress: false);
    }

    private void RefreshService_Click(object sender, RoutedEventArgs e) =>
        _ = RefreshServiceAsync(showProgress: true);

    private async Task RefreshServiceAsync(bool showProgress)
    {
        if (showProgress)
            SetServiceProgress("Checking service state…");

        try
        {
            var snapshot = await Task.Run(CollectServiceSnapshot);
            RenderServiceSnapshot(snapshot);
        }
        catch (Exception ex)
        {
            ServiceStateText.Text = $"Error: {ex.Message}";
            ServiceStateText.Foreground = (Brush)FindResource("ErrBrush");
            ServicePathText.Text = "";
        }
        finally
        {
            HideServiceProgress();
        }
    }

    private sealed record ServiceSnapshot(
        bool BinaryPresent,
        string BinaryPath,
        long? BinarySizeBytes,
        DateTime? BinaryLastWrite,
        ServiceRunState ServiceState,
        string? StartupType,
        string? ServiceAccount,
        bool PipeResponsive,
        string? PipeDetail);

    private static ServiceSnapshot CollectServiceSnapshot()
    {
        var installedPath = Path.Combine(NextGpuServiceInstallRoot, NextGpuServiceBinaryName);
        var publishedPath = ResolvePublishedServiceBinary();

        var primaryPath = File.Exists(installedPath) ? installedPath
            : File.Exists(publishedPath) ? publishedPath
            : null;

        var binaryPresent = primaryPath is not null;
        long? size = null;
        DateTime? lastWrite = null;
        if (primaryPath is not null)
        {
            var fi = new FileInfo(primaryPath);
            size = fi.Length;
            lastWrite = fi.LastWriteTime;
        }

        var state = TryReadServiceState(NextGpuServiceName, out var startupType, out var serviceAccount);
        var (pipeOk, pipeDetail) = state == ServiceRunState.Running
            ? TryPingService()
            : (false, "Service is not running");

        return new ServiceSnapshot(
            BinaryPresent: binaryPresent,
            BinaryPath: primaryPath ?? $"Expected at: {installedPath}",
            BinarySizeBytes: size,
            BinaryLastWrite: lastWrite,
            ServiceState: state,
            StartupType: startupType,
            ServiceAccount: serviceAccount,
            PipeResponsive: pipeOk,
            PipeDetail: pipeDetail);
    }

    private static string? ResolvePublishedServiceBinary()
    {
        var repo = App.Session?.RepoRoot;
        if (string.IsNullOrWhiteSpace(repo))
            return null;
        var path = Path.Combine(repo, "apps", "NextGPU", "publish", "Service", NextGpuServiceBinaryName);
        return File.Exists(path) ? path : null;
    }

    private static ServiceRunState TryReadServiceState(string serviceName, out string? startupType, out string? account)
    {
        startupType = null;
        account = null;
        try
        {
            var psi = new ProcessStartInfo("sc.exe", $"query \"{serviceName}\"")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            if (p is null) return ServiceRunState.Unknown;
            var stdout = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            if (stdout.Contains("does not exist", StringComparison.OrdinalIgnoreCase) ||
                stdout.Contains("1060", StringComparison.OrdinalIgnoreCase))
                return ServiceRunState.NotInstalled;
            if (stdout.Contains("RUNNING", StringComparison.OrdinalIgnoreCase))
            {
                ParseScQuery(stdout, out startupType, out account);
                return ServiceRunState.Running;
            }
            if (stdout.Contains("STOPPED", StringComparison.OrdinalIgnoreCase))
            {
                ParseScQuery(stdout, out startupType, out account);
                return ServiceRunState.Stopped;
            }
            ParseScQuery(stdout, out startupType, out account);
            return ServiceRunState.Unknown;
        }
        catch
        {
            return ServiceRunState.Unknown;
        }
    }

    private static void ParseScQuery(string output, out string? startupType, out string? account)
    {
        startupType = null;
        account = null;
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.StartsWith("START_TYPE", StringComparison.OrdinalIgnoreCase))
            {
                var parts = line.Split(':', 2);
                if (parts.Length == 2) startupType = parts[1].Trim();
            }
            else if (line.StartsWith("SERVICE_START_NAME", StringComparison.OrdinalIgnoreCase))
            {
                var parts = line.Split(':', 2);
                if (parts.Length == 2) account = parts[1].Trim();
            }
        }
    }

    private static (bool Ok, string Detail) TryPingService()
    {
        try
        {
            using var pipe = new System.IO.Pipes.NamedPipeClientStream(
                ".", NextGpuPipeName, System.IO.Pipes.PipeDirection.InOut, System.IO.Pipes.PipeOptions.Asynchronous);
            pipe.Connect(2000);

            var request = "{\"version\":1,\"op\":\"ping\"}";
            var reqBytes = Encoding.UTF8.GetBytes(request);
            var lenBytes = BitConverter.GetBytes(reqBytes.Length);
            pipe.Write(lenBytes, 0, 4);
            pipe.Write(reqBytes, 0, reqBytes.Length);
            pipe.WaitForPipeDrain();

            var lenBuf = new byte[4];
            var read = pipe.Read(lenBuf, 0, 4);
            if (read < 4) return (false, "Pipe responded with short header");
            var len = BitConverter.ToUInt32(lenBuf, 0);
            if (len == 0 || len > 64 * 1024) return (false, $"Pipe returned implausible length {len}");

            var respBuf = new byte[len];
            var total = 0;
            while (total < len)
            {
                var r = pipe.Read(respBuf, total, (int)len - total);
                if (r == 0) break;
                total += r;
            }
            var resp = Encoding.UTF8.GetString(respBuf, 0, total);
            return resp.Contains("\"ok\":true", StringComparison.OrdinalIgnoreCase)
                ? (true, "ok=true")
                : (false, $"unexpected response: {resp}");
        }
        catch (TimeoutException)
        {
            return (false, "Pipe connect timed out (2s)");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    private void RenderServiceSnapshot(ServiceSnapshot s)
    {
        var (label, brushKey) = s.ServiceState switch
        {
            ServiceRunState.Running => (s.PipeResponsive
                    ? "Running — pipe responsive"
                    : "Running — pipe NOT responsive",
                s.PipeResponsive ? "OkBrush" : "WarnBrush"),
            ServiceRunState.Stopped => ("Stopped", "WarnBrush"),
            ServiceRunState.NotInstalled => ("Not installed", "ErrBrush"),
            _ => ("Unknown", "MutedBrush")
        };

        var extra = s.ServiceState == ServiceRunState.Running && !s.PipeResponsive
            ? $" ({s.PipeDetail})"
            : "";

        ServiceStateText.Text = $"Status: {label}{extra}";
        ServiceStateText.Foreground = (Brush)FindResource(brushKey);

        var lines = new List<string> { s.BinaryPath };
        if (s.BinarySizeBytes is long bytes)
        {
            var sizeKb = bytes / 1024.0;
            lines.Add($"size: {sizeKb:F1} KB  ·  updated: {s.BinaryLastWrite:yyyy-MM-dd HH:mm}");
        }
        if (!string.IsNullOrWhiteSpace(s.StartupType))
            lines.Add($"start type: {s.StartupType}");
        if (!string.IsNullOrWhiteSpace(s.ServiceAccount))
            lines.Add($"account: {s.ServiceAccount}");
        ServicePathText.Text = string.Join(Environment.NewLine, lines);

        ServiceActionsPanel.Children.Clear();

        if (s.ServiceState == ServiceRunState.NotInstalled)
        {
            AddServiceActionButton("Install NextGPUService", "Install / register NextGPUService as a Windows Service (auto start).", NextGpuServiceInstallScript, "PrimaryButton", isPowerShell: true);
        }
        else
        {
            if (s.ServiceState == ServiceRunState.Stopped)
                AddServiceActionButton("Start Service", "Start the NextGPUService Windows Service.", "");

            if (s.ServiceState == ServiceRunState.Running)
            {
                AddServiceActionButton("Stop Service", "Stop the NextGPUService Windows Service.", "");
                AddServiceActionButton("Restart Service", "Stop and then start the NextGPUService Windows Service.", "");
                AddServiceActionButton("Smoke Test", "Send a ping to the NextGPUService named pipe to verify it responds.", NextGpuServiceSmokeTestScript, "SecondaryButton", isPowerShell: true, returnsImmediately: true);
            }

            AddServiceActionButton("Re-register (repair)", "Re-run Install-NextGPUService.ps1 to refresh the service registration.", NextGpuServiceInstallScript, "SecondaryButton", isPowerShell: true);
            AddServiceActionButton("Uninstall", "Stop and remove the NextGPUService Windows Service.", NextGpuServiceUninstallScript, "SecondaryButton", isPowerShell: true, confirm: "Uninstall NextGPUService? Active Moonlight sessions will fail to launch games until reinstall.");
        }

        if (!s.BinaryPresent)
        {
            AddServiceActionButton("Build Service", "Run apps\\NextGPU\\build-publish.bat to publish NextGPUService.exe.", "apps\\NextGPU\\build-publish.bat", "PrimaryButton", isPowerShell: false);
        }
    }

    private void AddServiceActionButton(
        string label,
        string helpText,
        string scriptRelativePath,
        string styleKey = "SecondaryButton",
        bool isPowerShell = true,
        bool returnsImmediately = false,
        string? confirm = null)
    {
        var btn = new Button
        {
            Content = label,
            Style = (Style)FindResource(styleKey),
            Padding = new Thickness(styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10,
                styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10),
            Margin = new Thickness(0, 0, 8, 8),
            ToolTip = helpText
        };

        if (label is "Start Service" or "Stop Service" or "Restart Service")
        {
            btn.Click += (_, _) => _ = RunServiceControlAsync(label);
        }
        else if (isPowerShell)
        {
            btn.Click += (_, _) =>
            {
                if (App.Session.Scripts is null)
                {
                    MessageBox.Show("Repo not configured.", "NextGPU");
                    return;
                }
                if (!string.IsNullOrWhiteSpace(confirm) &&
                    MessageBox.Show(confirm, "NextGPU", MessageBoxButton.YesNo, MessageBoxImage.Warning) != MessageBoxResult.Yes)
                    return;
                var r = App.Session.Scripts.RunPowerShellRelative(scriptRelativePath, "", elevated: true, keepConsoleOpen: true);
                MessageBox.Show(r.Message, "NextGPU Service", MessageBoxButton.OK,
                    r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
                if (returnsImmediately)
                    _ = RefreshServiceAsync(showProgress: false);
            };
        }
        else
        {
            btn.Click += (_, _) =>
            {
                if (App.Session.Scripts is null)
                {
                    MessageBox.Show("Repo not configured.", "NextGPU");
                    return;
                }
                var r = App.Session.Scripts.RunBatchRelative(scriptRelativePath, elevated: true, keepConsoleOpen: true);
                MessageBox.Show(r.Message, "NextGPU Service", MessageBoxButton.OK,
                    r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
            };
        }

        ServiceActionsPanel.Children.Add(btn);
    }

    private async Task RunServiceControlAsync(string action)
    {
        if (App.Session.Services is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }
        SetServiceProgress($"{action}…");
        try
        {
            (bool Success, string Message) r = action switch
            {
                "Start Service" => await Task.Run(() => App.Session.Services.Start(NextGpuServiceName, elevated: true)),
                "Stop Service" => await Task.Run(() => App.Session.Services.Stop(NextGpuServiceName, elevated: true)),
                "Restart Service" => await Task.Run(() => App.Session.Services.Restart(NextGpuServiceName, elevated: true)),
                _ => (false, $"Unknown action: {action}")
            };
            if (!r.Success)
                MessageBox.Show(r.Message, "NextGPU Service", MessageBoxButton.OK, MessageBoxImage.Warning);
            await Task.Delay(800);
        }
        finally
        {
            await RefreshServiceAsync(showProgress: false);
        }
    }

    private void SetServiceProgress(string message)
    {
        ServiceProgressText.Text = message;
        ServiceProgressPanel.Visibility = Visibility.Visible;
        RefreshServiceBtn.IsEnabled = false;
        SetPanelButtonsEnabled(ServiceActionsPanel, false);
    }

    private void HideServiceProgress()
    {
        ServiceProgressPanel.Visibility = Visibility.Collapsed;
        RefreshServiceBtn.IsEnabled = true;
        SetPanelButtonsEnabled(ServiceActionsPanel, true);
    }

    private static void SetPanelButtonsEnabled(Panel panel, bool enabled)
    {
        foreach (var child in panel.Children)
        {
            if (child is Button b) b.IsEnabled = enabled;
        }
    }

    // -----------------------------------------------------------------------
    // Launch Companions
    // -----------------------------------------------------------------------

    private void BuildCompanionsButtons()
    {
        CompanionsEditActionsPanel.Children.Clear();
        AddInlineButton(CompanionsEditActionsPanel, "Add Row", AddCompanion_Click, "SecondaryButton",
            "Add an empty row; type the main app exe and companion exe file names.");
        AddInlineButton(CompanionsEditActionsPanel, "Remove Selected", RemoveSelectedCompanions_Click, "SecondaryButton",
            "Remove checked rows (Save to apply).");
        AddInlineButton(CompanionsEditActionsPanel, "Browse Path…", BrowseCompanionPath_Click, "GhostButton",
            "Pick the companion exe for the checked (or current) row; fills companion exe, path and search folder.");

        CompanionsActionsPanel.Children.Clear();
        AddInlineButton(CompanionsActionsPanel, "Find Paths with Everything & Seed", SeedCompanions_Click, "PrimaryButton",
            "Save the grid, then resolve every companion path with Everything (folder walk if Everything is unavailable) and write launch-companions.json.");
        AddInlineButton(CompanionsActionsPanel, "Save", SaveCompanions_Click, "SecondaryButton",
            "Write launch-companions.json with the admin-only ACL NextGPUService requires.");
        AddInlineButton(CompanionsActionsPanel, "Reload", (_, _) => _ = ReloadCompanionsAsync(), "GhostButton",
            "Re-read launch-companions.json and refresh file / running status.");
        AddInlineButton(CompanionsActionsPanel, "Open JSON", OpenCompanionsJson_Click, "GhostButton",
            "Open launch-companions.json in Notepad (read-only view; edit through this page so the ACL stays admin-only).");
    }

    private static void AddInlineButton(Panel panel, string label, RoutedEventHandler onClick, string styleKey, string tooltip)
    {
        var btn = new Button
        {
            Content = label,
            Style = (Style)Application.Current.FindResource(styleKey),
            Padding = new Thickness(styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10,
                styleKey == "GhostButton" ? 10 : 14, styleKey == "GhostButton" ? 6 : 10),
            Margin = new Thickness(0, 0, 8, 8),
            ToolTip = tooltip
        };
        btn.Click += onClick;
        panel.Children.Add(btn);
    }

    private void AddCompanion_Click(object sender, RoutedEventArgs e)
    {
        var entry = new LaunchCompanionEntry { Status = "New (not saved)" };
        _companions.Add(entry);
        CompanionsGrid.SelectedItem = entry;
        CompanionsGrid.ScrollIntoView(entry);
        UpdateCompanionsCount();
    }

    private void RemoveSelectedCompanions_Click(object sender, RoutedEventArgs e)
    {
        CompanionsGrid.CommitEdit(DataGridEditingUnit.Row, true);
        var selected = _companions.Where(c => c.IsSelected).ToList();
        if (selected.Count == 0)
        {
            MessageBox.Show("Check one or more rows first.", "Launch Companions");
            return;
        }
        foreach (var row in selected)
            _companions.Remove(row);
        UpdateCompanionsCount();
    }

    private void BrowseCompanionPath_Click(object sender, RoutedEventArgs e)
    {
        CompanionsGrid.CommitEdit(DataGridEditingUnit.Row, true);
        var target = _companions.FirstOrDefault(c => c.IsSelected) ?? CompanionsGrid.SelectedItem as LaunchCompanionEntry;
        if (target is null)
        {
            MessageBox.Show("Check or select a row first (use Add Row for a new companion).", "Launch Companions");
            return;
        }

        var dlg = new OpenFileDialog
        {
            Title = $"Companion exe for {(string.IsNullOrWhiteSpace(target.MainExe) ? "main app" : target.MainExe)}",
            Filter = "Executables (*.exe)|*.exe",
            CheckFileExists = true
        };
        var startDir = !string.IsNullOrWhiteSpace(target.Exe) ? Path.GetDirectoryName(target.Exe) : target.SearchDir;
        if (!string.IsNullOrWhiteSpace(startDir) && Directory.Exists(startDir))
            dlg.InitialDirectory = startDir;
        if (dlg.ShowDialog() != true)
            return;

        target.Exe = dlg.FileName;
        target.ExeName = Path.GetFileName(dlg.FileName);
        if (string.IsNullOrWhiteSpace(target.SearchDir))
            target.SearchDir = Path.GetDirectoryName(dlg.FileName) ?? "";
        target.Status = "Picked (not saved)";
    }

    private async void SaveCompanions_Click(object sender, RoutedEventArgs e)
    {
        if (!TryWriteGridToTempJson(out var tempJson))
            return;
        await RunCompanionsScriptAsync("Saving launch-companions.json…", $"-SaveJson \"{tempJson}\"", tempJson, showOutput: false);
    }

    private async void SeedCompanions_Click(object sender, RoutedEventArgs e)
    {
        if (!TryWriteGridToTempJson(out var tempJson))
            return;
        await RunCompanionsScriptAsync(
            "Finding companion paths with Everything… (first run may install Everything and wait for indexing)",
            $"-SaveJson \"{tempJson}\" -Seed", tempJson, showOutput: true);
    }

    private async Task RunCompanionsScriptAsync(string progress, string args, string? tempFile, bool showOutput)
    {
        if (App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU");
            return;
        }

        SetCompanionsBusy(progress);
        (bool Success, string Message) r;
        try
        {
            var scripts = App.Session.Scripts;
            r = await Task.Run(() => scripts.RunPowerShellCapture(UpdateCompanionsScript, args));
        }
        finally
        {
            if (tempFile is not null)
            {
                try { File.Delete(tempFile); } catch { /* temp cleanup is best-effort */ }
            }
            ClearCompanionsBusy();
        }

        if (!r.Success)
            MessageBox.Show(r.Message, "Launch Companions", MessageBoxButton.OK, MessageBoxImage.Warning);
        else if (showOutput)
            MessageBox.Show(TailLines(r.Message, 25), "Launch Companions", MessageBoxButton.OK, MessageBoxImage.Information);

        await ReloadCompanionsAsync();
    }

    private bool TryWriteGridToTempJson(out string tempJson)
    {
        tempJson = "";
        CompanionsGrid.CommitEdit(DataGridEditingUnit.Row, true);

        var invalid = new List<string>();
        var items = new List<Dictionary<string, object>>();
        for (var i = 0; i < _companions.Count; i++)
        {
            var c = _companions[i];
            var main = c.MainExe.Trim();
            var exeName = c.ExeName.Trim();
            var exe = c.Exe.Trim();
            if (string.IsNullOrEmpty(exeName) && !string.IsNullOrEmpty(exe))
                exeName = Path.GetFileName(exe);

            if (!IsExeFileName(main))
                invalid.Add($"Row {i + 1}: main app exe '{main}' must be a file name ending in .exe");
            if (!IsExeFileName(exeName))
                invalid.Add($"Row {i + 1}: companion exe '{exeName}' must be a file name ending in .exe");
            if (!string.IsNullOrEmpty(exe) && !Path.IsPathRooted(exe))
                invalid.Add($"Row {i + 1}: resolved path must be absolute (or empty)");

            items.Add(new Dictionary<string, object>
            {
                ["mainExe"] = main,
                ["exeName"] = exeName,
                ["exe"] = exe,
                ["searchDir"] = c.SearchDir.Trim(),
                ["delayMs"] = c.DelayMs
            });
        }

        if (invalid.Count > 0)
        {
            MessageBox.Show(string.Join(Environment.NewLine, invalid), "Launch Companions", MessageBoxButton.OK, MessageBoxImage.Warning);
            return false;
        }

        tempJson = Path.Combine(Path.GetTempPath(), $"nextgpu-launch-companions-{Guid.NewGuid():N}.json");
        File.WriteAllText(tempJson, JsonSerializer.Serialize(items), new UTF8Encoding(false));
        return true;
    }

    private static bool IsExeFileName(string name) =>
        !string.IsNullOrWhiteSpace(name) &&
        name.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) &&
        name.Length > 4 &&
        name.IndexOfAny(['\\', '/', ':', '*', '?', '"', '<', '>', '|']) < 0;

    private async Task ReloadCompanionsAsync()
    {
        if (App.Session.Scripts is null)
        {
            CompanionsCountText.Text = "Repo not configured.";
            return;
        }

        SetCompanionsBusy("Reading launch-companions.json…");
        try
        {
            var scripts = App.Session.Scripts;
            var r = await Task.Run(() => scripts.RunPowerShellCapture(UpdateCompanionsScript, "-StatusOnly"));
            if (!r.Success)
            {
                CompanionsCountText.Text = $"Could not read companions: {TailLines(r.Message, 3)}";
                return;
            }

            _companions.Clear();
            foreach (var row in ParseStatusRows(r.Message))
                _companions.Add(row);
            UpdateCompanionsCount();
        }
        catch (Exception ex)
        {
            CompanionsCountText.Text = $"Could not read companions: {ex.Message}";
        }
        finally
        {
            ClearCompanionsBusy();
        }
    }

    private static List<LaunchCompanionEntry> ParseStatusRows(string output)
    {
        var rows = new List<LaunchCompanionEntry>();
        var line = output.Split('\n')
            .Select(l => l.Trim())
            .LastOrDefault(l => l.StartsWith(CompanionsStatusMarker, StringComparison.Ordinal));
        if (line is null)
            return rows;

        using var doc = JsonDocument.Parse(line[CompanionsStatusMarker.Length..]);
        var items = doc.RootElement.ValueKind == JsonValueKind.Array
            ? doc.RootElement.EnumerateArray().ToList()
            : [doc.RootElement];

        foreach (var item in items)
        {
            if (item.ValueKind != JsonValueKind.Object)
                continue;
            var exe = GetString(item, "exe");
            var exists = item.TryGetProperty("exists", out var ex) && ex.ValueKind == JsonValueKind.True;
            var running = GetStringList(item, "running");

            string status;
            if (string.IsNullOrWhiteSpace(exe))
                status = "Path not resolved";
            else if (!exists)
                status = "File missing";
            else
                status = "Found";
            if (running.Count > 0)
                status += $" · running ({string.Join("; ", running)})";

            rows.Add(new LaunchCompanionEntry
            {
                MainExe = GetString(item, "mainExe"),
                ExeName = GetString(item, "exeName"),
                Exe = exe,
                SearchDir = GetString(item, "searchDir"),
                DelayMs = item.TryGetProperty("delayMs", out var d) && d.TryGetInt32(out var delay) ? delay : 0,
                Status = status
            });
        }
        return rows;
    }

    private static string GetString(JsonElement item, string name) =>
        item.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    private static List<string> GetStringList(JsonElement item, string name)
    {
        var list = new List<string>();
        if (!item.TryGetProperty(name, out var v))
            return list;
        if (v.ValueKind == JsonValueKind.String)
            list.Add(v.GetString() ?? "");
        else if (v.ValueKind == JsonValueKind.Array)
            list.AddRange(v.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.String).Select(x => x.GetString() ?? ""));
        return list.Where(s => !string.IsNullOrWhiteSpace(s)).ToList();
    }

    private static string TailLines(string text, int count)
    {
        var lines = text.Split('\n').Select(l => l.TrimEnd('\r')).Where(l => !string.IsNullOrWhiteSpace(l)).ToList();
        return string.Join(Environment.NewLine, lines.Skip(Math.Max(0, lines.Count - count)));
    }

    private void UpdateCompanionsCount()
    {
        var mains = _companions.Select(c => c.MainExe.Trim()).Where(m => m.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase).Count();
        CompanionsCountText.Text = _companions.Count == 0
            ? $"No companions configured ({CompanionsConfigPath} missing or empty)."
            : $"{_companions.Count} companion(s) for {mains} main app(s) — {CompanionsConfigPath}";
    }

    private void SetCompanionsBusy(string message)
    {
        CompanionsProgressText.Text = message;
        CompanionsProgressPanel.Visibility = Visibility.Visible;
        CompanionsGrid.IsEnabled = false;
        SetPanelButtonsEnabled(CompanionsActionsPanel, false);
        SetPanelButtonsEnabled(CompanionsEditActionsPanel, false);
    }

    private void ClearCompanionsBusy()
    {
        CompanionsProgressPanel.Visibility = Visibility.Collapsed;
        CompanionsGrid.IsEnabled = true;
        SetPanelButtonsEnabled(CompanionsActionsPanel, true);
        SetPanelButtonsEnabled(CompanionsEditActionsPanel, true);
    }

    private void OpenCompanionsJson_Click(object sender, RoutedEventArgs e)
    {
        if (!File.Exists(CompanionsConfigPath))
        {
            MessageBox.Show($"{CompanionsConfigPath} does not exist yet. Add rows and Save (or Seed) first.", "Launch Companions");
            return;
        }
        OpenInNotepad(CompanionsConfigPath);
    }

    // -----------------------------------------------------------------------
    // Logs
    // -----------------------------------------------------------------------

    private void BuildLogsButtons()
    {
        LogsPanel.Children.Clear();

        var serviceLog = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "NextGPU", "Logs", "NextGPUService.log");

        AddOpenLogButton(LogsPanel, "Open NextGPUService Log", serviceLog,
            "Service log at C:\\ProgramData\\NextGPU\\Logs\\NextGPUService.log (launch-elevated and companion start / skip lines).");
        AddOpenLogButton(LogsPanel, "Open Launch Companions Log",
            Path.Combine(ProgramDataNextGpu, "logs", "launch-companions.log"),
            "Save / Seed runs of Update-LaunchCompanions.ps1 (which paths Everything found).");
        AddOpenLogButton(LogsPanel, "Open Garena Companion Log",
            Path.Combine(ProgramDataNextGpu, "logs", "garena-launch-companion.log"),
            "Register-GarenaLaunchCompanion.ps1 runs (legacy task cleanup, helper path).");
        ActionPageTools.AddOpenExplorerButton(LogsPanel, "Open ProgramData\\nextGPU",
            () => EnsureDirectory(ProgramDataNextGpu),
            helpText: "Opens C:\\ProgramData\\nextGPU (launch-companions.json, logs).");
    }

    private static void AddOpenLogButton(Panel panel, string label, string logPath, string helpText)
    {
        var btn = ActionPageTools.MakeButton(label, helpText, (_, _) =>
        {
            var dir = Path.GetDirectoryName(logPath);
            if (!string.IsNullOrWhiteSpace(dir))
                Directory.CreateDirectory(dir);
            if (!File.Exists(logPath))
                File.WriteAllText(logPath, "");
            OpenInNotepad(logPath);
        });
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn, helpText);
        else
            panel.Children.Add(btn);
    }

    private static void OpenInNotepad(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo("notepad.exe", $"\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "NextGPU");
        }
    }

    private static string EnsureDirectory(string path)
    {
        if (!Directory.Exists(path))
            Directory.CreateDirectory(path);
        return path;
    }
}
