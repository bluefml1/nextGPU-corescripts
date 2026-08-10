using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Extensions.Logging;
using Timer = System.Threading.Timer;

namespace NextGPU.Service;

public sealed class LaunchResult
{
    public bool Ok { get; set; }
    public uint Pid { get; set; }
    public string? Error { get; set; }
}

public sealed class ResolvedApp
{
    public required string Exe { get; init; }
    public string Args { get; init; } = "";
    public string WorkingDir { get; init; } = "";
    public AppKind Kind { get; init; } = AppKind.Exe;
    public bool RunAsAdmin { get; init; }
}

public enum AppKind
{
    Exe,
    PlayniteStart,
}

public sealed class AllowlistService
{
    private readonly ILogger<AllowlistService> _log;
    private readonly string _resolvedTxtPath;
    private readonly string _resolvedJsonPath;
    private readonly Dictionary<int, ResolvedApp> _appMap = new();
    private readonly object _lock = new();
    private readonly Timer _fallbackTimer;
    private FileSystemWatcher? _watcher;
    private bool _initialized;

    private static readonly Regex AdminMarkerRegex = new(@"\s@ADMIN\b", RegexOptions.Compiled);

    public AllowlistService(ILogger<AllowlistService> log)
    {
        _log = log;
        string configDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "Sunshine", "config");
        _resolvedTxtPath = Path.Combine(configDir, "resolved-appids.txt");
        _resolvedJsonPath = Path.Combine(configDir, "resolved-appids.json");

