using System.Diagnostics;
using System.Text;
using NextGPU.Core.Models;

namespace NextGPU.Core;

public sealed class ScheduledTaskManager
{
    private readonly AuditLogger? _audit;

    public ScheduledTaskManager(AuditLogger? audit = null)
    {
        _audit = audit;
    }

    public IReadOnlyList<ScheduledTaskItem> CollectKnownTasks()
    {
        return RepoCatalog.KnownScheduledTasks
            .Select(template =>
            {
                var item = new ScheduledTaskItem
                {
                    TaskName = template.TaskName,
                    DisplayName = template.DisplayName,
                    Description = template.Description,
                    IntervalSummary = template.IntervalSummary,
                    RegisterScriptRelativePath = template.RegisterScriptRelativePath,
                    StdoutLogFileName = template.StdoutLogFileName,
                    StderrLogFileName = template.StderrLogFileName,
                    ManualRunScriptRelativePath = template.ManualRunScriptRelativePath,
                    State = ScheduledTaskState.Unknown
                };
                ApplyQueryResult(item, QueryTask(template.TaskName));
                return item;
            })
            .ToList();
    }

    public (bool Success, string Message) Run(string taskName, bool elevated = true)
    {
        _audit?.Write($"Scheduled task run: {taskName} elevated={elevated}");
        return RunSchtasks($"/Run /TN \"{taskName}\"", elevated);
    }

    public (bool Success, string Message) Enable(string taskName, bool elevated = true)
    {
        _audit?.Write($"Scheduled task enable: {taskName}");
        return RunSchtasks($"/Change /TN \"{taskName}\" /ENABLE", elevated);
    }

    public (bool Success, string Message) Disable(string taskName, bool elevated = true)
    {
        _audit?.Write($"Scheduled task disable: {taskName}");
        return RunSchtasks($"/Change /TN \"{taskName}\" /DISABLE", elevated);
    }

    private static Dictionary<string, string> QueryTask(string taskName)
    {
        var output = RunSchtasksCapture($"/Query /TN \"{taskName}\" /FO LIST /V");
        if (output.ExitCode != 0)
        {
            var missing = output.StdOut.Contains("ERROR: The system cannot find", StringComparison.OrdinalIgnoreCase)
                || output.StdOut.Contains("cannot find the file", StringComparison.OrdinalIgnoreCase)
                || output.StdErr.Contains("cannot find", StringComparison.OrdinalIgnoreCase);
            return missing
                ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["__missing"] = "1" }
                : new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["__error"] = string.IsNullOrWhiteSpace(output.StdErr) ? output.StdOut.Trim() : output.StdErr.Trim()
                };
        }

        return ParseSchtasksList(output.StdOut);
    }

    private static void ApplyQueryResult(ScheduledTaskItem item, Dictionary<string, string> fields)
    {
        if (fields.ContainsKey("__missing"))
        {
            item.State = ScheduledTaskState.NotInstalled;
            item.Detail = "Task not registered on this machine.";
            return;
        }

        if (fields.ContainsKey("__error"))
        {
            item.State = ScheduledTaskState.Unknown;
            item.Detail = fields["__error"];
            return;
        }

        item.LastRunTime = GetField(fields, "Last Run Time");
        item.NextRunTime = GetField(fields, "Next Run Time");
        item.TaskToRun = GetField(fields, "Task To Run");
        if (int.TryParse(GetField(fields, "Last Result"), out var lastResult))
            item.LastResult = lastResult;

        var status = GetField(fields, "Status") ?? "";
        item.State = status.Contains("Running", StringComparison.OrdinalIgnoreCase)
            ? ScheduledTaskState.Running
            : status.Contains("Disabled", StringComparison.OrdinalIgnoreCase)
                ? ScheduledTaskState.Disabled
                : status.Contains("Ready", StringComparison.OrdinalIgnoreCase)
                    ? ScheduledTaskState.Ready
                    : ScheduledTaskState.Unknown;

        item.Detail = status;
    }

    private static string? GetField(Dictionary<string, string> fields, string key)
    {
        return fields.TryGetValue(key, out var value) ? NullIfDash(value) : null;
    }

    private static string? NullIfDash(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;
        var trimmed = value.Trim();
        return trimmed is "N/A" or "-" or "n/a" ? null : trimmed;
    }

    private static Dictionary<string, string> ParseSchtasksList(string output)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var rawLine in output.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries))
        {
            var line = rawLine.Trim();
            var idx = line.IndexOf(':');
            if (idx <= 0)
                continue;
            var key = line[..idx].Trim();
            var value = line[(idx + 1)..].Trim();
            result[key] = value;
        }
        return result;
    }

    private static (int ExitCode, string StdOut, string StdErr) RunSchtasksCapture(string arguments)
    {
        try
        {
            var psi = new ProcessStartInfo("schtasks.exe", arguments)
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.Default
            };
            using var p = Process.Start(psi);
            if (p is null)
                return (-1, "", "Failed to start schtasks.exe");
            var stdout = p.StandardOutput.ReadToEnd();
            var stderr = p.StandardError.ReadToEnd();
            p.WaitForExit(30_000);
            return (p.ExitCode, stdout, stderr);
        }
        catch (Exception ex)
        {
            return (-1, "", ex.Message);
        }
    }

    private static (bool Success, string Message) RunSchtasks(string arguments, bool elevated)
    {
        try
        {
            if (elevated)
            {
                var psi = new ProcessStartInfo("schtasks.exe", arguments)
                {
                    Verb = "runas",
                    UseShellExecute = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                using var p = Process.Start(psi);
                if (p is null)
                    return (false, "Elevation cancelled or failed.");
                p.WaitForExit(60_000);
                return (p.ExitCode == 0, p.ExitCode == 0 ? "Command completed." : $"schtasks exit code {p.ExitCode}");
            }

            var capture = RunSchtasksCapture(arguments);
            var msg = string.IsNullOrWhiteSpace(capture.StdErr) ? capture.StdOut.Trim() : capture.StdErr.Trim();
            return (capture.ExitCode == 0, string.IsNullOrWhiteSpace(msg) ? $"Exit code {capture.ExitCode}" : msg);
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
}
