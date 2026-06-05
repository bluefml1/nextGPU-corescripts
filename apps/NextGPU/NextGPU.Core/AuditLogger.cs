namespace NextGPU.Core;

public sealed class AuditLogger
{
    private readonly string _logPath;
    private readonly object _lock = new();

    public AuditLogger(string repoRoot)
    {
        var logsDir = RepoRootResolver.LogsDirectory(repoRoot);
        Directory.CreateDirectory(logsDir);
        _logPath = Path.Combine(logsDir, "nextgpu-controller.log");
    }

    public void Write(string message)
    {
        var line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] {message}";
        lock (_lock)
        {
            File.AppendAllText(_logPath, line + Environment.NewLine);
        }
    }
}
