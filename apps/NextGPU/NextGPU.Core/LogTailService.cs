namespace NextGPU.Core;

public sealed class LogTailService : IDisposable
{
    private readonly string _logsDir;
    private FileSystemWatcher? _watcher;
    private string? _currentPath;
    private long _lastPosition;

    public event Action<string>? ContentUpdated;

    public LogTailService(string repoRoot)
    {
        _logsDir = RepoRootResolver.LogsDirectory(repoRoot);
        Directory.CreateDirectory(_logsDir);
    }

    public IEnumerable<string> ListLogFiles()
    {
        var files = new List<string>();
        if (Directory.Exists(_logsDir))
        {
            foreach (var f in Directory.GetFiles(_logsDir))
            {
                var name = Path.GetFileName(f);
                if (name is not null)
                    files.Add(name);
            }
        }

        foreach (var k in RepoCatalog.KnownLogFiles)
        {
            if (!files.Contains(k, StringComparer.OrdinalIgnoreCase))
                files.Add(k);
        }

        files.Sort(StringComparer.OrdinalIgnoreCase);
        return files;
    }

    public string GetLogPath(string fileName)
    {
        var safe = Path.GetFileName(fileName);
        return Path.Combine(_logsDir, safe);
    }

    /// <summary>Returns the newest setup_log_*.txt filename under logs, or null if none.</summary>
    public string? FindLatestSetupLogFileName()
    {
        if (!Directory.Exists(_logsDir))
            return null;
        var latest = Directory.EnumerateFiles(_logsDir, "setup_log_*.txt")
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .FirstOrDefault();
        return latest is null ? null : Path.GetFileName(latest);
    }

    public string LogsDirectory => _logsDir;

    public void Watch(string fileName)
    {
        StopWatch();
        _currentPath = GetLogPath(fileName);
        if (!File.Exists(_currentPath))
        {
            File.WriteAllText(_currentPath, "");
        }

        _lastPosition = 0;
        ReadTail(fullRead: true);

        _watcher = new FileSystemWatcher(_logsDir, Path.GetFileName(_currentPath))
        {
            NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size
        };
        _watcher.Changed += (_, _) => ReadTail(fullRead: false);
        _watcher.EnableRaisingEvents = true;
    }

    public void StopWatch()
    {
        if (_watcher is not null)
        {
            _watcher.EnableRaisingEvents = false;
            _watcher.Dispose();
            _watcher = null;
        }
    }

    public string ReadAll(string fileName, int maxLines = 15000)
    {
        var path = GetLogPath(fileName);
        if (!File.Exists(path))
            return "(log file does not exist yet)";

        var lines = ReadLinesShared(path);
        if (lines.Count <= maxLines)
            return string.Join(Environment.NewLine, lines);
        return string.Join(Environment.NewLine, lines.Skip(lines.Count - maxLines));
    }

    private void ReadTail(bool fullRead, int maxLines = 2000)
    {
        if (_currentPath is null || !File.Exists(_currentPath))
            return;

        try
        {
            using var fs = new FileStream(_currentPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            if (fullRead)
            {
                _lastPosition = Math.Max(0, fs.Length - 256_000);
            }

            fs.Seek(_lastPosition, SeekOrigin.Begin);
            using var reader = new StreamReader(fs);
            var chunk = reader.ReadToEnd();
            _lastPosition = fs.Length;
            if (!string.IsNullOrEmpty(chunk))
                ContentUpdated?.Invoke(chunk);
        }
        catch
        {
            // locked or rotating — ignore
        }
    }

    private static List<string> ReadLinesShared(string path)
    {
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new StreamReader(fs);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line)
            lines.Add(line);
        return lines;
    }

    public void Dispose() => StopWatch();
}
