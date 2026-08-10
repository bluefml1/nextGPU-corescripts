using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace NextGPU.Service;

/// <summary>
/// Elevated launch into the streaming user's interactive session:
///
///   WTSQueryUserToken(session) → CreateProcessAsUser(Launcher --as-admin)
///     [service writes Admin password on stdin]
///   → Launcher CreateProcessWithLogonW(NextGPU-Admin) → game on same desktop
///
/// Why not LogonUser(Admin)+SetTokenSessionId: that token lacks the session Logon
/// SID, so Electron dies with 0x80000003 on winsta0\default. CreateProcessWithLogonW
/// from an in-session broker inherits the caller's interactive desktop.
/// </summary>
public sealed class ElevatedLauncher
{
    private const int SessionWaitTimeoutMs = 60_000;
    private const int SessionWaitPollMs = 500;
    private const uint LauncherWaitMs = 45_000;
    private const string LauncherFileName = "NextGPU.Launcher.exe";

    private readonly ILogger<ElevatedLauncher> _log;
    private readonly CredentialService _credentialService;

    public ElevatedLauncher(ILogger<ElevatedLauncher> log, CredentialService credentialService)
    {
        _log = log;
        _credentialService = credentialService;
    }

    public LaunchResult LaunchElevated(ResolvedApp app)
    {
        try
        {
            return LaunchElevatedCore(app);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Unhandled exception in LaunchElevated for {Exe}", app.Exe);
            return new LaunchResult { Ok = false, Error = $"Unhandled: {ex.Message}" };
        }
    }

