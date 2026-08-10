using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.EventLog;
namespace NextGPU.Service;

public static partial class LaunchInterop
{
    public const uint LOGON32_LOGON_INTERACTIVE = 2;
    public const uint LOGON32_PROVIDER_WINNT50 = 3;

    [LibraryImport("advapi32.dll", EntryPoint = "LogonUserW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool LogonUser(
        string lpszUsername,
        string lpszDomain,
        string lpszPassword,
        uint dwLogonType,
        uint dwLogonProvider,
        out IntPtr phToken);

    [LibraryImport("advapi32.dll", EntryPoint = "DuplicateTokenEx", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DuplicateTokenEx(
        IntPtr hExistingToken,
        uint dwDesiredAccess,
        IntPtr lpTokenAttributes,
        SECURITY_IMPERSONATION_LEVEL ImpersonationLevel,
        TOKEN_TYPE TokenType,
        out IntPtr phNewToken);

    [LibraryImport("kernel32.dll", EntryPoint = "WTSGetActiveConsoleSessionId", SetLastError = true)]
    public static partial uint WTSGetActiveConsoleSessionId();

    [LibraryImport("wtsapi32.dll", EntryPoint = "WTSQueryUserToken", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool WTSQueryUserToken(
        uint SessionId,
        out IntPtr phUserToken);

    [LibraryImport("wtsapi32.dll", EntryPoint = "WTSEnumerateSessionsW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool WTSEnumerateSessionsW(
        IntPtr hServer,
        uint Reserved,
        uint Version,
        out IntPtr pSessionInfo,
        out uint pCount);

    [LibraryImport("wtsapi32.dll", EntryPoint = "WTSFreeMemory", SetLastError = false)]
    public static partial void WTSFreeMemory(IntPtr pMemory);

    [LibraryImport("wtsapi32.dll", EntryPoint = "WTSQuerySessionInformationW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool WTSQuerySessionInformationW(
        IntPtr hServer,
        uint SessionId,
        uint WTSInfoClass,
        out IntPtr ppBuffer,
        out uint pBytesReturned);

    [LibraryImport("advapi32.dll", EntryPoint = "ImpersonateLoggedOnUser", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ImpersonateLoggedOnUser(IntPtr hToken);

    [LibraryImport("advapi32.dll", EntryPoint = "RevertToSelf", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool RevertToSelf();

    public static IntPtr WTS_CURRENT_SERVER_HANDLE = IntPtr.Zero;
    public const uint WTS_SESSION_QUERY_LOCK = 0x0001;
    public const uint WTSActive = 0;
    public const uint WTSConnected = 1;
    public const uint WTSDisconnected = 4;
    public const uint WTSUserName = 5;

    // Streaming / Moonlight rental account whose interactive session receives elevated launches.
    public const string StreamingUserName = "nextGPU";

    public static string FormatWtsState(uint state) => state switch
    {
        0 => "Active",
        1 => "Connected",
        2 => "ConnectQuery",
        3 => "Shadow",
        4 => "Disconnected",
        5 => "Idle",
        6 => "Listen",
        7 => "Reset",
        8 => "Down",
        9 => "Init",
        _ => $"Unknown({state})"
    };

    [LibraryImport("advapi32.dll", EntryPoint = "CreateProcessAsUserW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CreateProcessAsUserW(
        IntPtr hToken,
        string? lpApplicationName,
        string? lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags,
        string? lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    // Overload accepting a raw environment block pointer (as returned by userenv!
    // CreateEnvironmentBlock). The Windows API expects lpEnvironment to be a
    // pointer to a Unicode environment block when CREATE_UNICODE_ENVIRONMENT is
    // set, so this overload must take IntPtr rather than string.
    // StringMarshalling.Utf16 is required — without it, lpApplicationName /
    // lpCommandLine / lpCurrentDirectory can be marshalled incorrectly and
    // CreateProcessAsUserW returns ERROR_FILE_NOT_FOUND (2).
    [LibraryImport("advapi32.dll", EntryPoint = "CreateProcessAsUserW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CreateProcessAsUserW(
        IntPtr hToken,
        string? lpApplicationName,
        string? lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [LibraryImport("advapi32.dll", EntryPoint = "CreateProcessWithLogonW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CreateProcessWithLogonW(
        string lpUsername,
        string lpDomain,
        string lpPassword,
        uint dwLogonFlags,
        string? lpApplicationName,
        string lpCommandLine,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string? lpCurrentDirectory,
        ref STARTUPINFO lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [LibraryImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AdjustTokenPrivileges(
        IntPtr TokenHandle,
        [MarshalAs(UnmanagedType.Bool)] bool DisableAllPrivileges,
        ref TOKEN_PRIVILEGES NewState,
        uint BufferLength,
        IntPtr PreviousState,
        IntPtr ReturnLength);

    [LibraryImport("kernel32.dll", EntryPoint = "CloseHandle", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CloseHandle(IntPtr hObject);

    // userenv.dll — builds/destroys environment blocks for a given token. Used by
    // ElevatedLauncher so that CreateProcessAsUserW can start the elevated process
    // with the admin's environment (USERPROFILE, AppData, PATH, etc.) rather than
    // inheriting the service's (or empty) environment.
    [LibraryImport("userenv.dll", EntryPoint = "CreateEnvironmentBlock", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool CreateEnvironmentBlock(
        out IntPtr lpEnvironment,
        IntPtr hToken,
        [MarshalAs(UnmanagedType.Bool)] bool bInherit);

    [LibraryImport("userenv.dll", EntryPoint = "DestroyEnvironmentBlock", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool DestroyEnvironmentBlock(IntPtr lpEnvironment);

    // LoadUserProfile / UnloadUserProfile — required so CreateProcessAsUser gets a
    // fully mounted HKCU and correct USERPROFILE/AppData for the admin logon.
    [DllImport("userenv.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool LoadUserProfile(IntPtr hToken, ref PROFILEINFO lpProfileInfo);

    [DllImport("userenv.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnloadUserProfile(IntPtr hToken, IntPtr hProfile);

    public const int PI_NOUI = 0x00000001;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PROFILEINFO
    {
        public int dwSize;
        public int dwFlags;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpUserName;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpProfilePath;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpDefaultPath;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpServerName;
        [MarshalAs(UnmanagedType.LPWStr)] public string? lpPolicyPath;
        public IntPtr hProfile;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "WaitForSingleObject", SetLastError = true)]
    public static partial uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CreatePipe(
        out IntPtr hReadPipe,
        out IntPtr hWritePipe,
        ref SECURITY_ATTRIBUTES lpPipeAttributes,
        uint nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetHandleInformation(IntPtr hObject, uint dwMask, uint dwFlags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool ReadFile(
        IntPtr hFile,
        byte[] lpBuffer,
        uint nNumberOfBytesToRead,
        out uint lpNumberOfBytesRead,
        IntPtr lpOverlapped);

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES
    {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [LibraryImport("kernel32.dll", EntryPoint = "GetExitCodeProcess", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [LibraryImport("kernel32.dll", EntryPoint = "ProcessIdToSessionId", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool ProcessIdToSessionId(uint dwProcessId, out uint pSessionId);

    [LibraryImport("kernel32.dll", EntryPoint = "GetProcessTimes", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetProcessTimes(
        IntPtr hProcess,
        out long lpCreationTime,
        out long lpExitTime,
        out long lpKernelTime,
        out long lpUserTime);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "QueryFullProcessImageNameW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool QueryFullProcessImageNameW(
        IntPtr hProcess,
        uint dwFlags,
        System.Text.StringBuilder lpExeName,
        ref uint lpdwSize);

    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetProcessMemoryInfo(
        IntPtr hProcess,
        out PROCESS_MEMORY_COUNTERS ppsmemCounters,
        uint cb);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateToolhelp32Snapshot(uint dwFlags, uint th32ProcessID);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool Thread32First(IntPtr hSnapshot, ref THREADENTRY32 lpte);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool Thread32Next(IntPtr hSnapshot, ref THREADENTRY32 lpte);

    public const uint STILL_ACTIVE = 259;
    public const uint WAIT_TIMEOUT = 0x00000102;
    public const uint WAIT_OBJECT_0 = 0;
    public const uint TH32CS_SNAPTHREAD = 0x00000004;
    public static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_MEMORY_COUNTERS
    {
        public uint cb;
        public uint PageFaultCount;
        public UIntPtr PeakWorkingSetSize;
        public UIntPtr WorkingSetSize;
        public UIntPtr QuotaPeakPagedPoolUsage;
        public UIntPtr QuotaPagedPoolUsage;
        public UIntPtr QuotaPeakNonPagedPoolUsage;
        public UIntPtr QuotaNonPagedPoolUsage;
        public UIntPtr PagefileUsage;
        public UIntPtr PeakPagefileUsage;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct THREADENTRY32
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ThreadID;
        public uint th32OwnerProcessID;
        public int tpBasePri;
        public int tpDeltaPri;
        public uint dwFlags;
    }

    /// <summary>
    /// Snapshot process diagnostics for elevated-launch logging. Safe to call with a
    /// process handle we still own (alive or already exited).
    /// </summary>
    public static string FormatProcessDiagnostics(IntPtr hProcess, uint pid)
    {
        string startTime = "(n/a)";
        string exitTime = "(n/a)";
        string cpuTime = "(n/a)";
        string exitCode = "(n/a)";
        string mainModule = "(n/a)";
        string workingSet = "(n/a)";
        string threadCount = "(n/a)";

        if (GetProcessTimes(hProcess, out long creation, out long exit, out long kernel, out long user))
        {
            try
            {
                startTime = DateTime.FromFileTimeUtc(creation).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss.fff");
            }
            catch
            {
                startTime = $"raw={creation}";
            }

            // Exit FILETIME is zero while the process is still running.
            if (exit != 0)
            {
                try
                {
                    exitTime = DateTime.FromFileTimeUtc(exit).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss.fff");
                }
                catch
                {
                    exitTime = $"raw={exit}";
                }
            }

            // Kernel + user are in 100-ns ticks.
            double cpuMs = (kernel + user) / 10_000.0;
            cpuTime = $"{cpuMs:F1}ms";
        }

        if (GetExitCodeProcess(hProcess, out uint code))
        {
            exitCode = code == STILL_ACTIVE ? "STILL_ACTIVE" : code.ToString();
        }

        try
        {
            var sb = new System.Text.StringBuilder(1024);
            uint size = (uint)sb.Capacity;
            if (QueryFullProcessImageNameW(hProcess, 0, sb, ref size))
                mainModule = sb.ToString(0, (int)size);
        }
        catch
        {
            // ignore
        }

        var mem = new PROCESS_MEMORY_COUNTERS { cb = (uint)Marshal.SizeOf<PROCESS_MEMORY_COUNTERS>() };
        if (GetProcessMemoryInfo(hProcess, out mem, mem.cb))
        {
            workingSet = $"{mem.WorkingSetSize.ToUInt64()} bytes";
        }

        int threads = CountProcessThreads(pid);
        if (threads >= 0)
            threadCount = threads.ToString();

        return
            $"StartTime={startTime}; MainModule={mainModule}; ExitTime={exitTime}; ExitCode={exitCode}; " +
            $"CpuTime={cpuTime}; WorkingSet={workingSet}; ThreadCount={threadCount}";
    }

    private static int CountProcessThreads(uint pid)
    {
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snap == IntPtr.Zero || snap == INVALID_HANDLE_VALUE)
            return -1;

        try
        {
            var te = new THREADENTRY32 { dwSize = (uint)Marshal.SizeOf<THREADENTRY32>() };
            if (!Thread32First(snap, ref te))
                return -1;

            int count = 0;
            do
            {
                if (te.th32OwnerProcessID == pid)
                    count++;
            }
            while (Thread32Next(snap, ref te));

            return count;
        }
        finally
        {
            CloseHandle(snap);
        }
    }

    [LibraryImport("kernel32.dll", EntryPoint = "GetCurrentProcess", SetLastError = true)]
    public static partial IntPtr GetCurrentProcess();

    [LibraryImport("advapi32.dll", EntryPoint = "OpenProcessToken", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool OpenProcessToken(
        IntPtr ProcessHandle,
        uint DesiredAccess,
        out IntPtr TokenHandle);

    [LibraryImport("advapi32.dll", EntryPoint = "SetTokenInformation", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool SetTokenInformation(
        IntPtr TokenHandle,
        uint TokenInformationClass,
        ref uint TokenInformation,
        uint TokenInformationLength);

    [LibraryImport("advapi32.dll", EntryPoint = "GetTokenInformation", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetTokenInformation(
        IntPtr TokenHandle,
        uint TokenInformationClass,
        IntPtr TokenInformation,
        uint TokenInformationLength,
        out uint ReturnLength);

    [LibraryImport("advapi32.dll", EntryPoint = "LookupPrivilegeValueW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool LookupPrivilegeValue(
        string? lpSystemName,
        string lpName,
        out LUID lpLuid);

    public const uint SE_PRIVILEGE_ENABLED = 0x00000002;
    public const uint TOKEN_ADJUST_PRIVILEGES = 0x0020;
    public const uint TOKEN_QUERY = 0x0008;
    public const uint MAXIMUM_ALLOWED = 0x02000000;
    public const uint CREATE_NEW_CONSOLE = 0x00000010;
    public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    public const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    public const uint NORMAL_PRIORITY_CLASS = 0x00000020;
    public const uint STARTF_USESHOWWINDOW = 0x00000001;
    public const uint STARTF_FORCEONFEEDBACK = 0x00000040;
    public const uint STARTF_USESTDHANDLES = 0x00000100;
    public const uint CREATE_NO_WINDOW = 0x08000000;
    public const uint HANDLE_FLAG_INHERIT = 0x00000001;
    public const uint DUPLICATE_SAME_ACCESS = 0x00000002;
    public const uint LOGON_WITH_PROFILE = 0x00000001;
    public const ushort SW_SHOW = 5;
    public const ushort SW_SHOWDEFAULT = 10;

    public const uint TOKEN_SESSION = 12;
    public const uint TokenPrivileges = 3;

    public enum SECURITY_IMPERSONATION_LEVEL
    {
        SecurityAnonymous = 0,
        SecurityIdentification = 1,
        SecurityImpersonation = 2,
        SecurityDelegation = 3,
    }

    public enum TOKEN_TYPE
    {
        TokenPrimary = 1,
        TokenImpersonation = 2,
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFO
    {
        public uint cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public ushort wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;

        public STARTUPINFO(string desktop)
        {
            cb = (uint)Marshal.SizeOf<STARTUPINFO>();
            lpReserved = "";
            lpDesktop = desktop;
            lpTitle = "";
            dwX = 0;
            dwY = 0;
            dwXSize = 0;
            dwYSize = 0;
            dwXCountChars = 0;
            dwYCountChars = 0;
            dwFillAttribute = 0;
            dwFlags = STARTF_USESHOWWINDOW;
            wShowWindow = SW_SHOWDEFAULT;
            cbReserved2 = 0;
            lpReserved2 = IntPtr.Zero;
            hStdInput = IntPtr.Zero;
            hStdOutput = IntPtr.Zero;
            hStdError = IntPtr.Zero;
        }

        public STARTUPINFO()
        {
            cb = (uint)Marshal.SizeOf<STARTUPINFO>();
            lpReserved = "";
            lpDesktop = "";
            lpTitle = "";
            dwX = 0;
            dwY = 0;
            dwXSize = 0;
            dwYSize = 0;
            dwXCountChars = 0;
            dwYCountChars = 0;
            dwFillAttribute = 0;
            dwFlags = 0;
            wShowWindow = SW_SHOWDEFAULT;
            cbReserved2 = 0;
            lpReserved2 = IntPtr.Zero;
            hStdInput = IntPtr.Zero;
            hStdOutput = IntPtr.Zero;
            hStdError = IntPtr.Zero;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct LUID_AND_ATTRIBUTES
    {
        public LUID Luid;
        public uint Attributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct TOKEN_PRIVILEGES
    {
        public uint PrivilegeCount;
        // Privileges[PrivilegeCount] — must be allocated dynamically
    }

    private static readonly ILogger _initLogger = LoggerFactory
        .Create(b => b.AddEventLog(new EventLogSettings
        {
            SourceName = "NextGPUService",
            LogName = "Application"
        }))
        .CreateLogger("NextGPU.Service.LaunchInterop");

    public static LUID SeAssignPrimaryTokenLuid;
    public static LUID SeImpersonatePrivilegeLuid;
    public static LUID SeTcbPrivilegeLuid;
    public static LUID SeIncreaseQuotaPrivilegeLuid;
    public static LUID SeBackupPrivilegeLuid;
    public static LUID SeRestorePrivilegeLuid;
    public static bool PrivilegesEnabled;

    private static int _initialized;

    public static void EnsureInitialized()
    {
        if (System.Threading.Interlocked.CompareExchange(ref _initialized, 1, 0) != 0)
            return;

        try
        {
            if (!LookupPrivilegeValue(null, "SeAssignPrimaryTokenPrivilege", out SeAssignPrimaryTokenLuid))
            {
                _initLogger.LogWarning("LookupPrivilegeValue(SeAssignPrimaryTokenPrivilege) failed, error {Error}",
                    Marshal.GetLastWin32Error());
            }

            if (!LookupPrivilegeValue(null, "SeImpersonatePrivilege", out SeImpersonatePrivilegeLuid))
            {
                _initLogger.LogWarning("LookupPrivilegeValue(SeImpersonatePrivilege) failed, error {Error}",
                    Marshal.GetLastWin32Error());
            }

            // Required for SetTokenInformation(TokenSessionId) when pinning admin token into a user session.
            if (!LookupPrivilegeValue(null, "SeTcbPrivilege", out SeTcbPrivilegeLuid))
            {
                _initLogger.LogWarning("LookupPrivilegeValue(SeTcbPrivilege) failed, error {Error}",
                    Marshal.GetLastWin32Error());
            }

            if (!LookupPrivilegeValue(null, "SeIncreaseQuotaPrivilege", out SeIncreaseQuotaPrivilegeLuid))
            {
                _initLogger.LogWarning("LookupPrivilegeValue(SeIncreaseQuotaPrivilege) failed, error {Error}",
                    Marshal.GetLastWin32Error());
            }

            // Required for LoadUserProfile from a service.
            if (!LookupPrivilegeValue(null, "SeBackupPrivilege", out SeBackupPrivilegeLuid))
            {
                _initLogger.LogWarning("LookupPrivilegeValue(SeBackupPrivilege) failed, error {Error}",
                    Marshal.GetLastWin32Error());
            }

            if (!LookupPrivilegeValue(null, "SeRestorePrivilege", out SeRestorePrivilegeLuid))
            {
                _initLogger.LogWarning("LookupPrivilegeValue(SeRestorePrivilege) failed, error {Error}",
                    Marshal.GetLastWin32Error());
            }

            PrivilegesEnabled = EnableCurrentProcessPrivileges();
            if (!PrivilegesEnabled)
            {
                _initLogger.LogWarning("EnableCurrentProcessPrivileges returned false; launches requiring SeAssignPrimaryToken/SeImpersonate/SeTcb may fail");
            }
            else
            {
                _initLogger.LogInformation("LaunchInterop privileges enabled");
            }
        }
        catch (Exception ex)
        {
            _initLogger.LogError(ex, "LaunchInterop initialization failed; continuing with default ACL");
        }
    }

    public static bool EnableCurrentProcessPrivileges()
    {
        IntPtr hProcess = GetCurrentProcess();
        if (!OpenProcessToken(hProcess, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, out IntPtr hToken))
            return false;

        try
        {
            // SeAssignPrimaryToken + SeImpersonate + SeTcb + SeIncreaseQuota + SeBackup + SeRestore
            int structSize = 4; // PrivilegeCount
            int entrySize = Marshal.SizeOf<LUID_AND_ATTRIBUTES>();
            int count = 6;
            int totalSize = structSize + count * entrySize;
            IntPtr buf = Marshal.AllocCoTaskMem(totalSize);
            try
            {
                Marshal.WriteInt32(buf, count);
                IntPtr entries = IntPtr.Add(buf, structSize);

                void WritePriv(IntPtr entry, LUID luid)
                {
                    Marshal.WriteInt32(entry, 0, (int)luid.LowPart);
                    Marshal.WriteInt32(entry, 4, luid.HighPart);
                    Marshal.WriteInt32(entry, 8, (int)SE_PRIVILEGE_ENABLED);
                }

                WritePriv(entries, SeAssignPrimaryTokenLuid);
                WritePriv(IntPtr.Add(entries, entrySize), SeImpersonatePrivilegeLuid);
                WritePriv(IntPtr.Add(entries, entrySize * 2), SeTcbPrivilegeLuid);
                WritePriv(IntPtr.Add(entries, entrySize * 3), SeIncreaseQuotaPrivilegeLuid);
                WritePriv(IntPtr.Add(entries, entrySize * 4), SeBackupPrivilegeLuid);
                WritePriv(IntPtr.Add(entries, entrySize * 5), SeRestorePrivilegeLuid);

                unsafe
                {
                    bool ok = AdjustTokenPrivilegesRaw(hToken, buf.ToPointer(), (uint)totalSize);
                    if (!ok)
                        _initLogger.LogDebug("AdjustTokenPrivileges errors: {Err}", Marshal.GetLastWin32Error());
                    return ok;
                }
            }
            finally
            {
                Marshal.FreeCoTaskMem(buf);
            }
        }
        finally
        {
            CloseHandle(hToken);
        }
    }

    public static void FreeToken(ref IntPtr token)
    {
        if (token != IntPtr.Zero)
        {
            CloseHandle(token);
            token = IntPtr.Zero;
        }
    }

    // Duplicates a token as TokenImpersonation type, which is required for
    // use as a source token when injecting privileges via AdjustTokenPrivileges.
    public static bool DuplicateTokenAsImpersonation(
        IntPtr hExistingToken,
        out IntPtr phNewToken)
    {
        return DuplicateTokenEx(
            hExistingToken,
            MAXIMUM_ALLOWED,
            IntPtr.Zero,
            SECURITY_IMPERSONATION_LEVEL.SecurityImpersonation,
            TOKEN_TYPE.TokenImpersonation,
            out phNewToken);
    }

    // Reads all privileges from srcToken and copies them (enabled) into dstToken.
    // Returns false on any error; never throws.
    public static bool InjectPrivileges(IntPtr srcToken, IntPtr dstToken)
    {
        try
        {
            // Query required buffer size.
            if (!GetTokenInformation(srcToken, TokenPrivileges, IntPtr.Zero, 0, out uint needed) &&
                Marshal.GetLastWin32Error() != 122)
            {
                return false;
            }

            if (needed < 4 || needed > 1_000_000)
                return false;

            IntPtr srcBuf = Marshal.AllocCoTaskMem((int)needed);
            IntPtr dstBuf = IntPtr.Zero;
            bool success = false;
            try
            {
                if (!GetTokenInformation(srcToken, TokenPrivileges, srcBuf, needed, out _))
                    return false;

                uint count = (uint)Marshal.ReadInt32(srcBuf);
                if (count == 0)
                    return true;

                // TOKEN_PRIVILEGES layout: DWORD (4 bytes) + LUID_AND_ATTRIBUTES[count]
                // LUID_AND_ATTRIBUTES = LUID (8 bytes: LowPart DWORD + HighPart DWORD) + DWORD Attributes
                int entrySize = 16; // 8 bytes LUID + 4 bytes attrs + 4 bytes padding (struct alignment)
                int dstSize = 4 + (int)count * entrySize;
                dstBuf = Marshal.AllocCoTaskMem(dstSize);

                // Write count
                Marshal.WriteInt32(dstBuf, (int)count);

                // Copy each entry, forcing SE_PRIVILEGE_ENABLED
                IntPtr srcEntry = IntPtr.Add(srcBuf, 4);
                IntPtr dstEntry = IntPtr.Add(dstBuf, 4);
                for (int i = 0; i < (int)count; i++)
                {
                    // Copy Luid.HighPart and Luid.LowPart
                    int high = Marshal.ReadInt32(srcEntry, 4);
                    int low  = Marshal.ReadInt32(srcEntry, 0);
                    Marshal.WriteInt32(dstEntry, 0, low);
                    Marshal.WriteInt32(dstEntry, 4, high);
                    // Force ENABLED attribute
                    Marshal.WriteInt32(dstEntry, 8, (int)SE_PRIVILEGE_ENABLED);
                    srcEntry = IntPtr.Add(srcEntry, entrySize);
                    dstEntry = IntPtr.Add(dstEntry, entrySize);
                }

                unsafe
                {
                    byte* p = (byte*)dstBuf.ToPointer();
                    success = AdjustTokenPrivilegesRaw(dstToken, p, (uint)dstSize);
                }
                return success;
            }
            finally
            {
                if (srcBuf != IntPtr.Zero) Marshal.FreeCoTaskMem(srcBuf);
                if (dstBuf != IntPtr.Zero) Marshal.FreeCoTaskMem(dstBuf);
            }
        }
        catch
        {
            return false;
        }
    }

    // Raw pointer version — lives in a separate non-partial class to avoid
    // conflicts with the LibraryImport-generated partial method.
    public static unsafe bool AdjustTokenPrivilegesRaw(
        IntPtr TokenHandle,
        void* NewState,
        uint BufferLength)
        => RawPInvokes.AdjustTokenPrivilegesRaw(TokenHandle, NewState, BufferLength);

    public static void FreeProcessInfo(PROCESS_INFORMATION pi)
    {
        if (pi.hProcess != IntPtr.Zero)
        {
            CloseHandle(pi.hProcess);
        }
        if (pi.hThread != IntPtr.Zero)
        {
            CloseHandle(pi.hThread);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct WTS_SESSION_INFO
    {
        public uint SessionId;
        public IntPtr pWinStationName;
        public uint State;
    }

    // Finds the Windows session ID for the first running process whose executable name matches.
    // Returns 0 if no matching process is found. Used to discover where Playnite is currently running
    // so that PlayniteStart launches can target that session (WCF named pipes are per-session, so the
    // launcher needs to run in the same session as the target Playnite for the forward path to work).
    public static uint FindProcessSessionId(string processName)
    {
        try
        {
            var procs = Process.GetProcessesByName(processName);
            if (procs.Length == 0)
                return 0;

            // Prefer an active session (WTSActive == 0). Process.SessionId is the user's session.
            uint best = 0;
            foreach (var p in procs)
            {
                if (p.SessionId == 0) continue; // services session
                best = (uint)p.SessionId;
                break;
            }

            return best;
        }
        catch
        {
            return 0;
        }
    }

    // Finds the first active session via WTSEnumerateSessionsW and returns its session ID.
    // Falls back to WTSGetActiveConsoleSessionId if enumeration returns nothing.
    // Returns 0 if no session can be found.
    public static uint GetFirstActiveSessionId()
    {
        IntPtr pSessionInfo = IntPtr.Zero;
        uint count = 0;
        try
        {
            if (!WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, out pSessionInfo, out count))
                return WTSGetActiveConsoleSessionId();

            if (count == 0)
                return WTSGetActiveConsoleSessionId();

            int structSize = Marshal.SizeOf<WTS_SESSION_INFO>();
            IntPtr current = pSessionInfo;
            for (int i = 0; i < (int)count; i++)
            {
                var info = Marshal.PtrToStructure<WTS_SESSION_INFO>(current);
                if (info.State == WTSActive)
                {
                    return info.SessionId;
                }
                current = IntPtr.Add(current, structSize);
            }

            return WTSGetActiveConsoleSessionId();
        }
        finally
        {
            if (pSessionInfo != IntPtr.Zero)
                WTSFreeMemory(pSessionInfo);
        }
    }

    [LibraryImport("kernel32.dll", EntryPoint = "GetVolumeNameForVolumeMountPointW", StringMarshalling = StringMarshalling.Utf16, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static partial bool GetVolumeNameForVolumeMountPoint(
        string lpszVolumeMountPoint,
        [Out] char[] lpszVolumeName,
        uint cchBufferLength);

    // Resolves a drive-letter path (e.g. Z:\Playnite\app.exe) to a volume GUID path
    // (\\?\Volume{guid}\Playnite\app.exe) so CreateProcessAsUserW can find the file after
    // the token is pinned into another session (drive letters are not always visible there).
    public static string ResolvePathForCrossSession(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return path;

        try
        {
            string full = Path.GetFullPath(path);
            if (full.Length < 3 || full[1] != ':' || full[2] != '\\')
                return full;

            string root = full.Substring(0, 3); // "Z:\"
            char[] volBuf = new char[50];
            if (!GetVolumeNameForVolumeMountPoint(root, volBuf, (uint)volBuf.Length))
                return full;

            string volumeName = new string(volBuf).TrimEnd('\0'); // "\\?\Volume{guid}\"
            if (string.IsNullOrEmpty(volumeName))
                return full;

            string relative = full.Substring(3); // path after "Z:\"
            return volumeName + relative;
        }
        catch
        {
            return path;
        }
    }

    // Returns the logged-on user name for a WTS session, or null on failure.
    public static string? TryGetSessionUserName(uint sessionId)
    {
        IntPtr buffer = IntPtr.Zero;
        try
        {
            if (!WTSQuerySessionInformationW(
                    WTS_CURRENT_SERVER_HANDLE,
                    sessionId,
                    WTSUserName,
                    out buffer,
                    out uint bytesReturned))
            {
                return null;
            }

            if (buffer == IntPtr.Zero || bytesReturned == 0)
                return null;

            return Marshal.PtrToStringUni(buffer);
        }
        finally
        {
            if (buffer != IntPtr.Zero)
                WTSFreeMemory(buffer);
        }
    }

    // Locates a session whose WTS user name matches userName (case-insensitive).
    // Preference: Active, then Connected, then Disconnected (and other non-zero sessions).
    // Returns false if no matching session is found.
    public static bool FindSessionIdByUserName(string userName, out uint sessionId, out uint state)
    {
        sessionId = 0;
        state = 0;

        if (string.IsNullOrWhiteSpace(userName))
            return false;

        IntPtr pSessionInfo = IntPtr.Zero;
        uint count = 0;
        try
        {
            if (!WTSEnumerateSessionsW(WTS_CURRENT_SERVER_HANDLE, 0, 1, out pSessionInfo, out count) || count == 0)
                return false;

            uint bestId = 0;
            uint bestState = 0;
            int bestRank = int.MaxValue;

            int structSize = Marshal.SizeOf<WTS_SESSION_INFO>();
            IntPtr current = pSessionInfo;
            for (int i = 0; i < (int)count; i++)
            {
                var info = Marshal.PtrToStructure<WTS_SESSION_INFO>(current);
                current = IntPtr.Add(current, structSize);

                if (info.SessionId == 0)
                    continue;

                string? sessionUser = TryGetSessionUserName(info.SessionId);
                if (string.IsNullOrEmpty(sessionUser) ||
                    !string.Equals(sessionUser, userName, StringComparison.OrdinalIgnoreCase))
                {
                    continue;
                }

                int rank = info.State switch
                {
                    WTSActive => 0,
                    WTSConnected => 1,
                    WTSDisconnected => 2,
                    _ => 3
                };

                if (rank < bestRank)
                {
                    bestRank = rank;
                    bestId = info.SessionId;
                    bestState = info.State;
                }
            }

            if (bestId == 0)
                return false;

            sessionId = bestId;
            state = bestState;
            return true;
        }
        finally
        {
            if (pSessionInfo != IntPtr.Zero)
                WTSFreeMemory(pSessionInfo);
        }
    }
}

// Lives in its own non-partial class so DllImport can coexist with LibraryImport.
internal static unsafe class RawPInvokes
{
    [DllImport("advapi32.dll", EntryPoint = "AdjustTokenPrivileges", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AdjustTokenPrivilegesRaw(
        IntPtr TokenHandle,
        void* NewState,
        uint BufferLength);
}