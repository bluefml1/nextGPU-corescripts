using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace NextGPU.Service;

/// <summary>
/// Starts helper processes that must run alongside an elevated app, as the same
/// NextGPU-Admin account in the streaming user's session (e.g. Garena.exe needs
/// gxxapphelper.exe). Config: %ProgramData%\nextGPU\launch-companions.json
///
///   { "companions": { "Garena.exe": [ { "exeName": "gxxapphelper.exe", "exe": "...", "searchDir": "...", "delayMs": 2000 } ] } }
///
/// The file is re-read on every elevated launch; missing file = no companions.
/// Entries run as NextGPU-Admin, so the file is ignored unless only SYSTEM /
/// Administrators / TrustedInstaller own it and can write it.
/// </summary>
public sealed class LaunchCompanionService
{
    private const int MaxDelayMs = 2000;
    private const int SlowWarningMs = 15_000;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true
    };

    private readonly ILogger<LaunchCompanionService> _log;
    private readonly ElevatedLauncher _elevatedLauncher;
    private readonly CredentialService _credentialService;
    private readonly string _configPath;
    // Pipe connections are handled concurrently; serialize check+launch+delay so two
    // near-simultaneous launches cannot both start a companion.
    private readonly object _gate = new();

    public LaunchCompanionService(
        ILogger<LaunchCompanionService> log,
        ElevatedLauncher elevatedLauncher,
        CredentialService credentialService)
    {
        _log = log;
        _elevatedLauncher = elevatedLauncher;
        _credentialService = credentialService;
        _configPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "nextGPU", "launch-companions.json");
    }

    public void EnsureCompanions(ResolvedApp mainApp)
    {
        try
        {
            string mainName = Path.GetFileName(mainApp.Exe);
            if (string.IsNullOrEmpty(mainName))
                return;

            List<CompanionEntry> entries = LoadEntries(mainName);
            if (entries.Count == 0)
                return;

            lock (_gate)
            {
                var sw = Stopwatch.StartNew();
                foreach (CompanionEntry entry in entries)
                {
                    EnsureOne(mainName, entry);
                }
                sw.Stop();
                if (sw.ElapsedMilliseconds > SlowWarningMs)
                {
                    _log.LogWarning(
                        "Companions for {Main} took {Ms} ms; pipe clients time out at 60 s",
                        mainName, sw.ElapsedMilliseconds);
                }
            }
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Companion launch failed for {Exe}; continuing with main launch", mainApp.Exe);
        }
    }

    private void EnsureOne(string mainName, CompanionEntry entry)
    {
        string? exe = ResolveCompanionPath(entry);
        if (exe == null)
        {
            _log.LogWarning(
                "Companion for {Main} not found (exeName={ExeName}, exe={Exe}, searchDir={SearchDir}); skipping",
                mainName, entry.ExeName ?? "(none)", entry.Exe ?? "(none)", entry.SearchDir ?? "(none)");
            return;
        }

        string processName = Path.GetFileNameWithoutExtension(exe);
        if (IsRunningAsAdminInStreamingSession(processName, out uint existingPid))
        {
            _log.LogInformation(
                "Companion already running for {Main}: {Name} PID {Pid}",
                mainName, processName, existingPid);
            return;
        }

        _log.LogInformation("Starting companion for {Main}: {Exe}", mainName, exe);
        LaunchResult result = _elevatedLauncher.LaunchElevated(new ResolvedApp
        {
            Exe = exe,
            WorkingDir = Path.GetDirectoryName(exe) ?? "",
            RunAsAdmin = true
        });

        if (!result.Ok)
        {
            _log.LogWarning("Companion {Exe} failed to start: {Error}", exe, result.Error);
            return;
        }

        _log.LogInformation("Companion {Name} started PID {Pid}", processName, result.Pid);
        int delay = Math.Clamp(entry.DelayMs ?? MaxDelayMs, 0, MaxDelayMs);
        if (delay > 0)
            Thread.Sleep(delay);
    }

    private List<CompanionEntry> LoadEntries(string mainName)
    {
        var none = new List<CompanionEntry>();
        if (!File.Exists(_configPath))
            return none;

        if (!IsConfigTrusted(_configPath, out string reason))
        {
            _log.LogWarning(
                "Ignoring {Path}: {Reason}. Re-save it from NextGPU Service > Launch Companions (admin-only ACL).",
                _configPath, reason);
            return none;
        }

        CompanionConfig? config;
        try
        {
            config = JsonSerializer.Deserialize<CompanionConfig>(File.ReadAllText(_configPath), JsonOptions);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Could not parse {Path}", _configPath);
            return none;
        }

        if (config?.Companions == null)
            return none;

        foreach (var kv in config.Companions)
        {
            if (string.Equals(kv.Key, mainName, StringComparison.OrdinalIgnoreCase))
                return kv.Value?.Where(e => e != null).ToList() ?? none;
        }
        return none;
    }

    private string? ResolveCompanionPath(CompanionEntry entry)
    {
        if (!string.IsNullOrWhiteSpace(entry.Exe) && File.Exists(entry.Exe))
            return entry.Exe;

        if (string.IsNullOrWhiteSpace(entry.SearchDir) || !Directory.Exists(entry.SearchDir))
            return null;

        string fileName = !string.IsNullOrWhiteSpace(entry.ExeName)
            ? Path.GetFileName(entry.ExeName.Trim())
            : !string.IsNullOrWhiteSpace(entry.Exe)
                ? Path.GetFileName(entry.Exe)
                : "";
        if (string.IsNullOrEmpty(fileName))
            return null;

        try
        {
            string? found = Directory
                .EnumerateFiles(entry.SearchDir, fileName, new EnumerationOptions
                {
                    RecurseSubdirectories = true,
                    IgnoreInaccessible = true,
                    MatchCasing = MatchCasing.CaseInsensitive
                })
                .FirstOrDefault();
            if (found != null)
            {
                _log.LogInformation(
                    "Companion {File} not at {Saved}; found under searchDir: {Found}",
                    fileName, entry.Exe, found);
            }
            return found;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Companion search failed under {Dir}", entry.SearchDir);
            return null;
        }
    }

    private static readonly SecurityIdentifier[] TrustedSids =
    [
        new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
        new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
        new SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464") // TrustedInstaller
    ];

    // Rights that let a principal change what the file says or who controls it.
    // Raw generic bits are included because ACEs may carry them unmapped.
    private const int DangerousRightsMask =
        (int)(FileSystemRights.WriteData | FileSystemRights.AppendData |
              FileSystemRights.ChangePermissions | FileSystemRights.TakeOwnership) |
        0x40000000 /* GENERIC_WRITE */ | 0x10000000 /* GENERIC_ALL */;

    internal static bool IsConfigTrusted(string path, out string reason)
    {
        reason = "";
        FileSecurity security;
        try
        {
            security = new FileInfo(path).GetAccessControl(AccessControlSections.Owner | AccessControlSections.Access);
        }
        catch (Exception ex)
        {
            reason = "cannot read ACL: " + ex.Message;
            return false;
        }

        if (security.GetOwner(typeof(SecurityIdentifier)) is not SecurityIdentifier owner ||
            !TrustedSids.Contains(owner))
        {
            reason = "owner is not SYSTEM/Administrators";
            return false;
        }

        foreach (FileSystemAccessRule rule in security.GetAccessRules(true, true, typeof(SecurityIdentifier)))
        {
            if (rule.AccessControlType != AccessControlType.Allow)
                continue;
            if ((rule.PropagationFlags & PropagationFlags.InheritOnly) != 0)
                continue;
            if (rule.IdentityReference is SecurityIdentifier sid && TrustedSids.Contains(sid))
                continue;
            if (((int)rule.FileSystemRights & DangerousRightsMask) == 0)
                continue;

            reason = $"{rule.IdentityReference.Value} can write it ({rule.FileSystemRights})";
            return false;
        }

        return true;
    }

    private bool IsRunningAsAdminInStreamingSession(string processName, out uint pid)
    {
        pid = 0;
        if (!LaunchInterop.FindSessionIdByUserName(LaunchInterop.StreamingUserName, out uint sessionId, out _))
            return false;

        SecurityIdentifier adminSid;
        try
        {
            adminSid = (SecurityIdentifier)new NTAccount(_credentialService.AdminUsername)
                .Translate(typeof(SecurityIdentifier));
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Could not resolve SID for {Admin}", _credentialService.AdminUsername);
            return false;
        }

        foreach (Process p in Process.GetProcessesByName(processName))
        {
            using (p)
            {
                if ((uint)p.SessionId != sessionId)
                    continue;

                SecurityIdentifier? owner = TryGetProcessOwnerSid((uint)p.Id);
                if (owner != null && owner.Equals(adminSid))
                {
                    pid = (uint)p.Id;
                    return true;
                }
            }
        }
        return false;
    }

    private static SecurityIdentifier? TryGetProcessOwnerSid(uint processId)
    {
        IntPtr hProcess = LaunchInterop.OpenProcess(LaunchInterop.PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (hProcess == IntPtr.Zero)
            return null;

        IntPtr hToken = IntPtr.Zero;
        IntPtr buffer = IntPtr.Zero;
        try
        {
            if (!LaunchInterop.OpenProcessToken(hProcess, LaunchInterop.TOKEN_QUERY, out hToken))
                return null;

            if (!WindowStationAccess.TryGetTokenUserSid(hToken, out IntPtr pSid, out buffer, out _))
                return null;

            return new SecurityIdentifier(pSid);
        }
        catch
        {
            return null;
        }
        finally
        {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            if (hToken != IntPtr.Zero) LaunchInterop.CloseHandle(hToken);
            LaunchInterop.CloseHandle(hProcess);
        }
    }

    private sealed class CompanionConfig
    {
        public Dictionary<string, List<CompanionEntry>?>? Companions { get; set; }
    }

    private sealed class CompanionEntry
    {
        public string? ExeName { get; set; }
        public string? Exe { get; set; }
        public string? SearchDir { get; set; }
        public int? DelayMs { get; set; }
    }
}
