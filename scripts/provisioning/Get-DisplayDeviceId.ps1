#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Compute Sunshine output_name device_id using the same algorithm as libdisplaydevice.

.DESCRIPTION
  Source: LizardByte/libdisplaydevice src/windows/win_api_layer.cpp
           WinApiLayer::getDeviceId() + getInstanceIdAndEdid()
  https://github.com/LizardByte/libdisplaydevice/blob/master/src/windows/win_api_layer.cpp

  Pipeline (per display path in QueryDisplayConfig):
    1. DisplayConfigGetDeviceInfo(GET_TARGET_NAME) -> monitorDevicePath
    2. SetupDiEnumDeviceInterfaces(Monitor GUID) -> match device path
    3. SetupDiGetDeviceInstanceIdW -> instance id (DISPLAY\...\&...\&UID...)
    4. SetupDiOpenDevRegKey -> RegQueryValueExW("EDID")
    5. device_id_data = EDID bytes
                      + wchar bytes instance[0 .. 2nd '&')
                      + wchar bytes instance[3rd '&' .. end)
    6. UUID = SHA1(name_generator_sha1, namespace=0) -> RFC 4122 v5 string

  NOT derived from Get-PnpDevice InstanceId alone (that can disagree with the path Sunshine uses).
#>
param(
    [string]$HardwareId = 'MTT1337',
    [string]$ManufacturerId = 'MTT',
    [string]$ProductCode = '1337',
    [switch]$ListAll,
    [switch]$IncludeInactive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not ('DisplayConfigHelper' -as [type])) {
    $prevWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    $csharp = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

public static class DisplayConfigHelper
{
    private static readonly Guid MonitorInterfaceClass =
        new Guid(0xe6f07b5f, 0xee97, 0x4a90, 0xb0, 0x76, 0x33, 0xf5, 0x7b, 0xf4, 0xea, 0xa7);

    private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;
    private const uint QDC_ALL_PATHS = 0x00000001;
    private const uint DISPLAYCONFIG_PATH_ACTIVE = 0x00000001;
    private const uint DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2;
    private const int ERROR_SUCCESS = 0;
    private const int ERROR_INSUFFICIENT_BUFFER = 122;

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID
    {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_TARGET_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint outputTechnology;
        public uint rotation;
        public uint scaling;
        public DISPLAYCONFIG_RATIONAL refreshRate;
        public uint scanLineOrdering;
        [MarshalAs(UnmanagedType.Bool)] public bool targetAvailable;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_RATIONAL
    {
        public uint Numerator;
        public uint Denominator;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_SOURCE_INFO
    {
        public LUID adapterId;
        public uint id;
        public uint modeInfoIdx;
        public uint statusFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_MODE_INFO
    {
        public uint infoType;
        public uint id;
        public LUID adapterId;
        public uint modeInfoIdx;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_PATH_INFO
    {
        public DISPLAYCONFIG_PATH_SOURCE_INFO sourceInfo;
        public DISPLAYCONFIG_PATH_TARGET_INFO targetInfo;
        public uint flags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DISPLAYCONFIG_DEVICE_INFO_HEADER
    {
        public DISPLAYCONFIG_DEVICE_INFO_TYPE type;
        public uint size;
        public LUID adapterId;
        public uint id;
    }

    private enum DISPLAYCONFIG_DEVICE_INFO_TYPE : uint
    {
        DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME = 2
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct DISPLAYCONFIG_TARGET_DEVICE_NAME
    {
        public DISPLAYCONFIG_DEVICE_INFO_HEADER header;
        public uint flags;
        public uint outputTechnology;
        public ushort edidManufactureId;
        public ushort edidProductCodeId;
        public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string monitorFriendlyDeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string monitorDevicePath;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVICE_INTERFACE_DATA
    {
        public int cbSize;
        public Guid InterfaceClassGuid;
        public int Flags;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct SP_DEVINFO_DATA
    {
        public int cbSize;
        public Guid ClassGuid;
        public int DevInst;
        public IntPtr Reserved;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SP_DEVICE_INTERFACE_DETAIL_DATA
    {
        public int cbSize;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1)]
        public string DevicePath;
    }

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPathArrayElements, out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(
        uint flags,
        ref uint numPathArrayElements,
        [Out] DISPLAYCONFIG_PATH_INFO[] pathArray,
        ref uint numModeInfoArrayElements,
        [Out] DISPLAYCONFIG_MODE_INFO[] modeInfoArray,
        IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int DisplayConfigGetDeviceInfo(ref DISPLAYCONFIG_DEVICE_INFO_HEADER deviceInfo);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr SetupDiGetClassDevs(ref Guid classGuid, string enumerator, IntPtr hwndParent, uint flags);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiEnumDeviceInterfaces(IntPtr deviceInfoSet, IntPtr deviceInfoData, ref Guid interfaceClassGuid, uint memberIndex, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInterfaceDetail(IntPtr deviceInfoSet, ref SP_DEVICE_INTERFACE_DATA deviceInterfaceData, IntPtr deviceInterfaceDetailData, uint deviceInterfaceDetailDataSize, out uint requiredSize, ref SP_DEVINFO_DATA deviceInfoData);

    [DllImport("setupapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool SetupDiGetDeviceInstanceId(IntPtr deviceInfoSet, ref SP_DEVINFO_DATA deviceInfoData, StringBuilder deviceInstanceId, int deviceInstanceIdSize, out int requiredSize);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern IntPtr SetupDiOpenDevRegKey(IntPtr deviceInfoSet, ref SP_DEVINFO_DATA deviceInfoData, uint scope, uint hwProfile, uint keyType, uint samDesired);

    [DllImport("setupapi.dll", SetLastError = true)]
    private static extern bool SetupDiDestroyDeviceInfoList(IntPtr deviceInfoSet);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int RegQueryValueEx(IntPtr hKey, string lpValueName, IntPtr lpReserved, out uint lpType, byte[] lpData, ref uint lpcbData);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern int RegCloseKey(IntPtr hKey);

    private const uint DIGCF_PRESENT = 0x00000002;
    private const uint DIGCF_DEVICEINTERFACE = 0x00000010;
    private const uint DICS_FLAG_GLOBAL = 0x00000001;
    private const uint DIREG_DEV = 0x00000001;
    private const uint KEY_READ = 0x20019;

    public sealed class DeviceRecord
    {
        public string DeviceId { get; set; }
        public string InstanceId { get; set; }
        public string DevicePath { get; set; }
        public string DisplayName { get; set; }
        public bool Active { get; set; }
        public byte[] Edid { get; set; }
    }

    private static string ToUuidV5Sha1(byte[] nameBytes)
    {
        var ns = new byte[16];
        var hashInput = new byte[ns.Length + nameBytes.Length];
        Buffer.BlockCopy(ns, 0, hashInput, 0, ns.Length);
        Buffer.BlockCopy(nameBytes, 0, hashInput, ns.Length, nameBytes.Length);
        var hash = SHA1.Create().ComputeHash(hashInput);
        var b = new byte[16];
        Array.Copy(hash, 0, b, 0, 16);
        b[6] = (byte)((b[6] & 0x0F) | 0x50);
        b[8] = (byte)((b[8] & 0x3F) | 0x80);
        return "{" + new Guid(b).ToString("D").ToLowerInvariant() + "}";
    }

    private static string ComputeDeviceId(string instanceId, byte[] edid)
    {
        var data = new List<byte>();
        if (edid != null && edid.Length > 0)
            data.AddRange(edid);

        var unstable = instanceId.IndexOf('&');
        if (unstable >= 0)
            unstable = instanceId.IndexOf('&', unstable + 1);
        if (unstable < 0)
            throw new InvalidOperationException("Failed to split instance id (stable part): " + instanceId);

        var semiStable = instanceId.IndexOf('&', unstable + 1);
        if (semiStable < 0)
            throw new InvalidOperationException("Failed to split instance id (semi-stable part): " + instanceId);

        var part1 = instanceId.Substring(0, unstable);
        var part2 = instanceId.Substring(semiStable);
        data.AddRange(Encoding.Unicode.GetBytes(part1));
        data.AddRange(Encoding.Unicode.GetBytes(part2));

        if (data.Count == 0)
            throw new InvalidOperationException("Empty device_id payload");

        return ToUuidV5Sha1(data.ToArray());
    }

    private static byte[] ReadEdid(IntPtr devInfo, ref SP_DEVINFO_DATA devInfoData)
    {
        var hKey = SetupDiOpenDevRegKey(devInfo, ref devInfoData, DICS_FLAG_GLOBAL, 0, DIREG_DEV, KEY_READ);
        if (hKey == IntPtr.Zero || hKey == new IntPtr(-1))
            return null;

        try
        {
            uint type, size = 0;
            var rc = RegQueryValueEx(hKey, "EDID", IntPtr.Zero, out type, null, ref size);
            if (rc != ERROR_SUCCESS || size == 0)
                return null;
            var buf = new byte[size];
            rc = RegQueryValueEx(hKey, "EDID", IntPtr.Zero, out type, buf, ref size);
            return rc == ERROR_SUCCESS ? buf : null;
        }
        finally
        {
            RegCloseKey(hKey);
        }
    }

    private static bool TryGetInstanceIdAndEdid(string devicePath, out string instanceId, out byte[] edid)
    {
        instanceId = null;
        edid = null;
        var guid = MonitorInterfaceClass;
        var devInfo = SetupDiGetClassDevs(ref guid, null, IntPtr.Zero, DIGCF_PRESENT | DIGCF_DEVICEINTERFACE);
        if (devInfo == IntPtr.Zero || devInfo == new IntPtr(-1))
            return false;

        try
        {
            var ifData = new SP_DEVICE_INTERFACE_DATA { cbSize = Marshal.SizeOf(typeof(SP_DEVICE_INTERFACE_DATA)) };
            for (uint i = 0; ; i++)
            {
                if (!SetupDiEnumDeviceInterfaces(devInfo, IntPtr.Zero, ref guid, i, ref ifData))
                    break;

                uint required = 0;
                var devData = new SP_DEVINFO_DATA { cbSize = Marshal.SizeOf(typeof(SP_DEVINFO_DATA)) };
                SetupDiGetDeviceInterfaceDetail(devInfo, ref ifData, IntPtr.Zero, 0, out required, ref devData);
                if (required == 0)
                    continue;

                var detail = Marshal.AllocHGlobal((int)required);
                try
                {
                    Marshal.WriteInt32(detail, IntPtr.Size == 8 ? 8 : 6);
                    if (!SetupDiGetDeviceInterfaceDetail(devInfo, ref ifData, detail, required, out required, ref devData))
                        continue;

                    var pathPtr = detail + Marshal.SizeOf(typeof(int));
                    var path = Marshal.PtrToStringUni(pathPtr);
                    if (!string.Equals(path, devicePath, StringComparison.OrdinalIgnoreCase))
                        continue;

                    var sb = new StringBuilder(512);
                    int need;
                    if (!SetupDiGetDeviceInstanceId(devInfo, ref devData, sb, sb.Capacity, out need))
                        continue;
                    if (need > sb.Capacity)
                    {
                        sb = new StringBuilder(need);
                        if (!SetupDiGetDeviceInstanceId(devInfo, ref devData, sb, sb.Capacity, out need))
                            continue;
                    }

                    instanceId = sb.ToString();
                    edid = ReadEdid(devInfo, ref devData);
                    return !string.IsNullOrEmpty(instanceId);
                }
                finally
                {
                    Marshal.FreeHGlobal(detail);
                }
            }
        }
        finally
        {
            SetupDiDestroyDeviceInfoList(devInfo);
        }

        return false;
    }

    private static string GetMonitorDevicePath(DISPLAYCONFIG_PATH_INFO path)
    {
        var target = new DISPLAYCONFIG_TARGET_DEVICE_NAME
        {
            header = new DISPLAYCONFIG_DEVICE_INFO_HEADER
            {
                type = DISPLAYCONFIG_DEVICE_INFO_TYPE.DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME,
                size = (uint)Marshal.SizeOf(typeof(DISPLAYCONFIG_TARGET_DEVICE_NAME)),
                adapterId = path.targetInfo.adapterId,
                id = path.targetInfo.id
            }
        };

        var rc = DisplayConfigGetDeviceInfo(ref target.header);
        return rc == ERROR_SUCCESS ? target.monitorDevicePath : null;
    }

    private static DISPLAYCONFIG_PATH_INFO[] QueryPaths(uint flags)
    {
        uint pathCount, modeCount;
        var err = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
        if (err != ERROR_SUCCESS)
            throw new InvalidOperationException("GetDisplayConfigBufferSizes failed: " + err);

        var paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
        var modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
        err = QueryDisplayConfig(flags, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        if (err == ERROR_INSUFFICIENT_BUFFER)
        {
            paths = new DISPLAYCONFIG_PATH_INFO[pathCount];
            modes = new DISPLAYCONFIG_MODE_INFO[modeCount];
            err = QueryDisplayConfig(flags, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
        }
        if (err != ERROR_SUCCESS)
            throw new InvalidOperationException("QueryDisplayConfig failed: " + err);

        if (pathCount < paths.Length)
        {
            var trimmed = new DISPLAYCONFIG_PATH_INFO[pathCount];
            Array.Copy(paths, trimmed, pathCount);
            return trimmed;
        }
        return paths;
    }

    public static List<DeviceRecord> EnumerateDisplayDeviceIds(bool activeOnly)
    {
        var flags = activeOnly ? QDC_ONLY_ACTIVE_PATHS : QDC_ALL_PATHS;
        var paths = QueryPaths(flags);
        var list = new List<DeviceRecord>();

        foreach (var path in paths)
        {
            var devicePath = GetMonitorDevicePath(path);
            if (string.IsNullOrEmpty(devicePath))
                continue;

            string instanceId = string.Empty;
            byte[] edid = null;
            string deviceId;

            if (TryGetInstanceIdAndEdid(devicePath, out instanceId, out edid))
            {
                try
                {
                    deviceId = ComputeDeviceId(instanceId, edid);
                }
                catch
                {
                    deviceId = ToUuidV5Sha1(Encoding.Unicode.GetBytes(devicePath));
                }
            }
            else
            {
                // No EDID in registry (common for RDP / some virtual heads). Same fallback Sunshine uses.
                deviceId = ToUuidV5Sha1(Encoding.Unicode.GetBytes(devicePath));
            }

            list.Add(new DeviceRecord
            {
                DeviceId = deviceId,
                InstanceId = instanceId,
                DevicePath = devicePath,
                DisplayName = devicePath,
                Active = (path.flags & DISPLAYCONFIG_PATH_ACTIVE) != 0,
                Edid = edid
            });
        }

        return list;
    }

    public static ushort ParseEdidManufacturer(byte[] edid)
    {
        if (edid == null || edid.Length < 11) return 0;
        return (ushort)(((edid[8] & 0xFF) << 8) | (edid[9] & 0xFF));
    }

    public static ushort ParseEdidProduct(byte[] edid)
    {
        if (edid == null || edid.Length < 12) return 0;
        return (ushort)(((edid[10] & 0xFF) << 8) | (edid[11] & 0xFF));
    }

    public static string ManufacturerCode(ushort id)
    {
        var c1 = (char)(((id >> 10) & 0x1F) + 64);
        var c2 = (char)(((id >> 5) & 0x1F) + 64);
        var c3 = (char)((id & 0x1F) + 64);
        return new string(new[] { c1, c2, c3 });
    }
}
'@
    try {
        Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop
    } finally {
        $WarningPreference = $prevWarningPreference
    }
}

function Test-EdidMatch {
    param([byte[]]$Edid, [string]$Mfg, [string]$Product)
    if (-not $Edid -or $Edid.Length -lt 12) { return $false }
    $mfgCode = [DisplayConfigHelper]::ManufacturerCode([DisplayConfigHelper]::ParseEdidManufacturer($Edid))
    $prod = [DisplayConfigHelper]::ParseEdidProduct($Edid)
    $prodHex = '{0:x4}' -f $prod
    return ($mfgCode -eq $Mfg) -and (($Product -eq $prodHex) -or ($Product -eq "$prod"))
}

$devices = [DisplayConfigHelper]::EnumerateDisplayDeviceIds(-not $IncludeInactive.IsPresent)

if ($ListAll) {
    if ($devices.Count -eq 0) {
        Write-Host 'No display paths from QueryDisplayConfig (Windows sees no monitors to enumerate).'
        Write-Host ''
        Write-Host 'PnP Display class:'
        $pnp = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
        if ($pnp.Count -eq 0) {
            Write-Host '  (none)'
        } else {
            foreach ($p in $pnp) {
                $prob = if ($null -ne $p.Problem) { $p.Problem } else { '' }
                Write-Host ("  [{0}] {1}  Problem={2}" -f $p.Status, $p.InstanceId, $prob)
            }
        }
        Write-Host ''
        Write-Host 'If Sunshine log shows a device_id JSON block, you can set output_name to that UUID.'
        Write-Host 'If you need a headless VDD: run InstallVDD-VAD.bat, reboot, enable MTT1337 in Device Manager.'
        exit 1
    }
    foreach ($d in $devices) {
        $mfg = if ($d.Edid) { [DisplayConfigHelper]::ManufacturerCode([DisplayConfigHelper]::ParseEdidManufacturer($d.Edid)) } else { 'no-edid' }
        $prod = if ($d.Edid) { '{0:x4}' -f [DisplayConfigHelper]::ParseEdidProduct($d.Edid) } else { '-' }
        Write-Host ("[{0}] {1}" -f $(if ($d.Active) { 'active' } else { 'inactive' }), $d.DeviceId)
        Write-Host ("      instance: {0}" -f $(if ($d.InstanceId) { $d.InstanceId } else { '(path-only)' }))
        Write-Host ("      path: {0}" -f $d.DevicePath)
        Write-Host ("      edid: {0} / {1}" -f $mfg, $prod)
    }
    exit 0
}

$match = $devices | Where-Object {
    ($HardwareId -and $_.InstanceId -like "*$HardwareId*") -or
    (Test-EdidMatch -Edid $_.Edid -Mfg $ManufacturerId -Product $ProductCode)
} | Select-Object -First 1

if (-not $match) {
    $match = $devices | Where-Object { $_.InstanceId -like '*MTT1337*' } | Select-Object -First 1
}

if (-not $match) {
    [Console]::Error.WriteLine("No VDD display path matched (HardwareId='$HardwareId', EDID $ManufacturerId/$ProductCode). Use -ListAll -IncludeInactive.")
    exit 1
}

# stdout must be only the device id (RegisterMachine_Beta.bat parses this for DISPLAY_DEVICE_ID / logging).
[Console]::Out.WriteLine($match.DeviceId)
