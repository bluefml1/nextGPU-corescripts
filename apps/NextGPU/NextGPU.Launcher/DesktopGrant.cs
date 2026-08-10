using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace NextGPU.Launcher;

/// <summary>
/// Must run INSIDE the target interactive session (as the session user).
/// Session-0 OpenWindowStation(winsta0) cannot see another session's stations
/// even when impersonating — Access Denied (5).
/// </summary>
internal static class DesktopGrant
{
    private const uint DACL_SECURITY_INFORMATION = 0x00000004;
    private const uint READ_CONTROL = 0x00020000;
    private const uint WRITE_DAC = 0x00040000;
    private const uint WINSTA_ALL_ACCESS = 0x0000037F;
    private const uint DESKTOP_ALL_ACCESS = 0x000001FF;
    private const byte ACCESS_ALLOWED_ACE_TYPE = 0x0;
    private const byte ACL_REVISION = 2;

    public static int Run(string accountName)
    {
        try
        {
            if (string.IsNullOrWhiteSpace(accountName))
            {
                Console.Error.WriteLine("usage: --grant-desktop <AccountName>");
                return 2;
            }

            // Accept DOMAIN\user or bare user; LookupAccountName resolves local accounts.
            string name = accountName.Contains('\\')
                ? accountName.Split('\\')[^1]
                : accountName;
            string? domain = accountName.Contains('\\')
                ? accountName.Split('\\')[0]
                : Environment.MachineName;

            NTAccount account = accountName.Contains('\\')
                ? new NTAccount(accountName)
                : new NTAccount(Environment.MachineName, name);

            SecurityIdentifier sid;
            try
            {
                sid = (SecurityIdentifier)account.Translate(typeof(SecurityIdentifier));
            }
            catch (Exception ex)
            {
                // Fallback: machine\name
                try
                {
                    sid = (SecurityIdentifier)new NTAccount(Environment.MachineName, name)
                        .Translate(typeof(SecurityIdentifier));
                }
                catch
                {
                    Console.Error.WriteLine($"LookupAccount failed for '{accountName}': {ex.Message}");
                    return 3;
                }
            }

            byte[] sidBytes = new byte[sid.BinaryLength];
            sid.GetBinaryForm(sidBytes, 0);
            IntPtr pSid = Marshal.AllocHGlobal(sidBytes.Length);
            try
            {
                Marshal.Copy(sidBytes, 0, pSid, sidBytes.Length);

                IntPtr hWinsta = OpenWindowStationW("winsta0", false, READ_CONTROL | WRITE_DAC);
                if (hWinsta == IntPtr.Zero)
                {
                    Console.Error.WriteLine($"OpenWindowStation(winsta0) failed: {Marshal.GetLastWin32Error()}");
                    return 4;
                }

                try
                {
                    if (!AddSidToObjectDacl(hWinsta, pSid, WINSTA_ALL_ACCESS, out string? err))
                    {
                        Console.Error.WriteLine($"winsta ACE: {err}");
                        return 5;
                    }

                    IntPtr hDesk = OpenDesktopW("default", 0, false, READ_CONTROL | WRITE_DAC | DESKTOP_ALL_ACCESS);
                    if (hDesk == IntPtr.Zero)
                    {
                        Console.Error.WriteLine($"OpenDesktop(default) failed: {Marshal.GetLastWin32Error()}");
                        return 6;
                    }

                    try
                    {
                        if (!AddSidToObjectDacl(hDesk, pSid, DESKTOP_ALL_ACCESS, out err))
                        {
                            Console.Error.WriteLine($"desktop ACE: {err}");
                            return 7;
                        }
                    }
                    finally
                    {
                        CloseDesktop(hDesk);
                    }
                }
                finally
                {
                    CloseWindowStation(hWinsta);
                }
            }
            finally
            {
                Marshal.FreeHGlobal(pSid);
            }

            string json = $"{{\"ok\":true,\"granted\":\"{Escape(accountName)}\",\"sid\":\"{sid.Value}\"}}";
            Console.Out.WriteLine(json);
            Console.Out.Flush();
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"grant-desktop failed: {ex}");
            return 1;
        }
    }

    private static string Escape(string s) => s.Replace("\\", "\\\\").Replace("\"", "\\\"");

    private static bool AddSidToObjectDacl(IntPtr hObject, IntPtr pSid, uint accessMask, out string? error)
    {
        error = null;
        uint sdSize = 0;
        GetUserObjectSecurity(hObject, DACL_SECURITY_INFORMATION, IntPtr.Zero, 0, ref sdSize);
        if (sdSize == 0)
        {
            error = $"GetUserObjectSecurity(size) failed: {Marshal.GetLastWin32Error()}";
            return false;
        }

        IntPtr sd = Marshal.AllocHGlobal((int)sdSize);
        IntPtr newSd = IntPtr.Zero;
        IntPtr newDacl = IntPtr.Zero;
        try
        {
            if (!GetUserObjectSecurity(hObject, DACL_SECURITY_INFORMATION, sd, sdSize, ref sdSize))
            {
                error = $"GetUserObjectSecurity failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            if (!GetSecurityDescriptorDacl(sd, out bool daclPresent, out IntPtr pOldDacl, out _))
            {
                error = $"GetSecurityDescriptorDacl failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            ACL_SIZE_INFORMATION aclInfo = default;
            int aceCount = 0;
            int aclBytes = Marshal.SizeOf<ACL>();
            if (daclPresent && pOldDacl != IntPtr.Zero)
            {
                if (!GetAclInformation(pOldDacl, ref aclInfo, (uint)Marshal.SizeOf<ACL_SIZE_INFORMATION>(), 2))
                {
                    error = $"GetAclInformation failed: {Marshal.GetLastWin32Error()}";
                    return false;
                }
                aceCount = (int)aclInfo.AceCount;
                aclBytes = (int)aclInfo.AclBytesInUse;
            }

            int sidLen = GetLengthSid(pSid);
            int newAclSize = aclBytes + 8 + sidLen; // ACCESS_ALLOWED_ACE header + SID
            newDacl = Marshal.AllocHGlobal(newAclSize);
            if (!InitializeAcl(newDacl, (uint)newAclSize, ACL_REVISION))
            {
                error = $"InitializeAcl failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            bool sidAlreadyPresent = false;
            for (int i = 0; i < aceCount; i++)
            {
                if (!GetAce(pOldDacl, i, out IntPtr pAce))
                {
                    error = $"GetAce({i}) failed: {Marshal.GetLastWin32Error()}";
                    return false;
                }

                ushort size = (ushort)Marshal.ReadInt16(IntPtr.Add(pAce, 2));
                if (Marshal.ReadByte(pAce) == ACCESS_ALLOWED_ACE_TYPE)
                {
                    IntPtr aceSid = IntPtr.Add(pAce, 8);
                    if (EqualSid(pSid, aceSid))
                        sidAlreadyPresent = true;
                }

                if (!AddAce(newDacl, ACL_REVISION, uint.MaxValue, pAce, size))
                {
                    error = $"AddAce({i}) failed: {Marshal.GetLastWin32Error()}";
                    return false;
                }
            }

            if (!sidAlreadyPresent && !AddAccessAllowedAce(newDacl, ACL_REVISION, accessMask, pSid))
            {
                error = $"AddAccessAllowedAce failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            // SECURITY_DESCRIPTOR is variable; allocate generous buffer.
            newSd = Marshal.AllocHGlobal(Math.Max((int)sdSize, 4096));
            if (!InitializeSecurityDescriptor(newSd, 1))
            {
                error = $"InitializeSecurityDescriptor failed: {Marshal.GetLastWin32Error()}";
                return false;
            }
            if (!SetSecurityDescriptorDacl(newSd, true, newDacl, false))
            {
                error = $"SetSecurityDescriptorDacl failed: {Marshal.GetLastWin32Error()}";
                return false;
            }
            if (!SetUserObjectSecurity(hObject, DACL_SECURITY_INFORMATION, newSd))
            {
                error = $"SetUserObjectSecurity failed: {Marshal.GetLastWin32Error()}";
                return false;
            }
            return true;
        }
        finally
        {
            if (sd != IntPtr.Zero) Marshal.FreeHGlobal(sd);
            if (newSd != IntPtr.Zero) Marshal.FreeHGlobal(newSd);
            if (newDacl != IntPtr.Zero) Marshal.FreeHGlobal(newDacl);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ACL
    {
        public byte AclRevision;
        public byte Sbz1;
        public ushort AclSize;
        public ushort AceCount;
        public ushort Sbz2;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ACL_SIZE_INFORMATION
    {
        public uint AceCount;
        public uint AclBytesInUse;
        public uint AclBytesFree;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenWindowStationW(string lpszWinSta, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseWindowStation(IntPtr hWinSta);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenDesktopW(string lpszDesktop, uint dwFlags, bool fInherit, uint dwDesiredAccess);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserObjectSecurity(IntPtr hObj, uint si, IntPtr pSID, uint nLength, ref uint lpnLengthNeeded);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetUserObjectSecurity(IntPtr hObj, uint si, IntPtr pSID);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSecurityDescriptorDacl(IntPtr pSecurityDescriptor, [MarshalAs(UnmanagedType.Bool)] out bool bDaclPresent, out IntPtr pDacl, [MarshalAs(UnmanagedType.Bool)] out bool bDaclDefaulted);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetSecurityDescriptorDacl(IntPtr pSecurityDescriptor, [MarshalAs(UnmanagedType.Bool)] bool bDaclPresent, IntPtr pDacl, [MarshalAs(UnmanagedType.Bool)] bool bDaclDefaulted);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeSecurityDescriptor(IntPtr pSecurityDescriptor, uint dwRevision);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetAclInformation(IntPtr pAcl, ref ACL_SIZE_INFORMATION pAclInformation, uint nAclInformationLength, uint dwAclInformationClass);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeAcl(IntPtr pAcl, uint nAclLength, uint dwAclRevision);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetAce(IntPtr pAcl, int dwAceIndex, out IntPtr pAce);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddAce(IntPtr pAcl, uint dwAceRevision, uint dwStartingAceIndex, IntPtr pAceList, uint nAceListLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddAccessAllowedAce(IntPtr pAcl, uint dwAceRevision, uint AccessMask, IntPtr pSid);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EqualSid(IntPtr pSid1, IntPtr pSid2);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int GetLengthSid(IntPtr pSid);
}
