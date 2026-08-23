using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace NextGPU.Launcher;

/// <summary>
/// Session-side pipe client (same protocol as NextGPU-PlayElevated.ps1).
/// Hosted in this WinExe so Playnite / Task Scheduler never start powershell.exe.
/// </summary>
internal static class PlayElevatedClient
{
    private const string PipeName = "NextGPUControl";
    private const int DefaultTimeoutMs = 60_000;

    private static readonly string LogDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "nextGPU", "logs");
    private static readonly string LogPath = Path.Combine(LogDir, "play-elevated.log");

    public static int Run(string[] args)
    {
        if (!TryParse(args, out string exe, out string cwd, out string gameArgs, out int timeoutMs, out bool wait, out string? parseError))
        {
            WriteLog("ERROR", parseError ?? "usage");
            return 1;
        }

        exe = exe.Trim().Trim('"');
        if (!File.Exists(exe))
        {
            WriteLog("ERROR", $"Executable not found: {exe}");
            return 2;
        }

        if (string.IsNullOrWhiteSpace(cwd))
            cwd = Path.GetDirectoryName(exe) ?? "";

        WriteLog("INFO", $"Elevate request exe={exe} cwd={cwd} args={gameArgs} user={Environment.UserName}");

        PipeResponse resp;
        try
        {
            resp = SendLaunchElevated(exe, gameArgs, cwd, timeoutMs);
        }
        catch (Exception ex)
        {
            WriteLog("ERROR", $"Launch failed: {ex.Message}");
            return 1;
        }

        WriteLog("INFO", $"Service response: {JsonSerializer.Serialize(resp)}");
        if (!resp.Ok)
        {
            WriteLog("ERROR", $"Service rejected elevate: {resp.Error}");
            return 1;
        }

        int gamePid = (int)resp.Pid;
        WriteLog("INFO", $"Elevated PID: {gamePid}");

        if (wait && gamePid > 0)
        {
            try
            {
                using var proc = Process.GetProcessById(gamePid);
                WriteLog("INFO", "Waiting for process exit...");
                proc.WaitForExit();
                WriteLog("INFO", $"Process exited code={proc.ExitCode}");
            }
            catch (ArgumentException)
            {
                WriteLog("WARN", $"PID {gamePid} already gone (settled elsewhere)");
            }
        }

        return 0;
    }

    private static bool TryParse(
        string[] args,
        out string exe,
        out string cwd,
        out string gameArgs,
        out int timeoutMs,
        out bool wait,
        out string? error)
    {
        exe = "";
        cwd = "";
        gameArgs = "";
        timeoutMs = DefaultTimeoutMs;
        wait = false;
        error = null;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (IsFlag(a, "--exe", "-exe") && i + 1 < args.Length)
            {
                exe = args[++i];
                continue;
            }

            if (IsFlag(a, "--cwd", "-workingdir", "--workingdir") && i + 1 < args.Length)
            {
                cwd = args[++i];
                continue;
            }

            if (IsFlag(a, "--args", "-args") && i + 1 < args.Length)
            {
                gameArgs = args[++i];
                continue;
            }

            if (IsFlag(a, "--timeout-ms", "-timeoutms") && i + 1 < args.Length)
            {
                if (!int.TryParse(args[++i], out timeoutMs))
                    timeoutMs = DefaultTimeoutMs;
                continue;
            }

            if (IsFlag(a, "--wait", "-wait"))
            {
                wait = true;
                continue;
            }
        }

        if (string.IsNullOrWhiteSpace(exe))
        {
            error = "Usage: NextGPU.Launcher --play-elevated --exe <path> [--cwd <dir>] [--args <string>] [--wait]";
            return false;
        }

        return true;
    }

    private static bool IsFlag(string value, params string[] names)
    {
        foreach (string n in names)
        {
            if (string.Equals(value, n, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    private static PipeResponse SendLaunchElevated(string exe, string gameArgs, string cwd, int timeoutMs)
    {
        var request = new PipeRequest
        {
            Version = 1,
            Op = "launch-elevated",
            AppID = 0,
            Exe = exe,
            Args = gameArgs ?? "",
            WorkingDir = cwd ?? ""
        };
        byte[] requestBytes = JsonSerializer.SerializeToUtf8Bytes(request, JsonOptions);

        var deadline = DateTime.UtcNow.AddMilliseconds(Math.Max(timeoutMs, 1));
        Exception? last = null;
        while (DateTime.UtcNow < deadline)
        {
            var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                int remainingMs = Math.Max(1, (int)(deadline - DateTime.UtcNow).TotalMilliseconds);
                pipe.Connect(Math.Min(5000, remainingMs));
                return Exchange(pipe, requestBytes);
            }
            catch (Exception ex)
            {
                last = ex;
                try { pipe.Dispose(); } catch { }
                Thread.Sleep(500);
            }
        }

        throw new IOException($"Pipe connection to {PipeName} failed: {last?.Message}");
    }

    private static PipeResponse Exchange(NamedPipeClientStream pipe, byte[] requestBytes)
    {
        using (pipe)
        {
            pipe.Write(BitConverter.GetBytes(requestBytes.Length), 0, 4);
            pipe.Write(requestBytes, 0, requestBytes.Length);
            pipe.WaitForPipeDrain();

            byte[] lenBuf = new byte[4];
            if (ReadExact(pipe, lenBuf, 4) < 4)
                throw new IOException("Server returned short length header");

            uint len = BitConverter.ToUInt32(lenBuf, 0);
            if (len > 1_000_000)
                throw new IOException($"Server returned implausible length: {len}");

            byte[] respBuf = new byte[len];
            int total = ReadExact(pipe, respBuf, (int)len);
            string json = Encoding.UTF8.GetString(respBuf, 0, total);
            return JsonSerializer.Deserialize<PipeResponse>(json, JsonOptions)
                   ?? new PipeResponse { Ok = false, Error = "empty pipe response" };
        }
    }

    private static int ReadExact(Stream stream, byte[] buffer, int count)
    {
        int total = 0;
        while (total < count)
        {
            int n = stream.Read(buffer, total, count - total);
            if (n == 0)
                break;
            total += n;
        }
        return total;
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    private static void WriteLog(string level, string message)
    {
        string line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss}] [{level}] {message}";
        try
        {
            Directory.CreateDirectory(LogDir);
            File.AppendAllText(LogPath, line + Environment.NewLine, Encoding.UTF8);
        }
        catch { }
    }

    private sealed class PipeRequest
    {
        public int Version { get; set; }
        public string Op { get; set; } = "";
        public int? AppID { get; set; }
        public string? Exe { get; set; }
        public string? Args { get; set; }
        public string? WorkingDir { get; set; }
    }

    private sealed class PipeResponse
    {
        public bool Ok { get; set; }
        public uint Pid { get; set; }
        public string? Error { get; set; }
    }
}
