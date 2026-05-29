using NextGPU.Core;

namespace NextGPU.App;

public sealed class AppSession : IDisposable
{
    public AppSettings Settings { get; }
    public string? RepoRoot { get; private set; }
    public AuditLogger? Audit { get; private set; }
    public WindowsServiceManager? Services { get; private set; }
    public HealthMonitor? Health { get; private set; }
    public LogTailService? LogTail { get; private set; }
    public ScriptRunner? Scripts { get; private set; }
    public bool IsAuthenticated { get; set; }

    public AppSession()
    {
        Settings = AppSettings.Load();
        ResolveRepo();
    }

    public void ResolveRepo()
    {
        Health?.Dispose();
        LogTail?.Dispose();

        var start = string.IsNullOrWhiteSpace(Settings.RepoRootOverride)
            ? AppContext.BaseDirectory
            : Settings.RepoRootOverride;

        RepoRoot = RepoRootResolver.Resolve(start);
        if (RepoRoot is not null)
        {
            Environment.SetEnvironmentVariable("NEXTGPU_REPO_ROOT", RepoRoot, EnvironmentVariableTarget.Process);
        }

        if (RepoRoot is null)
        {
            Audit = null;
            Services = new WindowsServiceManager();
            Health = new HealthMonitor(Services);
            LogTail = null;
            Scripts = null;
            return;
        }

        Audit = new AuditLogger(RepoRoot);
        Services = new WindowsServiceManager(Audit);
        Health = new HealthMonitor(Services);
        LogTail = new LogTailService(RepoRoot);
        Scripts = new ScriptRunner(RepoRoot, Audit);
        Audit.Write("NextGPU Controller session started");
    }

    public void Dispose()
    {
        Health?.Dispose();
        LogTail?.Dispose();
    }
}
