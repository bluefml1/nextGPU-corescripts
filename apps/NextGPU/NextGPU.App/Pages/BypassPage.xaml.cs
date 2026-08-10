using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Microsoft.Win32;
using NextGPU.App;
using NextGPU.Core;
using NextGPU.Core.Models;

namespace NextGPU.App.Pages;

public partial class BypassPage : Page
{
    private readonly List<PlayniteAllowlistEntry> _allAllowlistEntries = [];
    private readonly List<SessionFolderRuleEntry> _allRules = [];
    private readonly ObservableCollection<SessionFolderRuleEntry> _rulesGridItems = [];

    private static string ProgramDataNextGpu =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "nextGPU");

    private static string RulesConfigPath => Path.Combine(ProgramDataNextGpu, "session-folder-rules.json");

    private static string SessionTemplatesPath => Path.Combine(ProgramDataNextGpu, "session-templates");

    private const string NextGpuServiceName = "NextGPUService";
    private const string NextGpuServiceInstallRoot = @"C:\Program Files\NextGPU\Service";
    private const string NextGpuServiceBinaryName = "NextGPUService.exe";
    private const string NextGpuServiceInstallScript = @"apps\NextGPU\NextGPU.Service\Install-NextGPUService.ps1";
    private const string NextGpuServiceUninstallScript = @"apps\NextGPU\NextGPU.Service\Uninstall-NextGPUService.ps1";
    private const string NextGpuServiceSmokeTestScript = @"scripts\runtime\Test-NextGPUService.ps1";
    private const string NextGpuPipeName = "NextGPUControl";

    public BypassPage()
    {
        InitializeComponent();
        Loaded += (_, _) => OnLoaded();
    }

    private void OnLoaded()
    {
        RulesGrid.ItemsSource = _rulesGridItems;
        BuildAdminSetupButtons();
        BuildSetupButtons();
        BuildServiceUi();
        BuildAllowlistActionButtons();
        BuildRulesActionButtons();
        BuildCleanSessionButtons();
        BuildToolsButtons();
        LoadAllowlistSummary();
        LoadRulesSummary();
    }

    // -----------------------------------------------------------------------
    // Setup — NextGPU-Admin
    // -----------------------------------------------------------------------

    private void BuildAdminSetupButtons()
    {
        AdminSetupPanel.Children.Clear();
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

        bool userExists = false;
        bool userIsAdmin = false;
        bool credExists = false;

        if (App.Session.Scripts is not null)
        {
            var statusR = App.Session.Scripts.RunPowerShellCapture(
                @"scripts\provisioning\Store-NextGpuAdminCredential.ps1",
                @"-StatusOnly");

            if (statusR.Success && TryParseAdminSetupStatus(statusR.Message, out userExists, out userIsAdmin, out credExists))
            {
            }
            else if (statusR.Success)
            {
                credExists = statusR.Message.Contains("\"CredExists\":true", StringComparison.Ordinal);
            }
        }

        string userStatusText;
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

        credStatusValue.Text = credExists ? "Stored" : "Not Stored";
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

                var r = App.Session.Scripts.RunPowerShellCapture(
                    @"scripts\provisioning\Store-NextGpuAdminCredential.ps1",
                    $"-EncryptedPassword \"{encrypted}\" -CreateUser");

                var verifyR = App.Session.Scripts.RunPowerShellCapture(
                    @"scripts\provisioning\Store-NextGpuAdminCredential.ps1",
                    @"-StatusOnly");
                var userReady = false;
                var adminReady = false;
                var credStored = false;
                var verified = verifyR.Success
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

    // -----------------------------------------------------------------------
    // Setup — Steam ACL
    // -----------------------------------------------------------------------

    private void BuildSetupButtons()
    {
        SetupPanel.Children.Clear();

        ActionPageTools.AddPrimaryPowerShellButton(SetupPanel, "Grant ACL NextGPU-Admin for Steam",
            @"scripts\runtime\Grant-SteamLibraryAdminAcl.ps1", keepConsoleOpen: true,
            helpText: "Full apply: Admin Full Control on each game (children inherit); DENY delete on the game folder only (cannot remove install dir); deny create ON common only; Modify downloading/temp. Remove Admin from NextGPURestricted.");

        ActionPageTools.AddPowerShellButton(SetupPanel, "Update ACL for new games",
            @"scripts\runtime\Grant-SteamLibraryAdminAcl.ps1", keepConsoleOpen: true,
            helpText: "After imaging or installing a new Steam title under steamapps\\common, re-run grant so that folder gets Full Control (common create-deny stays on common only). Safe to run anytime (idempotent re-scan of all current games).");

        ActionPageTools.AddPowerShellButton(SetupPanel, "Steam ACL Status",
            @"scripts\runtime\Grant-SteamLibraryAdminAcl.ps1", "-StatusOnly", keepConsoleOpen: true,
            helpText: "Show resolved Steam library roots and current NextGPU-Admin ACL status without making changes.");

        ActionPageTools.AddPowerShellButton(SetupPanel, "Revoke ACL NextGPU-Admin for Steam",
            @"scripts\runtime\Grant-SteamLibraryAdminAcl.ps1", "-Revoke", keepConsoleOpen: true,
            helpText: "Remove NextGPU-Admin Steam library ACEs (deny/grant) from all resolved libraries. Does not change Users or NextGPURestricted.");
    }

    // -----------------------------------------------------------------------
    // Setup — NextGPUService
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
        SetServiceButtonsEnabled(false);
    }

    private void HideServiceProgress()
    {
        ServiceProgressPanel.Visibility = Visibility.Collapsed;
        RefreshServiceBtn.IsEnabled = true;
        SetServiceButtonsEnabled(true);
    }

    private void SetServiceButtonsEnabled(bool enabled)
    {
        foreach (var child in ServiceActionsPanel.Children)
        {
            if (child is Button b) b.IsEnabled = enabled;
        }
    }

    // -----------------------------------------------------------------------
    // Allowlist
    // -----------------------------------------------------------------------

    private void BuildAllowlistActionButtons()
    {
        AllowlistActionsPanel.Children.Clear();
        AllowlistGridActionsPanel.Children.Clear();

        AllowlistGridActionsPanel.Children.Add(AllowlistFilterBox);
        AddPlainInlineActionButton(AllowlistGridActionsPanel, "Refresh", RefreshAllowlistGrid_Click, "GhostButton");
        AddPlainInlineActionButton(AllowlistGridActionsPanel, "Delete Selected", DeleteSelectedAllowlist_Click, "SecondaryButton");
        AddPlainInlineActionButton(AllowlistGridActionsPanel, "Open in Notepad", OpenAllowlistNotepad_Click, "GhostButton");

        AddConfirmedPowerShellButton(AllowlistActionsPanel, "Export Admin launches",
            @"PlayNiteWatcher\Export-SunshineFromPlaynite.ps1", "",
            "This exports to Sunshine, installs PlayNiteWatcher, and restarts Sunshine. Active Moonlight sessions may end. Continue?",
            "Writes Playnite games and allowlisted desktop apps into Sunshine apps.json with @ADMIN markers for runAsAdmin entries.");
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

    private string GetAllowlistPath()
    {
        var repo = App.Session.RepoRoot;
        return string.IsNullOrWhiteSpace(repo) ? "" : Path.Combine(repo, RepoCatalog.PlayniteAllowlistRelativePath);
    }

    private void LoadAllowlistSummary()
    {
        ReloadAllowlistEntries();
        AllowlistCountText.Text = _allAllowlistEntries.Count == 0
            ? "No allowlist entries yet."
            : $"{_allAllowlistEntries.Count} app(s) in {GetAllowlistPath()}";
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
                var runAsAdmin = app.TryGetProperty("runAsAdmin", out var raEl) && raEl.ValueKind == JsonValueKind.True
                    || app.TryGetProperty("skipAcl", out var skipEl) && skipEl.ValueKind == JsonValueKind.True;
                _allAllowlistEntries.Add(new PlayniteAllowlistEntry
                {
                    Exe = exe,
                    NameId = nameId,
                    Title = title,
                    Type = type,
                    RunAsAdmin = runAsAdmin
                });
            }
        }
        catch
        {
            // Grid stays empty; merge script validates on write.
        }

        ApplyAllowlistFilter();
    }

    private void ApplyAllowlistFilter()
    {
        var query = (AllowlistFilterBox.Text ?? "").Trim();
        IEnumerable<PlayniteAllowlistEntry> filtered = _allAllowlistEntries;

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

    private void AllowlistSkipAcl_Changed(object sender, RoutedEventArgs e)
    {
        if (sender is not CheckBox cb) return;
        if (cb.DataContext is not PlayniteAllowlistEntry entry) return;

        try
        {
            SaveAllowlistToDisk(_allAllowlistEntries);
            AllowlistGridFooter.Text = $"runAsAdmin updated for '{entry.Title}'. Re-export to Sunshine so the @ADMIN marker is emitted into resolved-appids.txt.";
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Failed to save allowlist with runAsAdmin change: {ex.Message}", "Allowlist");
        }
    }

    private void RefreshAllowlistGrid_Click(object sender, RoutedEventArgs e) => LoadAllowlistSummary();

    private void DeleteSelectedAllowlist_Click(object sender, RoutedEventArgs e)
    {
        if (AllowlistGrid.ItemsSource is not IEnumerable<PlayniteAllowlistEntry> visible)
            return;

        var selected = visible.Where(entry => entry.IsSelected).ToList();
        if (selected.Count == 0)
        {
            MessageBox.Show("Select one or more apps using the checkboxes.", "Allowlist");
            return;
        }

        if (MessageBox.Show(
                $"Remove {selected.Count} app(s) from the allowlist?",
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
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Allowlist", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
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
            var template = Path.Combine(dir!, "desktop-apps.allowlist.json.template");
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
            _comment = "List executable filenames only (exe), not install paths. Set runAsAdmin=true on Desktop apps to launch with admin privilege (High IL, via nextGPU-Admin account).",
            apps = entries.Select(e => new
            {
                exe = e.Exe,
                nameId = e.NameId,
                title = e.Title,
                type = e.Type,
                runAsAdmin = e.RunAsAdmin
            }).ToArray()
        };

        var json = JsonSerializer.Serialize(payload, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }

    // -----------------------------------------------------------------------
    // Clean Session
    // -----------------------------------------------------------------------

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
            helpText: "Registers nextGPU-SessionFolderRulesLogoff (SYSTEM + logoff) and nextGPU-SessionFolderRulesLogon scheduled tasks.");
        ActionPageTools.AddPowerShellButton(CleanSessionActionsPanel, "Seed Garena Template",
            @"scripts\runtime\Seed-SessionFolderTemplates.ps1", "-SeedGarena", keepConsoleOpen: true,
            helpText: "Copies only Config\\<name> into session-templates\\<name> and registers a replace rule.");
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
            (_, _) => OpenLogInNotepad(logPath));
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

    private static string FormatEditableList(string[] items) =>
        items.Length == 0 ? "" : string.Join(", ", items);

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
        if (e.EditAction != DataGridEditAction.Commit)
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

    // -----------------------------------------------------------------------
    // Tools & Logs
    // -----------------------------------------------------------------------

    private void BuildToolsButtons()
    {
        ToolsPanel.Children.Clear();

        ActionPageTools.AddOpenExplorerButton(ToolsPanel, "Open Steam Library Folder",
            ResolveSteamLibraryFolder,
            helpText: "Opens the first resolved Steam library folder (default install or Z:\\SteamLibrary).");

        ActionPageTools.AddOpenExplorerButton(ToolsPanel, "Open ProgramData\\nextGPU",
            () => EnsureDirectory(ProgramDataNextGpu),
            helpText: "Opens C:\\ProgramData\\nextGPU (admincred.dat, session-folder-rules.json, logs).");

        var sessionRulesLog = Path.Combine(ProgramDataNextGpu, "logs", RepoCatalog.SessionFolderRulesLog);
        var serviceLog = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "NextGPU", "Logs", "NextGPUService.log");

        ActionPageTools.AddOpenLogsButton(ToolsPanel, "Open Session Rules Log", RepoCatalog.SessionFolderRulesLog);
        AddOpenLogButton(ToolsPanel, "Open NextGPUService Log", serviceLog,
            "Service log at C:\\ProgramData\\NextGPU\\Logs\\NextGPUService.log");
        AddOpenLogButton(ToolsPanel, "Open Admin Setup Log",
            Path.Combine(ProgramDataNextGpu, "logs", "store-nextgpu-admin-credential.log"),
            "Log from Store-NextGpuAdminCredential.ps1 runs.");
    }

    private static void AddOpenLogButton(Panel panel, string label, string logPath, string helpText)
    {
        var btn = ActionPageTools.MakeButton(label, helpText, (_, _) => OpenLogInNotepad(logPath));
        if (panel is StackPanel stack)
            UiLayoutHelper.AddStretchedActionWithHelp(stack, btn, helpText);
        else
            panel.Children.Add(btn);
    }

    private static void OpenLogInNotepad(string logPath)
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
    }

    private static string ResolveSteamLibraryFolder()
    {
        var candidates = new List<string>();

        var defaultSteam = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Steam");
        if (Directory.Exists(defaultSteam))
            candidates.Add(defaultSteam);

        foreach (var root in new[] { @"Z:\SteamLibrary", @"Z:\steam", @"Z:\Steam" })
        {
            if (Directory.Exists(root))
                candidates.Add(root);
        }

        if (candidates.Count > 0)
            return candidates[0];

        var libraryVdf = Path.Combine(defaultSteam, "steamapps", "libraryfolders.vdf");
        if (File.Exists(libraryVdf))
        {
            try
            {
                foreach (var line in File.ReadAllLines(libraryVdf))
                {
                    var trimmed = line.Trim();
                    if (!trimmed.StartsWith("\"path\"", StringComparison.OrdinalIgnoreCase))
                        continue;
                    var parts = trimmed.Split('"', StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length >= 2)
                    {
                        var libPath = parts[^1].Replace("\\\\", "\\");
                        if (Directory.Exists(libPath))
                            return libPath;
                    }
                }
            }
            catch
            {
                // fall through
            }
        }

        return defaultSteam;
    }
}
