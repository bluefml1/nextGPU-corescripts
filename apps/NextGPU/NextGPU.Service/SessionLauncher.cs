using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;

namespace NextGPU.Service;

public sealed class SessionLauncher
{
    private readonly ILogger<SessionLauncher> _log;

    public SessionLauncher(ILogger<SessionLauncher> log)
    {
        _log = log;
    }

    // Launches the app in the specified user session. If preferredSessionId is 0,
    // the nextGPU streaming session is resolved (not "first Active", which may be Authority).
    public LaunchResult LaunchInSession(ResolvedApp app, uint preferredSessionId = 0)
    {
        uint sessionId = preferredSessionId;
        uint sessionState = 0;

        if (sessionId == 0)
        {
            if (!LaunchInterop.FindSessionIdByUserName(
                    LaunchInterop.StreamingUserName,
                    out sessionId,
                    out sessionState))
            {
                _log.LogError("No session found for streaming user {User}", LaunchInterop.StreamingUserName);
                return new LaunchResult
                {
                    Ok = false,
                    Error = $"No session found for {LaunchInterop.StreamingUserName}"
                };
            }
        }

        if (sessionId == 0)
        {
            _log.LogError("No active console session found");
            return new LaunchResult { Ok = false, Error = "No active console session" };
        }

        if (!LaunchInterop.WTSQueryUserToken(sessionId, out IntPtr hUserToken))
        {
            int err = Marshal.GetLastWin32Error();
            _log.LogError("WTSQueryUserToken failed for session {SessionId}, error {Error}", sessionId, err);
            return new LaunchResult { Ok = false, Error = $"WTSQueryUserToken failed: session {sessionId} error {err}" };
        }

        try
        {
            var pi = LaunchInSessionCore(hUserToken, app, sessionId);
            if (pi.hProcess == IntPtr.Zero)
            {
                return new LaunchResult { Ok = false, Error = "CreateProcessAsUserW failed" };
            }

            uint pid = pi.dwProcessId;
            _log.LogInformation(
                "Launched non-elevated process {Exe} (PID {Pid}). SessionId = {SessionId}; State = {State}; Username = {Username}",
                app.Exe,
                pid,
                sessionId,
                LaunchInterop.FormatWtsState(sessionState),
                LaunchInterop.StreamingUserName);
            return new LaunchResult { Ok = true, Pid = pid };
        }
        finally
        {
            LaunchInterop.FreeToken(ref hUserToken);
        }
    }

    private LaunchInterop.PROCESS_INFORMATION LaunchInSessionCore(IntPtr hUserToken, ResolvedApp app, uint sessionId)
    {
        LaunchInterop.STARTUPINFO si = new LaunchInterop.STARTUPINFO
        {
            dwFlags = LaunchInterop.STARTF_USESHOWWINDOW,
            wShowWindow = LaunchInterop.SW_SHOW
        };

        string? env = null;

        string cmdLine;
        if (string.IsNullOrEmpty(app.Args))
        {
            cmdLine = $"\"{app.Exe}\"";
        }
        else
        {
            // lpCommandLine must include the executable; quote it so paths with spaces work.
            cmdLine = $"\"{app.Exe}\" {app.Args}";
        }

        bool ok = LaunchInterop.CreateProcessAsUserW(
            hUserToken,
            null,
            cmdLine,
            IntPtr.Zero,
            IntPtr.Zero,
            false,
            LaunchInterop.NORMAL_PRIORITY_CLASS,
            env,
            string.IsNullOrEmpty(app.WorkingDir) ? null : app.WorkingDir,
            ref si,
            out LaunchInterop.PROCESS_INFORMATION pi);

        if (!ok)
        {
            _log.LogError("CreateProcessAsUserW failed for {Exe} in session {SessionId}, error {Error}",
                app.Exe, sessionId, Marshal.GetLastWin32Error());
            pi = new LaunchInterop.PROCESS_INFORMATION();
        }

        return pi;
    }
}
