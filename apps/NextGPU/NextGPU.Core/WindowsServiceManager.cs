using System.Diagnostics;
using System.ServiceProcess;
using NextGPU.Core.Models;

namespace NextGPU.Core;

public sealed class WindowsServiceManager
{
    private readonly AuditLogger? _audit;

    public WindowsServiceManager(AuditLogger? audit = null)
    {
        _audit = audit;
    }

    public ServiceRunState GetState(string serviceName)
    {
        try
        {
            using var sc = new ServiceController(serviceName);
            return sc.Status switch
            {
                ServiceControllerStatus.Running => ServiceRunState.Running,
                ServiceControllerStatus.Stopped => ServiceRunState.Stopped,
                ServiceControllerStatus.StartPending or ServiceControllerStatus.StopPending
                    or ServiceControllerStatus.ContinuePending or ServiceControllerStatus.PausePending
                    or ServiceControllerStatus.Paused => ServiceRunState.Running,
                _ => ServiceRunState.Unknown
            };
        }
        catch (InvalidOperationException)
        {
            return QueryWithSc(serviceName);
        }
    }

    private static ServiceRunState QueryWithSc(string serviceName)
    {
        try
        {
            var psi = new ProcessStartInfo("sc.exe", $"query \"{serviceName}\"")
            {
                RedirectStandardOutput = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            if (p is null)
                return ServiceRunState.Unknown;
            var output = p.StandardOutput.ReadToEnd();
            p.WaitForExit(5000);
            if (output.Contains("RUNNING", StringComparison.OrdinalIgnoreCase))
                return ServiceRunState.Running;
            if (output.Contains("STOPPED", StringComparison.OrdinalIgnoreCase))
                return ServiceRunState.Stopped;
            if (output.Contains("1060", StringComparison.Ordinal) || output.Contains("does not exist", StringComparison.OrdinalIgnoreCase))
                return ServiceRunState.NotInstalled;
            return ServiceRunState.Unknown;
        }
        catch
        {
            return ServiceRunState.Unknown;
        }
    }

    public (bool Success, string Message) Start(string serviceName, bool elevated = true)
        => RunNetCommand("start", serviceName, elevated);

    public (bool Success, string Message) Stop(string serviceName, bool elevated = true)
        => RunNetCommand("stop", serviceName, elevated);

    public (bool Success, string Message) Restart(string serviceName, bool elevated = true)
    {
        var stop = Stop(serviceName, elevated);
        if (!stop.Success && !stop.Message.Contains("not started", StringComparison.OrdinalIgnoreCase))
            return stop;
        Thread.Sleep(1500);
        return Start(serviceName, elevated);
    }

    private (bool Success, string Message) RunNetCommand(string verb, string serviceName, bool elevated)
    {
        var args = $"{verb} \"{serviceName}\"";
        _audit?.Write($"Service {verb}: {serviceName} (elevated={elevated})");
        try
        {
            if (elevated)
                return RunElevated("net.exe", args);

            var psi = new ProcessStartInfo("net.exe", args)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = Process.Start(psi);
            if (p is null)
                return (false, "Failed to start net.exe");
            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit(120000);
            var msg = string.IsNullOrWhiteSpace(stderr) ? stdout.Trim() : stderr.Trim();
            var ok = p.ExitCode == 0
                || msg.Contains("already been started", StringComparison.OrdinalIgnoreCase)
                || msg.Contains("was started successfully", StringComparison.OrdinalIgnoreCase)
                || msg.Contains("was stopped successfully", StringComparison.OrdinalIgnoreCase);
            _audit?.Write($"Service {verb} {serviceName}: exit={p.ExitCode} {msg}");
            return (ok, msg);
        }
        catch (Exception ex)
        {
            _audit?.Write($"Service {verb} {serviceName} error: {ex.Message}");
            return (false, ex.Message);
        }
    }

    public (bool Success, string Message) RestartSunshineInteractive()
    {
        _audit?.Write("Sunshine interactive restart");
        Stop(RepoCatalog.SunshineServiceName, elevated: true);
        try
        {
            Process.Start(new ProcessStartInfo("taskkill", "/f /im sunshine.exe")
            {
                UseShellExecute = false,
                CreateNoWindow = true
            })?.WaitForExit(5000);
        }
        catch
        {
            // ignore
        }

        Thread.Sleep(2000);
        if (!File.Exists(RepoCatalog.SunshineExe))
            return (false, $"Sunshine not found at {RepoCatalog.SunshineExe}");

        try
        {
            Process.Start(new ProcessStartInfo(RepoCatalog.SunshineExe)
            {
                UseShellExecute = true,
                WorkingDirectory = Path.GetDirectoryName(RepoCatalog.SunshineExe) ?? @"C:\Program Files\Sunshine"
            });
            _audit?.Write("Sunshine started interactively");
            return (true, "Sunshine started in interactive mode (user session).");
        }
        catch (Exception ex)
        {
            _audit?.Write($"Sunshine interactive start failed: {ex.Message}");
            return (false, ex.Message);
        }
    }

    private static (bool Success, string Message) RunElevated(string fileName, string arguments)
    {
        try
        {
            var psi = new ProcessStartInfo(fileName, arguments)
            {
                Verb = "runas",
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
            using var p = Process.Start(psi);
            if (p is null)
                return (false, "Elevation cancelled or failed.");
            p.WaitForExit(120000);
            return (p.ExitCode == 0, $"Exit code {p.ExitCode}");
        }
        catch (System.ComponentModel.Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            return (false, "UAC elevation was cancelled.");
        }
    }
}
