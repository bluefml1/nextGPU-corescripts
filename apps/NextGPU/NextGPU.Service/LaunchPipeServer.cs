using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;
using Timer = System.Threading.Timer;

namespace NextGPU.Service;

public sealed class LaunchPipeServer : IDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true
    };
    private const string PipeName = "NextGPUControl";
    private const int BufferSize = 64 * 1024;
    private const int MaxServerInstances = NamedPipeServerStream.MaxAllowedServerInstances;

    private readonly ILogger<LaunchPipeServer> _log;
    private readonly AllowlistService _allowlistService;
    private readonly SessionLauncher _sessionLauncher;
    private readonly ElevatedLauncher _elevatedLauncher;
    private readonly Dictionary<int, (DateTime Time, uint Pid)> _dedupWindow = new();
    private readonly object _dedupLock = new();
    private readonly Timer _dedupCleanup;
    private readonly CancellationTokenSource _cts = new();
    private bool _disposed;

    public LaunchPipeServer(
        ILogger<LaunchPipeServer> log,
        AllowlistService allowlistService,
        SessionLauncher sessionLauncher,
        ElevatedLauncher elevatedLauncher)
    {
        _log = log;
        _allowlistService = allowlistService;
        _sessionLauncher = sessionLauncher;
        _elevatedLauncher = elevatedLauncher;
        _dedupCleanup = new Timer(_ => CleanupDedup(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public async Task RunAsync(CancellationToken ct)
    {
        _log.LogInformation("LaunchPipeServer starting on \\\\.\\pipe\\{PipeName}", PipeName);

        NamedPipeServerStream? currentPipe = null;

        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (currentPipe == null)
                {
                    currentPipe = CreatePipeServer();
                }

                var pendingAr = currentPipe.BeginWaitForConnection(null!, null);

                await Task.Factory.FromAsync(pendingAr, _ => { }, TaskCreationOptions.None);

                currentPipe.EndWaitForConnection(pendingAr);
                _log.LogDebug("Client connected");

                var pipeToHandle = currentPipe;
                currentPipe = null;
                _ = Task.Run(() => HandleConnection(pipeToHandle), ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (IOException ex) when (ex.Message.Contains("busy") || ex.Message.Contains("All pipe instances"))
            {
                _log.LogDebug("Pipe slot busy, retrying...");
                currentPipe?.Dispose();
                currentPipe = null;
                await Task.Delay(50, ct);
            }
            catch (Exception ex)
            {
                _log.LogError(ex, "Error in pipe accept loop");
                currentPipe?.Dispose();
                currentPipe = null;
                await Task.Delay(500, ct);
            }
        }

        currentPipe?.Dispose();
    }

    /// <summary>
    /// Create the pipe with SY + BA + BU via PipeSecurity at create time.
    /// Post-create SetKernelObjectSecurity previously failed (ACCESS_DENIED) and left
    /// a default ACL that could block nextGPU (Playnite elevate wrapper).
    /// </summary>
    private NamedPipeServerStream CreatePipeServer()
    {
        LaunchInterop.EnsureInitialized();

        var security = new PipeSecurity();
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            PipeAccessRights.FullControl,
            AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinUsersSid, null),
            PipeAccessRights.ReadWrite | PipeAccessRights.CreateNewInstance,
            AccessControlType.Allow));

        var pipe = NamedPipeServerStreamAcl.Create(
            PipeName,
            PipeDirection.InOut,
            MaxServerInstances,
            PipeTransmissionMode.Message,
            PipeOptions.Asynchronous,
            BufferSize,
            BufferSize,
            security);

        _log.LogInformation("Pipe ACL set at create: SYSTEM + Administrators + Users");
        return pipe;
    }

    private void HandleConnection(NamedPipeServerStream pipe)
    {
        try
        {
            uint length = ReadUInt32(pipe);
            if (length == 0 || length > BufferSize)
            {
                _log.LogWarning("Invalid message length: {Length}", length);
                return;
            }

            byte[] buffer = new byte[length];
            int totalRead = 0;
            while (totalRead < length)
            {
                int read = pipe.Read(buffer, totalRead, (int)length - totalRead);
                if (read == 0) return;
                totalRead += read;
            }

            string json = Encoding.UTF8.GetString(buffer, 0, totalRead);
            _log.LogDebug("Received: {Json}", json);

            var request = JsonSerializer.Deserialize<PipeRequest>(json, JsonOptions);
            if (request == null)
            {
                SendResponse(pipe, new PipeResponse { Version = 1, Ok = false, Error = "invalid request" });
                return;
            }

            var response = ProcessRequest(request);
            SendResponse(pipe, response);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Error handling pipe connection");
        }
        finally
        {
            try { pipe.Dispose(); } catch { }
        }
    }

    private PipeResponse ProcessRequest(PipeRequest request)
    {
        if (request.Version != 1)
            return new PipeResponse { Version = 1, Ok = false, Error = "unsupported protocol version" };

        if (request.Op == "ping")
        {
            _log.LogDebug("Ping received");
            return new PipeResponse { Version = 1, Ok = true };
        }

        if (request.Op == "launch" || request.Op == "launch-elevated")
        {
            return HandleLaunch(request);
        }

        return new PipeResponse { Version = 1, Ok = false, Error = $"unknown op: {request.Op}" };
    }

    private PipeResponse HandleLaunch(PipeRequest request)
    {
        // Temporary / explicit exe override (e.g. Level Up smoke test) bypasses allowlist path.
        ResolvedApp? app;
        int appId = request.AppID ?? 0;
        if (!string.IsNullOrWhiteSpace(request.Exe))
        {
            string exe = request.Exe.Trim();
            string workingDir = string.IsNullOrWhiteSpace(request.WorkingDir)
                ? (Path.GetDirectoryName(exe) ?? "")
                : request.WorkingDir.Trim();
            app = new ResolvedApp
            {
                Exe = exe,
                Args = request.Args ?? "",
                WorkingDir = workingDir,
                RunAsAdmin = request.Op == "launch-elevated"
            };
            _log.LogInformation("Launch override exe={Exe} workingDir={Dir}", app.Exe, app.WorkingDir);
        }
        else
        {
            if (request.AppID == null)
                return new PipeResponse { Version = 1, Ok = false, Error = "appID required" };

            appId = request.AppID.Value;

            lock (_dedupLock)
            {
                if (_dedupWindow.TryGetValue(appId, out var existing) &&
                    (DateTime.UtcNow - existing.Time).TotalSeconds < 5)
                {
                    _log.LogInformation("Dedup hit for appID {AppId}, returning existing PID {Pid}", appId, existing.Pid);
                    return new PipeResponse { Version = 1, Ok = true, Pid = existing.Pid };
                }
            }

            app = _allowlistService.Map(appId);
            if (app == null)
            {
                _log.LogWarning("AppID {AppId} not found in allowlist", appId);
                return new PipeResponse { Version = 1, Ok = false, Error = $"appID {appId} not found" };
            }

            if (!string.IsNullOrEmpty(request.Args))
            {
                app = new ResolvedApp
                {
                    Exe = app.Exe,
                    Args = request.Args,
                    WorkingDir = string.IsNullOrEmpty(request.WorkingDir) ? app.WorkingDir : request.WorkingDir,
                    Kind = app.Kind,
                    RunAsAdmin = app.RunAsAdmin
                };
            }
            else if (!string.IsNullOrEmpty(request.WorkingDir))
            {
                app = new ResolvedApp
                {
                    Exe = app.Exe,
                    Args = app.Args,
                    WorkingDir = request.WorkingDir,
                    Kind = app.Kind,
                    RunAsAdmin = app.RunAsAdmin
                };
            }
        }

        LaunchResult result;
        bool wantsElevated = request.Op == "launch-elevated" || app.RunAsAdmin;

        if (wantsElevated)
        {
            result = _elevatedLauncher.LaunchElevated(app);
        }
        else
        {
            result = _sessionLauncher.LaunchInSession(app);
        }

        if (result.Ok)
        {
            if (appId != 0)
            {
                lock (_dedupLock)
                {
                    _dedupWindow[appId] = (DateTime.UtcNow, result.Pid);
                }
            }
            return new PipeResponse { Version = 1, Ok = true, Pid = result.Pid };
        }

        return new PipeResponse { Version = 1, Ok = false, Error = result.Error };
    }

    private static uint ReadUInt32(NamedPipeServerStream pipe)
    {
        byte[] lenBuf = new byte[4];
        int read = pipe.Read(lenBuf, 0, 4);
        if (read < 4) return 0;
        return BitConverter.ToUInt32(lenBuf, 0);
    }

    private static void SendResponse(NamedPipeServerStream pipe, PipeResponse response)
    {
        string json = JsonSerializer.Serialize(response, JsonOptions);
        byte[] jsonBytes = Encoding.UTF8.GetBytes(json);
        byte[] lenBytes = BitConverter.GetBytes(jsonBytes.Length);
        pipe.Write(lenBytes, 0, 4);
        pipe.Write(jsonBytes, 0, jsonBytes.Length);
        pipe.WaitForPipeDrain();
    }

    private void CleanupDedup()
    {
        lock (_dedupLock)
        {
            var cutoff = DateTime.UtcNow.AddSeconds(-10);
            var toRemove = _dedupWindow.Where(kv => kv.Value.Time < cutoff).Select(kv => kv.Key).ToList();
            foreach (var key in toRemove)
                _dedupWindow.Remove(key);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _cts.Cancel();
        _dedupCleanup.Dispose();
        _cts.Dispose();
    }
}

public sealed class PipeRequest
{
    public int Version { get; set; }
    public string? Op { get; set; }
    public int? AppID { get; set; }
    public string? Exe { get; set; }
    public string? Args { get; set; }
    public string? WorkingDir { get; set; }
}

public sealed class PipeResponse
{
    public int Version { get; set; } = 1;
    public bool Ok { get; set; }
    public uint Pid { get; set; }
    public string? Error { get; set; }
}
