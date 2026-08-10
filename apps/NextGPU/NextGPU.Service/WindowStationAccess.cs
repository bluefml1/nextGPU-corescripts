using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;

namespace NextGPU.Service;

/// <summary>
/// Grants a user SID (and optional logon SID) access to the interactive
/// window station/desktop of a target session. Required when CreateProcessAsUser
/// injects a foreign LogonUser token (NextGPU-Admin) into another user's session
/// (NextGPU-Authority): that token lacks the session Logon SID that owns winsta0\default.
/// </summary>
internal static class WindowStationAccess
{
    private const uint TokenUser = 1;
    private const uint TokenGroups = 2;
    private const uint SE_GROUP_LOGON_ID = 0xC0000000;
    private const uint DACL_SECURITY_INFORMATION = 0x00000004;
    private const uint ERROR_INSUFFICIENT_BUFFER = 122;
    private const uint READ_CONTROL = 0x00020000;
    private const uint WRITE_DAC = 0x00040000;
    private const uint WINSTA_ALL_ACCESS = 0x0000037F;
    private const uint DESKTOP_ALL_ACCESS = 0x000001FF;
    private const byte ACCESS_ALLOWED_ACE_TYPE = 0x0;
    private const byte ACL_REVISION = 2;

    public static bool GrantAdminAccessToSessionDesktop(
        IntPtr hSessionUserToken,
        IntPtr hAdminToken,
        ILogger log,
        out string? error)
    {
        error = null;
        IntPtr userSid = IntPtr.Zero;
        IntPtr logonSid = IntPtr.Zero;
        IntPtr userSidBuf = IntPtr.Zero;
        IntPtr groupsBuf = IntPtr.Zero;
        bool impersonating = false;

        try
        {
            if (!TryGetTokenUserSid(hAdminToken, out userSid, out userSidBuf, out error))
                return false;

            TryGetTokenLogonSid(hAdminToken, out logonSid, out groupsBuf);

            if (!LaunchInterop.ImpersonateLoggedOnUser(hSessionUserToken))
            {
                error = $"ImpersonateLoggedOnUser(session) failed: {Marshal.GetLastWin32Error()}";
                return false;
            }
            impersonating = true;

            IntPtr hWinsta = OpenWindowStationW("winsta0", false, READ_CONTROL | WRITE_DAC);
            if (hWinsta == IntPtr.Zero)
            {
                error = $"OpenWindowStation(winsta0) failed: {Marshal.GetLastWin32Error()}";
                return false;
            }

            try
            {
                if (!AddSidToObjectDacl(hWinsta, userSid, WINSTA_ALL_ACCESS, isDesktop: false, out error))
                    return false;
                if (logonSid != IntPtr.Zero &&
                    !AddSidToObjectDacl(hWinsta, logonSid, WINSTA_ALL_ACCESS, isDesktop: false, out error))
                    return false;

                IntPtr hDesk = OpenDesktopW("default", 0, false, READ_CONTROL | WRITE_DAC | DESKTOP_ALL_ACCESS);
                if (hDesk == IntPtr.Zero)
                {
                    error = $"OpenDesktop(default) failed: {Marshal.GetLastWin32Error()}";
                    return false;
                }

                try
                {
                    if (!AddSidToObjectDacl(hDesk, userSid, DESKTOP_ALL_ACCESS, isDesktop: true, out error))
                        return false;
                    if (logonSid != IntPtr.Zero &&
                        !AddSidToObjectDacl(hDesk, logonSid, DESKTOP_ALL_ACCESS, isDesktop: true, out error))
                        return false;
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

            log.LogInformation(
                "Granted Admin SID{Logon} access to session winsta0\\default",
                logonSid != IntPtr.Zero ? "+LogonSID" : "");
            return true;
        }
        finally
        {
            if (impersonating && !LaunchInterop.RevertToSelf())
                log.LogWarning("RevertToSelf after desktop grant failed: {Err}", Marshal.GetLastWin32Error());
            if (userSidBuf != IntPtr.Zero) Marshal.FreeHGlobal(userSidBuf);
            if (groupsBuf != IntPtr.Zero) Marshal.FreeHGlobal(groupsBuf);
        }
    }

    private static bool TryGetTokenUserSid(
        IntPtr hToken,
        out IntPtr pSid,
        out IntPtr ownedBuffer,
        out string? error)
    {
        pSid = IntPtr.Zero;
        ownedBuffer = IntPtr.Zero;
        error = null;

        LaunchInterop.GetTokenInformation(hToken, TokenUser, IntPtr.Zero, 0, out uint needed);
        if (needed == 0)
        {
            error = $"GetTokenInformation(TokenUser) size failed: {Marshal.GetLastWin32Error()}";
            return false;
        }

        ownedBuffer = Marshal.AllocHGlobal((int)needed);
        if (!LaunchInterop.GetTokenInformation(hToken, TokenUser, ownedBuffer, needed, out _))
        {
            error = $"GetTokenInformation(TokenUser) failed: {Marshal.GetLastWin32Error()}";
            Marshal.FreeHGlobal(ownedBuffer);
            ownedBuffer = IntPtr.Zero;
            return false;
        }

        // TOKEN_USER { SID_AND_ATTRIBUTES User; } → first field is PSID
        pSid = Marshal.ReadIntPtr(ownedBuffer);
        return pSid != IntPtr.Zero;
    }

    private static void TryGetTokenLogonSid(IntPtr hToken, out IntPtr pLogonSid, out IntPtr ownedBuffer)
    {
        pLogonSid = IntPtr.Zero;
        ownedBuffer = IntPtr.Zero;

        LaunchInterop.GetTokenInformation(hToken, TokenGroups, IntPtr.Zero, 0, out uint needed);
        if (needed == 0)
            return;

        ownedBuffer = Marshal.AllocHGlobal((int)needed);
        if (!LaunchInterop.GetTokenInformation(hToken, TokenGroups, ownedBuffer, needed, out _))
        {
            Marshal.FreeHGlobal(ownedBuffer);
            ownedBuffer = IntPtr.Zero;
            return;
        }

        // TOKEN_GROUPS: DWORD GroupCount; then SID_AND_ATTRIBUTES[GroupCount]
        int groupCount = Marshal.ReadInt32(ownedBuffer);
        IntPtr groups = IntPtr.Add(ownedBuffer, IntPtr.Size == 8 ? 8 : 4); // alignment after DWORD
        // On x64, TOKEN_GROUPS is: DWORD GroupCount; DWORD pad; SID_AND_ATTRIBUTES Groups[]
        if (IntPtr.Size == 8)
            groups = IntPtr.Add(ownedBuffer, 8);
        else
            groups = IntPtr.Add(ownedBuffer, 4);

        int saSize = IntPtr.Size + 4; // PSID + Attributes (DWORD); may pad to 8+8 on x64
        if (IntPtr.Size == 8)
            saSize = 16; // SID_AND_ATTRIBUTES is pointer + uint + pad

        for (int i = 0; i < groupCount; i++)
        {
            IntPtr entry = IntPtr.Add(groups, i * saSize);
            IntPtr sid = Marshal.ReadIntPtr(entry);
            uint attrs = (uint)Marshal.ReadInt32(IntPtr.Add(entry, IntPtr.Size));
            if ((attrs & SE_GROUP_LOGON_ID) == SE_GROUP_LOGON_ID)
            {
                pLogonSid = sid;
                return;
            }
        }
    }

    private static bool AddSidToObjectDacl(
        IntPtr hObject,
        IntPtr pSid,
        uint accessMask,
        bool isDesktop,
        out string? error)
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
            int aclBytes = 0;
            if (daclPresent && pOldDacl != IntPtr.Zero)
            {
                if (!GetAclInformation(pOldDacl, ref aclInfo, (uint)Marshal.SizeOf<ACL_SIZE_INFORMATION>(), 2 /*AclSizeInformation*/))
                {
                    error = $"GetAclInformation failed: {Marshal.GetLastWin32Error()}";
                    return false;
                }
                aceCount = (int)aclInfo.AceCount;
                aclBytes = (int)aclInfo.AclBytesInUse;
            }
            else
            {
                aclBytes = Marshal.SizeOf<ACL>();
            }

            int sidLen = GetLengthSid(pSid);
            int newAclSize = aclBytes + Marshal.SizeOf<ACCESS_ALLOWED_ACE>() + sidLen - sizeof(uint);
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
                byte aceType = Marshal.ReadByte(pAce);
                if (aceType == ACCESS_ALLOWED_ACE_TYPE)
                {
                    // ACCESS_ALLOWED_ACE: AceType, AceFlags, AceSize, Mask, SidStart...
                    IntPtr aceSid = IntPtr.Add(pAce, 8);
                    if (EqualSid(pSid, aceSid))
                        sidAlreadyPresent = true;
                }

                if (!AddAce(newDacl, ACL_REVISION, uint.MaxValue, pAce, size))
                {
                    error = $"AddAce(existing {i}) failed: {Marshal.GetLastWin32Error()}";
                    return false;
                }
            }

            if (!sidAlreadyPresent)
            {
                if (!AddAccessAllowedAce(newDacl, ACL_REVISION, accessMask, pSid))
                {
                    error = $"AddAccessAllowedAce failed: {Marshal.GetLastWin32Error()}";
                    return false;
                }
            }

            newSd = Marshal.AllocHGlobal((int)sdSize + newAclSize);
            if (!InitializeSecurityDescriptor(newSd, 1 /*SECURITY_DESCRIPTOR_REVISION*/))
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
                error = $"SetUserObjectSecurity({(isDesktop ? "desktop" : "winsta")}) failed: {Marshal.GetLastWin32Error()}";
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

    [StructLayout(LayoutKind.Sequential)]
    private struct ACCESS_ALLOWED_ACE
    {
        public byte AceType;
        public byte AceFlags;
        public ushort AceSize;
        public uint Mask;
        public uint SidStart; // placeholder — actual SID follows
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
    private static extern bool GetUserObjectSecurity(
        IntPtr hObj,
        uint si,
        IntPtr pSID,
        uint nLength,
        ref uint lpnLengthNeeded);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetUserObjectSecurity(IntPtr hObj, uint si, IntPtr pSID);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSecurityDescriptorDacl(
        IntPtr pSecurityDescriptor,
        [MarshalAs(UnmanagedType.Bool)] out bool bDaclPresent,
        out IntPtr pDacl,
        [MarshalAs(UnmanagedType.Bool)] out bool bDaclDefaulted);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetSecurityDescriptorDacl(
        IntPtr pSecurityDescriptor,
        [MarshalAs(UnmanagedType.Bool)] bool bDaclPresent,
        IntPtr pDacl,
        [MarshalAs(UnmanagedType.Bool)] bool bDaclDefaulted);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeSecurityDescriptor(IntPtr pSecurityDescriptor, uint dwRevision);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetAclInformation(
        IntPtr pAcl,
        ref ACL_SIZE_INFORMATION pAclInformation,
        uint nAclInformationLength,
        uint dwAclInformationClass);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeAcl(IntPtr pAcl, uint nAclLength, uint dwAclRevision);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetAce(IntPtr pAcl, int dwAceIndex, out IntPtr pAce);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddAce(
        IntPtr pAcl,
        uint dwAceRevision,
        uint dwStartingAceIndex,
        IntPtr pAceList,
        uint nAceListLength);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddAccessAllowedAce(
        IntPtr pAcl,
        uint dwAceRevision,
        uint AccessMask,
        IntPtr pSid);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EqualSid(IntPtr pSid1, IntPtr pSid2);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int GetLengthSid(IntPtr pSid);
}
