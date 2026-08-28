using System.Diagnostics;
using System.Security.Principal;

namespace NextGPU.Core;

public sealed class ScriptRunner
{
    private readonly string _repoRoot;
    private readonly AuditLogger _audit;

    public ScriptRunner(string repoRoot, AuditLogger audit)
    {
        _repoRoot = repoRoot;
        _audit = audit;
    }

    /// <param name="keepConsoleOpen">When true, elevated CMD uses /k (window stays open); PowerShell uses -NoExit so you can read install output.</param>
    public (bool Success, string Message) RunBatchRelative(string relativePath, bool elevated = true, string? arguments = null, bool keepConsoleOpen = false)
    {
        var full = ResolveUnderRepo(relativePath);
        if (full is null)
            return (false, "Path is outside repo root.");
        if (!File.Exists(full))
            return (false, $"Not found: {full}");

        _audit.Write($"Run batch: {relativePath} elevated={elevated} args={arguments ?? ""} keepConsole={keepConsoleOpen}");
        return RunProcess(full, elevated, arguments, isExecutablePath: true, keepConsoleOpen);
    }

    /// <param name="keepConsoleOpen">When true, adds -NoExit so the elevated console remains after the script finishes.</param>
    public (bool Success, string Message) RunPowerShellRelative(string relativePath, string psArguments, bool elevated = true, bool keepConsoleOpen = false)
    {
        var full = ResolveUnderRepo(relativePath);
        if (full is null)
            return (false, "Path is outside repo root.");
        if (!File.Exists(full))
            return (false, $"Not found: {full}");

        var prefix = keepConsoleOpen ? "-NoExit " : "";
        var psCommand = $"{prefix}-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{full}\" {psArguments}".Trim();
        _audit.Write($"Run PowerShell: {relativePath} {psArguments} keepConsole={keepConsoleOpen}");
        if (elevated)
            return RunElevatedPowerShellViaCmd(full, psCommand, keepConsoleOpen);
        return RunProcess("powershell.exe", false, psCommand, isExecutablePath: false, keepConsoleOpen);
    }

    public (bool Success, string Message) RunPowerShellCapture(string relativePath, string psArguments)
    {
        var full = ResolveUnderRepo(relativePath);
        if (full is null || !File.Exists(full))
            return (false, "Script not found.");

        var args = $"-NoLogo -NoProfile -ExecutionPolicy Bypass -File \"{full}\" {psArguments}".Trim();
        try
        {
            var psi = new ProcessStartInfo("powershell.exe", args)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = _repoRoot
            };
            using var p = Process.Start(psi);
            if (p is null)
                return (false, "Failed to start PowerShell.");
            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit(600_000);
            if (!string.IsNullOrWhiteSpace(stderr))
                _audit.Write($"PowerShell capture stderr: {stderr.Trim()}");
            // JSON capture scripts write payload to stdout; stderr often has Write-Warning lines that break parsers.
            var text = p.ExitCode == 0
                ? stdout.Trim()
                : (string.IsNullOrWhiteSpace(stderr) ? stdout : stderr).Trim();
            _audit.Write($"PowerShell capture exit={p.ExitCode}");
            return (p.ExitCode == 0, text);
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    private string? ResolveUnderRepo(string relativePath)
    {
        var combined = Path.GetFullPath(Path.Combine(_repoRoot, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        var root = Path.GetFullPath(_repoRoot);
        if (!combined.StartsWith(root, StringComparison.OrdinalIgnoreCase))
            return null;
        return combined;
    }

    /// <summary>
    /// Elevated PowerShell via UAC often drops -File/-ExecutionPolicy when started directly.
    /// Launch through cmd.exe so scripts run reliably on Restricted execution policy hosts.
    /// </summary>
    private (bool Success, string Message) RunElevatedPowerShellViaCmd(string scriptFullPath, string psCommand, bool keepConsoleOpen)
    {
        var scriptDir = Path.GetDirectoryName(scriptFullPath) ?? _repoRoot;
        var cmdFlag = keepConsoleOpen ? "/k" : "/c";
        var cmdArgs = $"{cmdFlag} cd /d \"{scriptDir}\" && powershell.exe {psCommand}";
        return RunProcess("cmd.exe", elevated: true, cmdArgs, isExecutablePath: true, keepConsoleOpen);
    }

    private (bool Success, string Message) RunProcess(string fileName, bool elevated, string? arguments, bool isExecutablePath = true, bool keepConsoleOpen = false)
    {
        try
        {
            ProcessStartInfo psi;
            if (isExecutablePath && fileName.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
            {
                var batDir = Path.GetDirectoryName(fileName) ?? _repoRoot;
                var cmdFlag = keepConsoleOpen ? "/k" : "/c";
                var cmdArgs = $"{cmdFlag} cd /d \"{batDir}\" && \"{fileName}\" {arguments ?? ""}".Trim();
                psi = new ProcessStartInfo("cmd.exe", cmdArgs)
                {
                    WorkingDirectory = _repoRoot
                };
            }
            else if (isExecutablePath)
            {
                psi = new ProcessStartInfo(fileName, arguments ?? "")
                {
                    WorkingDirectory = _repoRoot
                };
            }
            else
            {
                psi = new ProcessStartInfo(fileName, arguments ?? "")
                {
                    WorkingDirectory = _repoRoot
                };
            }

            if (elevated)
            {
                // Only trigger UAC if we are NOT already elevated.
                // When NextGPU.exe runs as admin, child processes inherit the elevated token automatically.
                if (!IsCurrentProcessElevated())
                {
                    psi.Verb = "runas";
                }
                psi.UseShellExecute = true;
            }
            else if (keepConsoleOpen)
            {
                // Shell execute opens a real console from the WPF host; UseShellExecute=false often yields an empty window.
                psi.UseShellExecute = true;
            }
            else
            {
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
            }

            var p = Process.Start(psi);
            if (p is null)
                return (false, "Process did not start (UAC cancelled?).");
            if (!elevated && !keepConsoleOpen)
                p.WaitForExit(600_000);
            _audit.Write($"Started: {fileName}");
            var hint = keepConsoleOpen ? " Console stays open (/k or -NoExit); close it when finished." : "";
            if (elevated || keepConsoleOpen)
                return (true, elevated ? $"Launched elevated window.{hint}" : $"Launched console window.{hint}");
            return (true, $"Finished with exit {p.ExitCode}.{hint}");
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            return (false, "UAC elevation was cancelled.");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    private static bool IsCurrentProcessElevated()
    {
        using var identity = WindowsIdentity.GetCurrent();
        var principal = new WindowsPrincipal(identity);
        return principal.IsInRole(WindowsBuiltInRole.Administrator);
    }
}