    private LaunchResult LaunchElevatedCore(ResolvedApp app)
    {
        if (!WaitForStreamingUserSession(
                out uint resolvedSessionId,
                out uint sessionState,
                out IntPtr hUserToken,
                out int wtsErr))
        {
            _log.LogError(
                "Timed out waiting for {User} session token, last error {Error}",
                LaunchInterop.StreamingUserName, wtsErr);
            return new LaunchResult
            {
                Ok = false,
                Error = $"Timed out waiting for {LaunchInterop.StreamingUserName} session (WTS error {wtsErr})"
            };
        }

        string stateName = LaunchInterop.FormatWtsState(sessionState);
        _log.LogInformation(
            "SessionId = {SessionId}; State = {State}; Username = {Username}; AdminAccount = {AdminAccount}; Mode = CreateProcessWithLogonW-broker",
            resolvedSessionId,
            stateName,
            LaunchInterop.StreamingUserName,
            _credentialService.AdminUsername);

        string? adminPassword = _credentialService.ReadAdminPassword();
        if (string.IsNullOrEmpty(adminPassword))
        {
            LaunchInterop.FreeToken(ref hUserToken);
            return new LaunchResult { Ok = false, Error = "Failed to read admincred.dat (DPAPI unprotect failed)" };
        }

        string? launcherPath = ResolveLauncherPath();
        if (launcherPath == null)
        {
            LaunchInterop.FreeToken(ref hUserToken);
            return new LaunchResult
            {
                Ok = false,
                Error = $"Launcher not found (expected under Program Files\\NextGPU\\Launcher\\{LauncherFileName})"
            };
        }

        LaunchInterop.PROCESS_INFORMATION pi = default;
        IntPtr stdoutRead = IntPtr.Zero;
        IntPtr stdoutWrite = IntPtr.Zero;
        IntPtr stdinRead = IntPtr.Zero;
        IntPtr stdinWrite = IntPtr.Zero;

        try
        {
            string launchExe = app.Exe;
            if (!File.Exists(launchExe) && !launchExe.Contains("://", StringComparison.Ordinal))
            {
                string volumeExe = LaunchInterop.ResolvePathForCrossSession(app.Exe);
                if (!string.Equals(volumeExe, app.Exe, StringComparison.OrdinalIgnoreCase) &&
                    File.Exists(volumeExe))
                {
                    launchExe = volumeExe;
                }
            }

            string? resolvedWorkDir = null;
            string? cwdCandidate = !string.IsNullOrEmpty(app.WorkingDir)
                ? app.WorkingDir
                : Path.GetDirectoryName(app.Exe);
            if (!string.IsNullOrEmpty(cwdCandidate))
            {
                try
                {
                    string fullCwd = Path.GetFullPath(cwdCandidate);
                    if (!fullCwd.StartsWith(@"\\?\", StringComparison.Ordinal) &&
                        Directory.Exists(fullCwd))
                    {
                        resolvedWorkDir = fullCwd;
                    }
                }
                catch
                {
                    // fall through
                }
            }

            string launcherCmd = BuildLauncherCommandLine(launcherPath, launchExe, app.Args, resolvedWorkDir);
            _log.LogInformation("Broker (session-user) launcher: {Cmd}", launcherCmd);
            _log.LogDebug("Game exe: {Exe}", launchExe);
            _log.LogDebug("Game working dir: {Dir}", resolvedWorkDir ?? "(none)");

            var sa = new LaunchInterop.SECURITY_ATTRIBUTES
            {
                nLength = Marshal.SizeOf<LaunchInterop.SECURITY_ATTRIBUTES>(),
                bInheritHandle = true,
                lpSecurityDescriptor = IntPtr.Zero
            };

            if (!LaunchInterop.CreatePipe(out stdoutRead, out stdoutWrite, ref sa, 0))
                return new LaunchResult { Ok = false, Error = $"CreatePipe(stdout) failed: {Marshal.GetLastWin32Error()}" };
            if (!LaunchInterop.SetHandleInformation(stdoutRead, LaunchInterop.HANDLE_FLAG_INHERIT, 0))
                return new LaunchResult { Ok = false, Error = $"SetHandleInformation(stdoutRead) failed: {Marshal.GetLastWin32Error()}" };

            if (!LaunchInterop.CreatePipe(out stdinRead, out stdinWrite, ref sa, 0))
                return new LaunchResult { Ok = false, Error = $"CreatePipe(stdin) failed: {Marshal.GetLastWin32Error()}" };
            // Child inherits stdin READ; parent keeps WRITE (must not be inherited).
            if (!LaunchInterop.SetHandleInformation(stdinWrite, LaunchInterop.HANDLE_FLAG_INHERIT, 0))
                return new LaunchResult { Ok = false, Error = $"SetHandleInformation(stdinWrite) failed: {Marshal.GetLastWin32Error()}" };

            var si = new LaunchInterop.STARTUPINFO
            {
                cb = (uint)Marshal.SizeOf<LaunchInterop.STARTUPINFO>(),
                lpDesktop = "",
                dwFlags = LaunchInterop.STARTF_USESHOWWINDOW
                    | LaunchInterop.STARTF_FORCEONFEEDBACK
                    | LaunchInterop.STARTF_USESTDHANDLES,
                wShowWindow = 0,
                hStdInput = stdinRead,
                hStdOutput = stdoutWrite,
                hStdError = stdoutWrite
            };

            bool ok = LaunchInterop.CreateProcessAsUserW(
                hUserToken,
                null,
                launcherCmd,
                IntPtr.Zero,
                IntPtr.Zero,
                true,
                LaunchInterop.NORMAL_PRIORITY_CLASS | LaunchInterop.CREATE_NO_WINDOW,
                (string?)null,
                Path.GetDirectoryName(launcherPath),
                ref si,
                out pi);

            // Parent no longer needs child ends of pipes.
            LaunchInterop.CloseHandle(stdoutWrite);
            stdoutWrite = IntPtr.Zero;
            LaunchInterop.CloseHandle(stdinRead);
            stdinRead = IntPtr.Zero;

            if (!ok)
            {
                int err = Marshal.GetLastWin32Error();
                _log.LogError("CreateProcessAsUserW(session-user launcher) failed, error {Error}", err);
                return new LaunchResult
                {
                    Ok = false,
                    Error = $"CreateProcessAsUserW(session-user launcher) failed: {err}"
                };
            }

            uint launcherPid = pi.dwProcessId;
            LaunchInterop.ProcessIdToSessionId(launcherPid, out uint actualSessionId);
            _log.LogInformation(
                "Session-user launcher started PID {Pid} session {Session}: {Diag}",
                launcherPid,
                actualSessionId,
                LaunchInterop.FormatProcessDiagnostics(pi.hProcess, launcherPid));

            // Deliver Admin password on stdin; launcher reads one line then elevates.
            byte[] pwdBytes = Encoding.UTF8.GetBytes(adminPassword + "\n");
            if (!WriteFileAll(stdinWrite, pwdBytes))
            {
                int err = Marshal.GetLastWin32Error();
                return new LaunchResult { Ok = false, Error = $"WriteFile(stdin password) failed: {err}" };
            }
            LaunchInterop.CloseHandle(stdinWrite);
            stdinWrite = IntPtr.Zero;

            string stdoutText = ReadPipeToEnd(stdoutRead, LauncherWaitMs, pi.hProcess);

            LaunchInterop.GetExitCodeProcess(pi.hProcess, out uint launcherExit);
            _log.LogInformation(
                "Launcher finished exit={Exit}: {Diag}",
                launcherExit,
                LaunchInterop.FormatProcessDiagnostics(pi.hProcess, launcherPid));
            _log.LogInformation("Launcher stdout ({Len} chars): {Stdout}", stdoutText?.Length ?? 0, Truncate(stdoutText ?? "", 500));
            _log.LogInformation(
                "Check also: C:\\ProgramData\\nextGPU\\logs\\launcher.log, launcher.err.log");

            if (!TryParseLauncherResult(stdoutText, out bool childOk, out uint gamePid, out string? childError))
            {
                return new LaunchResult
                {
                    Ok = false,
                    Pid = launcherPid,
                    Error = $"Launcher produced no JSON result (exit={launcherExit}). stdout={Truncate(stdoutText ?? "", 200)}"
                };
            }

            if (!childOk)
            {
                return new LaunchResult
                {
                    Ok = false,
                    Pid = gamePid,
                    Error = childError ?? $"Launcher reported failure (exit={launcherExit})"
                };
            }

            string gameDiag = "(no game pid)";
            if (gamePid != 0)
            {
                try
                {
                    using var gameProc = System.Diagnostics.Process.GetProcessById((int)gamePid);
                    bool exited = false;
                    try { exited = gameProc.HasExited; } catch { }
                    LaunchInterop.ProcessIdToSessionId(gamePid, out uint gameSess);
                    gameDiag = $"alive={!exited} name={gameProc.ProcessName} session={gameSess}";
                }
                catch (Exception ex)
                {
                    gameDiag = $"GetProcessById failed: {ex.GetType().Name}: {ex.Message}";
                }
            }

            _log.LogInformation(
                "Elevated broker ok. LauncherPid={LauncherPid}; GamePid={GamePid}; GameDiag={GameDiag}; TargetSessionId={SessionId}; AdminAccount={Admin}",
                launcherPid,
                gamePid,
                gameDiag,
                resolvedSessionId,
                _credentialService.AdminUsername);

            return new LaunchResult { Ok = true, Pid = gamePid };
        }
        finally
        {
            if (!string.IsNullOrEmpty(adminPassword))
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

            if (stdinWrite != IntPtr.Zero) LaunchInterop.CloseHandle(stdinWrite);
            if (stdinRead != IntPtr.Zero) LaunchInterop.CloseHandle(stdinRead);
            if (stdoutWrite != IntPtr.Zero) LaunchInterop.CloseHandle(stdoutWrite);
            if (stdoutRead != IntPtr.Zero) LaunchInterop.CloseHandle(stdoutRead);

            LaunchInterop.FreeToken(ref hUserToken);

            if (pi.hThread != IntPtr.Zero) LaunchInterop.CloseHandle(pi.hThread);
            if (pi.hProcess != IntPtr.Zero) LaunchInterop.CloseHandle(pi.hProcess);
        }
    }

    private static bool WriteFileAll(IntPtr hFile, byte[] data)
    {
        int offset = 0;
        while (offset < data.Length)
        {
            // Reuse ReadFile buffer pattern via WriteFile PInvoke below.
            uint toWrite = (uint)(data.Length - offset);
            byte[] chunk = data;
            if (offset > 0)
            {
                chunk = new byte[toWrite];
                Buffer.BlockCopy(data, offset, chunk, 0, (int)toWrite);
            }

            if (!WriteFile(hFile, chunk, (uint)chunk.Length, out uint written, IntPtr.Zero))
                return false;
            if (written == 0)
                return false;
            offset += (int)written;
        }
        return true;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteFile(
        IntPtr hFile,
        byte[] lpBuffer,
        uint nNumberOfBytesToWrite,
        out uint lpNumberOfBytesWritten,
        IntPtr lpOverlapped);

    private static string BuildLauncherCommandLine(
        string launcherPath,
        string gameExe,
        string gameArgs,
        string? cwd)
    {
        var sb = new StringBuilder();
        sb.Append('"').Append(launcherPath).Append('"');
        sb.Append(" --as-admin");
        if (!string.IsNullOrEmpty(cwd))
        {
            sb.Append(" --cwd \"").Append(cwd).Append('"');
        }
        sb.Append(" -- \"").Append(gameExe).Append('"');
        if (!string.IsNullOrEmpty(gameArgs))
        {
            sb.Append(' ').Append(gameArgs);
        }
        return sb.ToString();
    }

    private static string? ResolveLauncherPath()
    {
        string programmed = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            "NextGPU", "Launcher", LauncherFileName);
        if (File.Exists(programmed))
            return programmed;

        string? serviceDir = Path.GetDirectoryName(Environment.ProcessPath);
        if (!string.IsNullOrEmpty(serviceDir))
        {
            string sibling = Path.GetFullPath(Path.Combine(serviceDir, "..", "Launcher", LauncherFileName));
            if (File.Exists(sibling))
                return sibling;

            string sameDir = Path.Combine(serviceDir, LauncherFileName);
            if (File.Exists(sameDir))
                return sameDir;
        }

        return null;
    }

    private static string ReadPipeToEnd(IntPtr hRead, uint waitMs, IntPtr hProcess)
    {
        LaunchInterop.WaitForSingleObject(hProcess, waitMs);

        var ms = new MemoryStream();
        var buf = new byte[4096];
        while (true)
        {
            if (!LaunchInterop.ReadFile(hRead, buf, (uint)buf.Length, out uint read, IntPtr.Zero))
                break;
            if (read == 0)
                break;
            ms.Write(buf, 0, (int)read);
        }

        return Encoding.UTF8.GetString(ms.ToArray()).Trim();
    }

    private static bool TryParseLauncherResult(
        string? stdout,
        out bool ok,
        out uint pid,
        out string? error)
    {
        ok = false;
        pid = 0;
        error = null;

        if (string.IsNullOrWhiteSpace(stdout))
            return false;

        // Stdout may contain stderr noise mixed in if pipes were shared historically;
        // find the last JSON object line.
        string? jsonLine = null;
        foreach (string line in stdout.Split('\n'))
        {
            string t = line.Trim();
            if (t.StartsWith('{') && t.Contains("\"ok\"", StringComparison.Ordinal))
                jsonLine = t;
        }

        if (jsonLine == null)
            return false;

        try
        {
            using var doc = JsonDocument.Parse(jsonLine);
            var root = doc.RootElement;
            ok = root.TryGetProperty("ok", out var okEl) && okEl.GetBoolean();
            if (root.TryGetProperty("pid", out var pidEl) && pidEl.TryGetUInt32(out uint p))
                pid = p;
            if (root.TryGetProperty("error", out var errEl) && errEl.ValueKind == JsonValueKind.String)
                error = errEl.GetString();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static string Truncate(string s, int max)
        => string.IsNullOrEmpty(s) ? "" : (s.Length <= max ? s : s[..max] + "...");

    private bool WaitForStreamingUserSession(
        out uint sessionId,
        out uint sessionState,
        out IntPtr hUserToken,
        out int lastError)
    {
        sessionId = 0;
        sessionState = 0;
        hUserToken = IntPtr.Zero;
        lastError = 0;

        var deadline = DateTime.UtcNow.AddMilliseconds(SessionWaitTimeoutMs);
        while (DateTime.UtcNow < deadline)
        {
            if (LaunchInterop.FindSessionIdByUserName(
                    LaunchInterop.StreamingUserName,
                    out uint foundId,
                    out uint foundState))
            {
                if (LaunchInterop.WTSQueryUserToken(foundId, out hUserToken))
                {
                    sessionId = foundId;
                    sessionState = foundState;
                    lastError = 0;
                    return true;
                }

                lastError = Marshal.GetLastWin32Error();
                _log.LogDebug(
                    "WTSQueryUserToken failed for {User} session {SessionId} (state {State}), error {Error} — retrying",
                    LaunchInterop.StreamingUserName,
                    foundId,
                    LaunchInterop.FormatWtsState(foundState),
                    lastError);
            }
            else
            {
                lastError = 0;
                _log.LogDebug("Session for {User} not found yet — retrying", LaunchInterop.StreamingUserName);
            }

            System.Threading.Thread.Sleep(SessionWaitPollMs);
        }

        return false;
    }
}
