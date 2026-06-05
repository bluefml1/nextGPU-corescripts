namespace NextGPU.Core;

public static class RepoRootResolver
{
    private const string EnvVar = "NEXTGPU_REPO_ROOT";
    private const string RootLauncher = "RegisterMachine_Beta.bat";
    private const string ProvisioningScript = "scripts/provisioning/RegisterMachine_Beta.bat";

    public static string? Resolve(string? startDirectory = null)
    {
        var env = Environment.GetEnvironmentVariable(EnvVar);
        if (!string.IsNullOrWhiteSpace(env))
        {
            var fromEnv = Path.GetFullPath(env.Trim());
            if (IsRepoRoot(fromEnv))
                return fromEnv;
        }

        var dir = startDirectory;
        if (string.IsNullOrWhiteSpace(dir))
            dir = AppContext.BaseDirectory;

        var current = new DirectoryInfo(Path.GetFullPath(dir));
        while (current is not null)
        {
            if (IsRepoRoot(current.FullName))
                return current.FullName;
            current = current.Parent;
        }

        return null;
    }

    public static bool IsRepoRoot(string path)
    {
        return File.Exists(Path.Combine(path, RootLauncher))
            && File.Exists(Path.Combine(path, ProvisioningScript));
    }

    public static string LogsDirectory(string repoRoot) => Path.Combine(repoRoot, "logs");

    public static string DomainFile(string repoRoot) => Path.Combine(repoRoot, "domain.txt");
}