        _fallbackTimer = new Timer(_ => RefreshMap(), null, Timeout.Infinite, Timeout.Infinite);
    }

    private void EnsureInitialized()
    {
        if (_initialized) return;
        lock (_lock)
        {
            if (_initialized) return;
            _initialized = true;

            string? dir = Path.GetDirectoryName(_resolvedTxtPath);
            if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
            {
                try
                {
                    _watcher = new FileSystemWatcher(dir)
                    {
                        Filter = Path.GetFileName(_resolvedTxtPath),
                        NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size,
                        EnableRaisingEvents = true
                    };
                    _watcher.Changed += OnWatcherChanged;
                    _log.LogInformation("AllowlistService watching {Path}", _resolvedTxtPath);
                }
                catch (Exception ex)
                {
                    _log.LogWarning(ex, "AllowlistService could not create FileSystemWatcher");
                }
            }
            else
            {
                _log.LogWarning("Sunshine config dir not found, skipping watcher ({Path})", _resolvedTxtPath);
            }

            try
            {
                RefreshMap();
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "AllowlistService initial load failed");
            }
        }
    }

    private void OnWatcherChanged(object sender, FileSystemEventArgs e)
    {
        _log.LogDebug("FileSystemWatcher triggered: {ChangeType} {FullPath}", e.ChangeType, e.FullPath);
        _fallbackTimer.Change(500, Timeout.Infinite);
    }

    public ResolvedApp? Map(int appId)
    {
        EnsureInitialized();
        lock (_lock)
        {
            return _appMap.TryGetValue(appId, out var app) ? app : null;
        }
    }

    public void RefreshMap()
    {
        if (!File.Exists(_resolvedTxtPath))
        {
            _log.LogWarning("resolved-appids.txt not found at {Path}", _resolvedTxtPath);
            return;
        }

        Dictionary<int, ResolvedApp> newMap = new();

        try
        {
            var content = File.ReadAllText(_resolvedTxtPath);
            var lines = content.Split('\n', StringSplitOptions.RemoveEmptyEntries);

            string? currentSection = null;

            foreach (string rawLine in lines)
            {
                var line = rawLine.Trim();

                if (string.IsNullOrEmpty(line))
                    continue;

                // Section header lines (Steam:, Desktop:, Epic:)
                if (line.EndsWith(':'))
                {
                    currentSection = line.TrimEnd(':').Trim();
                    continue;
                }

                // Data lines: "appId: launchPath | installDir"
                int colonIdx = line.IndexOf(':');
                if (colonIdx <= 0)
                    continue;

                var idPart = line[..colonIdx].Trim();
                if (!int.TryParse(idPart, out int appId))
                    continue;

                var afterColon = line[(colonIdx + 1)..].Trim();

                // Split on " | " to separate launchPath from installDir
                string launchPath;
                string installDir;

                int pipeIdx = afterColon.IndexOf(" | ");
                if (pipeIdx >= 0)
                {
                    launchPath = afterColon[..pipeIdx].Trim();
                    installDir = afterColon[(pipeIdx + 3)..].Trim();
                }
                else
                {
                    // No pipe — treat whole thing as launchPath
                    launchPath = afterColon;
                    installDir = "";
                }

                bool runAsAdmin = AdminMarkerRegex.IsMatch(launchPath);
                var cleanLaunchPath = AdminMarkerRegex.Replace(launchPath, "").Trim();

                // Extract Exe and Args from launchPath
                // Format: &"path" args  or  "path" args  or  path args
                string exePath;
                string args;

                if (cleanLaunchPath.StartsWith('&'))
                {
                    // PowerShell call operator: &"D:\path\app.exe" --arg
                    var rest = cleanLaunchPath[1..].TrimStart();
                    if (rest.StartsWith('"'))
                    {
                        var endQuote = rest.IndexOf('"', 1);
                        if (endQuote > 0)
                        {
                            exePath = rest[1..endQuote];
                            args = rest[(endQuote + 1)..].Trim();
                        }
                        else
                        {
                            exePath = rest;
                            args = "";
                        }
                    }
                    else
                    {
                        var spaceIdx = rest.IndexOf(' ');
                        if (spaceIdx > 0)
                        {
                            exePath = rest[..spaceIdx];
                            args = rest[(spaceIdx + 1)..].Trim();
                        }
                        else
                        {
                            exePath = rest;
                            args = "";
                        }
                    }
                }
                else if (cleanLaunchPath.StartsWith('"'))
                {
                    var endQuote = cleanLaunchPath.IndexOf('"', 1);
                    if (endQuote > 0)
                    {
                        exePath = cleanLaunchPath[1..endQuote];
                        args = cleanLaunchPath[(endQuote + 1)..].Trim();
                    }
                    else
                    {
                        exePath = cleanLaunchPath;
                        args = "";
                    }
                }
                else
                {
                    var spaceIdx = cleanLaunchPath.IndexOf(' ');
                    if (spaceIdx > 0)
                    {
                        exePath = cleanLaunchPath[..spaceIdx];
                        args = cleanLaunchPath[(spaceIdx + 1)..].Trim();
                    }
                    else
                    {
                        exePath = cleanLaunchPath;
                        args = "";
                    }
                }

                if (string.IsNullOrEmpty(exePath))
                    continue;

                // Resolve working directory
                string workingDir = installDir;
                if (string.IsNullOrEmpty(workingDir))
                    workingDir = Path.GetDirectoryName(exePath) ?? "";

                // Resolve args from JSON if available
                string resolvedArgs = ResolveArgsFromJson(appId, args);

                AppKind kind = AppKind.Exe;
                if (exePath.EndsWith("Playnite.DesktopApp.exe", StringComparison.OrdinalIgnoreCase)
                    && (resolvedArgs.Contains("--start", StringComparison.OrdinalIgnoreCase)
                        || args.Contains("--start", StringComparison.OrdinalIgnoreCase)))
                {
                    kind = AppKind.PlayniteStart;
                }

                var resolvedApp = new ResolvedApp
                {
                    Exe = exePath,
                    Args = resolvedArgs,
                    WorkingDir = workingDir,
                    Kind = kind,
                    RunAsAdmin = runAsAdmin
                };

                newMap[appId] = resolvedApp;
            }

            lock (_lock)
            {
                _appMap.Clear();
                foreach (var kv in newMap)
                    _appMap[kv.Key] = kv.Value;
            }

            _log.LogInformation("AllowlistService loaded {Count} apps from resolved-appids.txt", newMap.Count);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to parse resolved-appids.txt");
        }
    }

    private string ResolveArgsFromJson(int appId, string fallbackArgs)
    {
        if (!File.Exists(_resolvedJsonPath))
            return fallbackArgs;

        try
        {
            var json = File.ReadAllText(_resolvedJsonPath);
            using var doc = JsonDocument.Parse(json);
            foreach (var elem in doc.RootElement.EnumerateArray())
            {
                if (!elem.TryGetProperty("AppID", out var appIdProp))
                    continue;
                if (!int.TryParse(appIdProp.GetString(), out var jsonAppId))
                    continue;
                if (jsonAppId != appId)
                    continue;

                if (elem.TryGetProperty("Args", out var argsProp))
                {
                    var args = argsProp.GetString();
                    if (!string.IsNullOrEmpty(args))
                        return args;
                }
                break;
            }
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "Could not resolve args from JSON for appID {AppId}", appId);
        }

        return fallbackArgs;
    }

    public void Dispose()
    {
        _fallbackTimer.Dispose();
        _watcher?.Dispose();
    }
}