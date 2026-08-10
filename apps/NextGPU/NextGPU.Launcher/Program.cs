using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.ServiceModel;
using System.Text;
using System.Text.Json;
using System.Xml;

namespace NextGPU.Launcher;

/// <summary>
/// In-session desktop broker. Already running as NextGPU-Admin inside the nextGPU
/// session (service did LogonUser + CreateProcessAsUser). Starts the real app via
/// CreateProcessW or ShellExecuteEx and prints one JSON line to stdout with the PID.
/// </summary>
internal static class Program
{
    private const string PlayniteExeSuffix = "Playnite.DesktopApp.exe";
    private const string PipeEndpointKey = "PipeEndpoint";
    private const string DefaultPipeEndpoint = "net.pipe://localhost/PlaynitePipe";
    private const uint ChildSettleMs = 1500;
    private const uint STILL_ACTIVE = 259;

    private static readonly string LogDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "nextGPU", "logs");
    private static readonly string LogPath = Path.Combine(LogDir, "launcher.log");
    private static readonly string ErrLogPath = Path.Combine(LogDir, "launcher.err.log");
    private static readonly string ChildErrLogPath = Path.Combine(LogDir, "launcher-child.err.log");

    private static TextWriter? _errFile;
    private static StringWriter? _errCapture;
    private static TextWriter? _previousError;

    public static int Main(string[] args)
    {
        int exitCode = 1;
        try
        {
            BeginStderrCapture();
            LogContextBanner(args);

            // In-session helper: grant NextGPU-Admin ACEs on winsta0\default.
            // Must run as the session user (not from session 0).
            if (args.Length >= 2 &&
                string.Equals(args[0], "--grant-desktop", StringComparison.OrdinalIgnoreCase))
            {
                Log($"grant-desktop account={args[1]}");
                exitCode = DesktopGrant.Run(args[1]);
                Log($"grant-desktop exit={exitCode}");
                return exitCode;
            }

            if (!TryParseArgs(args, out string? cwd, out string target, out string? targetArgs, out bool asAdmin, out string? parseError))
            {
                WriteResult(ok: false, pid: 0, error: parseError ?? "usage");
                Log($"FATAL parse: {parseError}");
                Console.Error.WriteLine($"FATAL: {parseError}");
                exitCode = 1;
                return exitCode;
            }

            Log($"Parsed cwd={cwd ?? "(null)"} target={target} args={targetArgs ?? "(none)"} asAdmin={asAdmin}");
            LogPathState(target, cwd);

            string? adminPassword = null;
            if (asAdmin)
            {
                // Service writes one password line on stdin (never on cmdline).
                try { adminPassword = Console.In.ReadLine(); } catch { }
                if (string.IsNullOrEmpty(adminPassword))
                {
                    WriteResult(ok: false, pid: 0, error: "as-admin requires password on stdin");
                    Log("FATAL: missing admin password on stdin");
                    exitCode = 1;
                    return exitCode;
                }
                Log("as-admin: password received on stdin (not logged)");
            }

            if (TryForwardPlayniteStart(target, targetArgs, out string? forwardError, out uint forwardedPid))
            {
                WriteResult(ok: true, pid: forwardedPid, error: null, forwarded: true);
                Log($"FORWARD ok pid={forwardedPid}");
                exitCode = 0;
                return exitCode;
            }

            if (forwardError != null)
                Log($"Playnite forward skipped: {forwardError}");

            bool useShell = ShouldUseShellExecute(target);
            Log($"Launch mode={(useShell ? "ShellExecuteEx" : "CreateProcessW")}");

            if (useShell)
            {
                if (asAdmin)
                {
                    WriteResult(ok: false, pid: 0, error: "as-admin does not support ShellExecute targets");
                    exitCode = 1;
                    return exitCode;
                }

                if (!LaunchViaShellExecute(target, targetArgs, cwd, out uint pid, out string? err))
                {
                    WriteResult(ok: false, pid: 0, error: err);
                    Log($"ShellExecuteEx FAILED: {err}");
                    Console.Error.WriteLine($"ShellExecuteEx failed: {err}");
                    exitCode = 1;
                    return exitCode;
                }

                LogProcessSnapshot("after-ShellExecuteEx", pid);
                WriteResult(ok: true, pid: pid, error: null);
                Log($"ShellExecuteEx ok pid={pid}");
                exitCode = 0;
                return exitCode;
            }

            bool launched;
            uint createPid;
            string? createErr;
            if (asAdmin)
            {
                launched = LaunchViaCreateProcessWithLogon(
                    target, targetArgs, cwd, adminPassword!, out createPid, out createErr);
            }
            else
            {
                launched = LaunchViaCreateProcess(target, targetArgs, cwd, out createPid, out createErr);
            }

            // Best-effort wipe password from memory.
            if (adminPassword != null)
            {
                unsafe
                {
                    fixed (char* p = adminPassword)
                    {
                        for (int i = 0; i < adminPassword.Length; i++)
                            p[i] = '\0';
                    }
                }
            }

            if (!launched)
            {
                WriteResult(ok: false, pid: 0, error: createErr);
                Log($"Launch FAILED: {createErr}");
                Console.Error.WriteLine($"Launch failed: {createErr}");
                exitCode = 1;
                return exitCode;
            }

            WriteResult(ok: true, pid: createPid, error: null);
            Log($"Launch ok pid={createPid} (asAdmin={asAdmin})");
            exitCode = 0;
            return exitCode;
        }
        catch (Exception ex)
        {
            try { WriteResult(ok: false, pid: 0, error: ex.Message); } catch { }
            Log($"Unhandled: {ex}");
            try { Console.Error.WriteLine($"Unhandled: {ex}"); } catch { }
            exitCode = 1;
            return exitCode;
        }
        finally
        {
            FlushStderrToLog(exitCode);
        }
    }

    private static void LogContextBanner(string[] args)
    {
        try
        {
            string user = WindowsIdentity.GetCurrent()?.Name ?? Environment.UserName;
            uint session = 0;
            Native.ProcessIdToSessionId((uint)Environment.ProcessId, out session);
            Log("======== launcher start ========");
            Log($"launcherPid={Environment.ProcessId} sessionId={session} user={user}");
            Log($"interactive={Environment.UserInteractive} machine={Environment.MachineName}");
            Log($"cwd={Environment.CurrentDirectory}");
            Log($"exe={Environment.ProcessPath}");
            Log($"rawArgs[{args.Length}]={string.Join(" | ", args.Select(a => $"'{a}'"))}");
            Log($"USERPROFILE={Environment.GetEnvironmentVariable("USERPROFILE")}");
            Log($"APPDATA={Environment.GetEnvironmentVariable("APPDATA")}");
            Log($"LOCALAPPDATA={Environment.GetEnvironmentVariable("LOCALAPPDATA")}");
            Log($"TEMP={Environment.GetEnvironmentVariable("TEMP")}");
        }
        catch (Exception ex)
        {
            Log($"LogContextBanner failed: {ex.Message}");
        }
    }

    private static void LogPathState(string target, string? cwd)
    {
        try
        {
            bool isUrl = target.Contains("://", StringComparison.Ordinal);
            Log($"target IsUrl={isUrl} Exists={!isUrl && File.Exists(target)}");
            if (!isUrl && File.Exists(target))
            {
                var fi = new FileInfo(target);
                Log($"target size={fi.Length} lastWrite={fi.LastWriteTime:yyyy-MM-dd HH:mm:ss}");
            }
            if (!string.IsNullOrEmpty(cwd))
                Log($"cwd Exists={Directory.Exists(cwd)}");
        }
        catch (Exception ex)
        {
            Log($"LogPathState failed: {ex.Message}");
        }
    }

    private static void BeginStderrCapture()
    {
        try
        {
            Directory.CreateDirectory(LogDir);
            _errCapture = new StringWriter();
            _errFile = new StreamWriter(
                new FileStream(ErrLogPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite),
                Encoding.UTF8)
            {
                AutoFlush = true
            };
            _errFile.WriteLine($"----- {DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} launcher start pid={Environment.ProcessId} -----");
            _previousError = Console.Error;
            Console.SetError(new TeeTextWriter(_errCapture, _errFile, _previousError));
            Log($"stderr tee -> {ErrLogPath}");
        }
        catch (Exception ex)
        {
            Log($"BeginStderrCapture failed: {ex.Message}");
        }
    }

    private static void FlushStderrToLog(int exitCode)
    {
        try { Console.Error.Flush(); } catch { }

        try
        {
            if (_errFile != null)
            {
                _errFile.WriteLine($"----- {DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} launcher exit={exitCode} -----");
                _errFile.Flush();
            }
        }
        catch { }

        try
        {
            string? captured = _errCapture?.ToString();
            if (!string.IsNullOrWhiteSpace(captured))
                Log($"stderr capture ({captured.Length} chars):\n{captured.TrimEnd()}");
            else
                Log("stderr capture empty");
        }
        catch { }

        try
        {
            if (_previousError != null)
                Console.SetError(_previousError);
        }
        catch { }

        try { _errFile?.Dispose(); } catch { }
        try { _errCapture?.Dispose(); } catch { }
        _errFile = null;
        _errCapture = null;
        _previousError = null;
        Log($"======== launcher end exit={exitCode} ========");
    }

    private sealed class TeeTextWriter : TextWriter
    {
        private readonly TextWriter _a;
        private readonly TextWriter _b;
        private readonly TextWriter? _c;

        public TeeTextWriter(TextWriter a, TextWriter b, TextWriter? c)
        {
            _a = a;
            _b = b;
            _c = c;
        }

        public override Encoding Encoding => Encoding.UTF8;

        public override void Write(char value)
        {
            _a.Write(value);
            _b.Write(value);
            _c?.Write(value);
        }

        public override void Write(char[] buffer, int index, int count)
        {
            _a.Write(buffer, index, count);
            _b.Write(buffer, index, count);
            _c?.Write(buffer, index, count);
        }

        public override void Write(string? value)
        {
            _a.Write(value);
            _b.Write(value);
            _c?.Write(value);
        }

        public override void Flush()
        {
            _a.Flush();
            _b.Flush();
            _c?.Flush();
        }
    }

    private static bool TryParseArgs(
        string[] args,
        out string? cwd,
        out string target,
        out string? targetArgs,
        out bool asAdmin,
        out string? error)
    {
        cwd = null;
        target = "";
        targetArgs = null;
        asAdmin = false;
        error = null;

        var remaining = new List<string>();
        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (string.Equals(a, "--cwd", StringComparison.OrdinalIgnoreCase))
            {
                if (i + 1 >= args.Length)
                {
                    error = "Usage: NextGPU.Launcher [--as-admin] --cwd <dir> -- <target> [args...]";
                    return false;
                }
                cwd = args[++i];
                continue;
            }

            if (string.Equals(a, "--as-admin", StringComparison.OrdinalIgnoreCase))
            {
                asAdmin = true;
                continue;
            }

            if (a == "--")
            {
                remaining.AddRange(args.Skip(i + 1));
                break;
            }

            remaining.Add(a);
        }

        if (remaining.Count == 0)
        {
            error = "Usage: NextGPU.Launcher [--as-admin] --cwd <dir> -- <target> [args...]";
            return false;
        }

        target = remaining[0];
        if (remaining.Count > 1)
            targetArgs = string.Join(" ", remaining.Skip(1));

        return true;
    }

    private static bool ShouldUseShellExecute(string target)
    {
        if (target.Contains("://", StringComparison.Ordinal))
            return true;
        if (target.EndsWith(".url", StringComparison.OrdinalIgnoreCase))
            return true;
        if (target.EndsWith(".lnk", StringComparison.OrdinalIgnoreCase))
            return true;
        return false;
    }

    private static bool LaunchViaCreateProcessWithLogon(
        string exe,
        string? args,
        string? cwd,
        string password,
        out uint pid,
        out string? error)
    {
        pid = 0;
        error = null;

        if (!File.Exists(exe))
        {
            error = $"Executable not found: {exe}";
            return false;
        }

        string commandLine = string.IsNullOrEmpty(args)
            ? $"\"{exe}\""
            : $"\"{exe}\" {args}";

        string? workDir = cwd;
        if (string.IsNullOrWhiteSpace(workDir))
            workDir = Path.GetDirectoryName(exe);
        if (string.IsNullOrWhiteSpace(workDir) || !Directory.Exists(workDir))
            workDir = null;

        const string adminUser = "NextGPU-Admin";
        const string adminDomain = ".";

        Log($"CreateProcessWithLogonW user={adminDomain}\\{adminUser} cmdline={commandLine}");
        Log($"CreateProcessWithLogonW workDir={workDir ?? "(null)"}");

        var si = new Native.STARTUPINFO
        {
            cb = (uint)Marshal.SizeOf<Native.STARTUPINFO>(),
            // Empty desktop inherits caller's interactive desktop (Authority session).
            lpDesktop = null,
            dwFlags = Native.STARTF_USESHOWWINDOW | Native.STARTF_FORCEONFEEDBACK,
            wShowWindow = Native.SW_SHOW
        };

        bool ok = Native.CreateProcessWithLogonW(
            adminUser,
            adminDomain,
            password,
            Native.LOGON_WITH_PROFILE,
            null,
            commandLine,
            Native.NORMAL_PRIORITY_CLASS,
            IntPtr.Zero,
            workDir,
            ref si,
            out Native.PROCESS_INFORMATION pi);

        if (!ok)
        {
            int err = Marshal.GetLastWin32Error();
            error = $"CreateProcessWithLogonW failed: {err}";
            Log($"CreateProcessWithLogonW GetLastError={err}");
            return false;
        }

        pid = pi.dwProcessId;
        Log($"CreateProcessWithLogonW succeeded pid={pid} tid={pi.dwThreadId}");

        uint wait = Native.WaitForSingleObject(pi.hProcess, ChildSettleMs);
        Native.GetExitCodeProcess(pi.hProcess, out uint exitCode);
        Log($"settle wait={wait} (0=signaled) exitCode={(exitCode == STILL_ACTIVE ? "STILL_ACTIVE" : exitCode.ToString())} after {ChildSettleMs}ms");
        LogProcessSnapshot("after-CreateProcessWithLogonW-settle", pid, pi.hProcess, exitCode);

        if (pi.hThread != IntPtr.Zero) Native.CloseHandle(pi.hThread);
        if (pi.hProcess != IntPtr.Zero) Native.CloseHandle(pi.hProcess);

        if (exitCode != STILL_ACTIVE)
        {
            string hex = $"0x{exitCode:X8}";
            error = $"Child exited during settle exitCode={exitCode} ({hex}) pid={pid}";
            Log($"FAIL: {error}");
            Console.Error.WriteLine(error);
            return false;
        }

        return true;
    }

    private static bool LaunchViaCreateProcess(
        string exe,
        string? args,
        string? cwd,
        out uint pid,
        out string? error)
    {
        pid = 0;
        error = null;

        if (!File.Exists(exe))
        {
            error = $"Executable not found: {exe}";
            return false;
        }

        string commandLine = string.IsNullOrEmpty(args)
            ? $"\"{exe}\""
            : $"\"{exe}\" {args}";

        string? workDir = cwd;
        if (string.IsNullOrWhiteSpace(workDir))
            workDir = Path.GetDirectoryName(exe);
        if (string.IsNullOrWhiteSpace(workDir) || !Directory.Exists(workDir))
            workDir = null;

        Log($"CreateProcessW cmdline={commandLine}");
        Log($"CreateProcessW workDir={workDir ?? "(null)"}");

            // Do NOT redirect GUI child std handles — Electron/Chromium often dies
            // (or behaves oddly) under STARTF_USESTDHANDLES. Child stderr is best-
            // effort via separate app logs; we only settle-wait + log exit codes.
            WriteChildErrMarker($"CreateProcessW launching exe={exe} cmdline={commandLine}");

            var si = new Native.STARTUPINFO
            {
                cb = (uint)Marshal.SizeOf<Native.STARTUPINFO>(),
                dwFlags = Native.STARTF_USESHOWWINDOW | Native.STARTF_FORCEONFEEDBACK,
                wShowWindow = Native.SW_SHOW
            };

            bool ok = Native.CreateProcessW(
                null,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                Native.NORMAL_PRIORITY_CLASS,
                IntPtr.Zero,
                workDir,
                ref si,
                out Native.PROCESS_INFORMATION pi);

            if (!ok)
            {
                int err = Marshal.GetLastWin32Error();
                error = $"CreateProcessW failed: {err}";
                Log($"CreateProcessW GetLastError={err}");
                return false;
            }

            pid = pi.dwProcessId;
            Log($"CreateProcessW succeeded pid={pid} tid={pi.dwThreadId}");

            uint wait = Native.WaitForSingleObject(pi.hProcess, ChildSettleMs);
            Native.GetExitCodeProcess(pi.hProcess, out uint exitCode);
            Log($"settle wait={wait} (0=signaled) exitCode={(exitCode == STILL_ACTIVE ? "STILL_ACTIVE" : exitCode.ToString())} after {ChildSettleMs}ms");

            LogProcessSnapshot("after-CreateProcessW-settle", pid, pi.hProcess, exitCode);

            if (pi.hThread != IntPtr.Zero) Native.CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) Native.CloseHandle(pi.hProcess);

            if (exitCode != STILL_ACTIVE)
            {
                string hex = $"0x{exitCode:X8}";
                error = $"Child exited during settle exitCode={exitCode} ({hex}) pid={pid}";
                Log($"FAIL: {error}");
                Console.Error.WriteLine(error);
                return false;
            }

            return true;
    }

    private static void LogProcessSnapshot(string phase, uint pid, IntPtr hProcess = default, uint knownExit = 0)
    {
        try
        {
            if (!Native.ProcessIdToSessionId(pid, out uint sess))
                sess = uint.MaxValue;

            try
            {
                using var proc = Process.GetProcessById((int)pid);
                string module = "(n/a)";
                try { module = proc.MainModule?.FileName ?? "(null)"; } catch (Exception ex) { module = $"(MainModule:{ex.GetType().Name})"; }
                bool hasExited = false;
                try { hasExited = proc.HasExited; } catch { }
                Log($"[{phase}] pid={pid} session={sess} hasExited={hasExited} name={proc.ProcessName} module={module}");
                if (!hasExited)
                {
                    try { Log($"[{phase}] workingSet={proc.WorkingSet64} threads={proc.Threads.Count}"); } catch { }
                }
            }
            catch (Exception ex)
            {
                Log($"[{phase}] pid={pid} session={sess} GetProcessById failed: {ex.GetType().Name}: {ex.Message}");
                if (hProcess != IntPtr.Zero && knownExit != 0 && knownExit != STILL_ACTIVE)
                    Log($"[{phase}] knownExitCode={knownExit}");
            }
        }
        catch (Exception ex)
        {
            Log($"LogProcessSnapshot failed: {ex.Message}");
        }
    }

    private static IntPtr OpenAppendLogHandle(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var sa = new Native.SECURITY_ATTRIBUTES
            {
                nLength = Marshal.SizeOf<Native.SECURITY_ATTRIBUTES>(),
                bInheritHandle = true,
                lpSecurityDescriptor = IntPtr.Zero
            };
            IntPtr h = Native.CreateFileW(
                path,
                Native.FILE_APPEND_DATA | Native.SYNCHRONIZE,
                Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE,
                ref sa,
                Native.OPEN_ALWAYS,
                Native.FILE_ATTRIBUTE_NORMAL,
                IntPtr.Zero);
            if (h == Native.INVALID_HANDLE_VALUE || h == IntPtr.Zero)
            {
                Log($"CreateFileW({path}) failed err={Marshal.GetLastWin32Error()}");
                return IntPtr.Zero;
            }
            return h;
        }
        catch (Exception ex)
        {
            Log($"OpenAppendLogHandle failed: {ex.Message}");
            return IntPtr.Zero;
        }
    }

    private static IntPtr OpenNulHandle()
    {
        var sa = new Native.SECURITY_ATTRIBUTES
        {
            nLength = Marshal.SizeOf<Native.SECURITY_ATTRIBUTES>(),
            bInheritHandle = true,
            lpSecurityDescriptor = IntPtr.Zero
        };
        IntPtr h = Native.CreateFileW(
            "NUL",
            Native.GENERIC_READ | Native.GENERIC_WRITE,
            Native.FILE_SHARE_READ | Native.FILE_SHARE_WRITE,
            ref sa,
            Native.OPEN_EXISTING,
            0,
            IntPtr.Zero);
        if (h == Native.INVALID_HANDLE_VALUE || h == IntPtr.Zero)
            return IntPtr.Zero;
        return h;
    }

    private static void WriteChildErrMarker(string message)
    {
        try
        {
            File.AppendAllText(
                ChildErrLogPath,
                $"----- {DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message} -----{Environment.NewLine}");
        }
        catch { }
    }

    private static bool LaunchViaShellExecute(
        string file,
        string? parameters,
        string? cwd,
        out uint pid,
        out string? error)
    {
        pid = 0;
        error = null;

        Log($"ShellExecuteEx file={file} params={parameters ?? "(none)"} dir={cwd ?? "(null)"} verb=open");

        var info = new Native.SHELLEXECUTEINFO
        {
            cbSize = (uint)Marshal.SizeOf<Native.SHELLEXECUTEINFO>(),
            fMask = Native.SEE_MASK_NOCLOSEPROCESS | Native.SEE_MASK_FLAG_NO_UI,
            hwnd = IntPtr.Zero,
            lpVerb = "open",
            lpFile = file,
            lpParameters = parameters,
            lpDirectory = string.IsNullOrWhiteSpace(cwd) ? null : cwd,
            nShow = Native.SW_SHOWNORMAL
        };

        if (!Native.ShellExecuteExW(ref info))
        {
            int err = Marshal.GetLastWin32Error();
            error = $"ShellExecuteExW failed: {err}";
            Log($"ShellExecuteExW GetLastError={err} hInstApp={info.hInstApp}");
            return false;
        }

        Log($"ShellExecuteExW ok hInstApp={info.hInstApp} hProcess={(info.hProcess != IntPtr.Zero)}");

        if (info.hProcess != IntPtr.Zero)
        {
            pid = NativeGetProcessId(info.hProcess);
            uint wait = Native.WaitForSingleObject(info.hProcess, ChildSettleMs);
            Native.GetExitCodeProcess(info.hProcess, out uint exitCode);
            Log($"ShellExecute settle wait={wait} exitCode={(exitCode == STILL_ACTIVE ? "STILL_ACTIVE" : exitCode.ToString())}");
            Native.CloseHandle(info.hProcess);
        }
        else
        {
            Log("ShellExecuteEx returned no process handle (protocol/activation path)");
        }

        return true;
    }

    [DllImport("kernel32.dll")]
    private static extern uint NativeGetProcessId(IntPtr handle);

    private static bool TryForwardPlayniteStart(
        string gameExe,
        string? gameArgs,
        out string? forwardError,
        out uint pid)
    {
        forwardError = null;
        pid = 0;

        if (!gameExe.EndsWith(PlayniteExeSuffix, StringComparison.OrdinalIgnoreCase))
            return false;

        string? startGuid = ExtractStartGuid(gameArgs);
        if (startGuid == null)
            return false;

        string? pipeEndpoint = ResolvePipeEndpoint(gameExe);
        if (pipeEndpoint == null)
        {
            forwardError = "Playnite pipe endpoint not resolvable";
            return false;
        }

        Log($"Playnite forward attempt guid={startGuid} endpoint={pipeEndpoint}");

        var binding = new NetNamedPipeBinding
        {
            OpenTimeout = TimeSpan.FromMilliseconds(1500),
            SendTimeout = TimeSpan.FromMilliseconds(1500),
            CloseTimeout = TimeSpan.FromMilliseconds(500),
            ReceiveTimeout = TimeSpan.FromMilliseconds(1500),
        };

        try
        {
            var factory = new ChannelFactory<IPlaynitePipeService>(binding, new EndpointAddress(pipeEndpoint));
            try
            {
                var proxy = factory.CreateChannel();
                try
                {
                    proxy.InvokeCommand(PlayniteCmdlineCommand.Start, startGuid);
                    pid = FindPlaynitePid(gameExe);
                    Log($"Playnite forward InvokeCommand ok; resolvedPid={pid}");
                    return true;
                }
                finally
                {
                    try { ((System.ServiceModel.Channels.IChannel)proxy).Close(); } catch { }
                }
            }
            finally
            {
                try { factory.Close(); } catch { }
            }
        }
        catch (Exception ex)
        {
            forwardError = $"Playnite pipe unreachable ({ex.GetType().Name}: {ex.Message})";
            return false;
        }
    }

    private static uint FindPlaynitePid(string gameExe)
    {
        string name = Path.GetFileNameWithoutExtension(gameExe);
        try
        {
            Process[] procs = Process.GetProcessesByName(name);
            if (procs.Length == 0)
                return 0;
            Process best = procs.OrderByDescending(p =>
            {
                try { return p.StartTime; }
                catch { return DateTime.MinValue; }
            }).First();
            uint id = (uint)best.Id;
            foreach (var p in procs) p.Dispose();
            return id;
        }
        catch
        {
            return 0;
        }
    }

    private static string? ExtractStartGuid(string? gameArgs)
    {
        if (string.IsNullOrEmpty(gameArgs)) return null;
        string[] tokens = gameArgs.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        for (int i = 0; i < tokens.Length - 1; i++)
        {
            if (string.Equals(tokens[i], "--start", StringComparison.OrdinalIgnoreCase))
            {
                string candidate = tokens[i + 1].Trim('"');
                if (Guid.TryParse(candidate, out _))
                    return candidate;
            }
        }
        return null;
    }

    private static string? ResolvePipeEndpoint(string gameExe)
    {
        string? installDir = Path.GetDirectoryName(gameExe);
        if (string.IsNullOrEmpty(installDir)) return null;

        string configPath = Path.Combine(installDir, "common.config");
        string? baseEndpoint = DefaultPipeEndpoint;
        if (File.Exists(configPath))
        {
            try
            {
                var doc = new XmlDocument();
                doc.Load(configPath);
                var nodes = doc.SelectNodes("//add[@key='" + PipeEndpointKey + "']");
                if (nodes != null)
                {
                    foreach (XmlNode n in nodes)
                    {
                        var v = n.Attributes?["value"]?.Value;
                        if (!string.IsNullOrWhiteSpace(v))
                        {
                            baseEndpoint = v.Trim();
                            break;
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Log($"ResolvePipeEndpoint config parse failed: {ex.Message}");
            }
        }

        return baseEndpoint!.TrimEnd('/') + "/PlayniteService";
    }

    private static void WriteResult(bool ok, uint pid, string? error, bool forwarded = false)
    {
        var payload = new Dictionary<string, object?>
        {
            ["ok"] = ok,
            ["pid"] = pid,
            ["error"] = error,
            ["forwarded"] = forwarded
        };
        string json = JsonSerializer.Serialize(payload);
        Log($"stdout JSON: {json}");
        Console.Out.WriteLine(json);
        Console.Out.Flush();
    }

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(LogDir);
            string line = $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}{Environment.NewLine}";
            File.AppendAllText(LogPath, line);
        }
        catch
        {
        }
    }

    [ServiceContract]
    private interface IPlaynitePipeService
    {
        [OperationContract(IsOneWay = true)]
        void InvokeCommand(PlayniteCmdlineCommand command, string args);
    }

    private enum PlayniteCmdlineCommand
    {
        None = 0,
        Start = 1,
        SwitchMode = 2,
        Shutdown = 3,
        Focus = 4,
        UriRequest = 5,
        ExtensionInstall = 6,
        BackupData = 7,
        RestoreBackup = 8,
    }
}
