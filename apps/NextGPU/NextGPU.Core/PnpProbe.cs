namespace NextGPU.Core;

public static class PnpProbe
{
    private const string VddCommand =
        "$d=Get-PnpDevice -EA 0|?{$_.InstanceId -like 'DISPLAY\\MTT1337*' -and $_.Status -eq 'OK'}|select -First 1;if($d){'OK:'+$d.InstanceId;exit 0};'WARN:No VDD';exit 1";

    private const string VadCommand =
        "$d=Get-PnpDevice -EA 0|?{$_.InstanceId -like 'ROOT\\VirtualAudioDriver*'}|select -First 1;if($d -and $d.Status -eq 'OK'){'OK:'+$d.InstanceId;exit 0};if($d){'WARN:'+$d.Status;exit 1};'WARN:Not installed';exit 1";

    public static (bool Ready, string Detail) ProbeVdd() => RunProbe(VddCommand);

    public static (bool Ready, string Detail) ProbeVad() => RunProbe(VadCommand);

    private static (bool Ready, string Detail) RunProbe(string command)
    {
        try
        {
            var psi = new System.Diagnostics.ProcessStartInfo("powershell.exe",
                $"-NoLogo -NoProfile -ExecutionPolicy Bypass -Command \"{command}\"")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };
            using var p = System.Diagnostics.Process.Start(psi);
            if (p is null)
                return (false, "PowerShell failed to start");
            var output = p.StandardOutput.ReadToEnd().Trim();
            p.WaitForExit(30000);
            var ready = p.ExitCode == 0 && output.StartsWith("OK:", StringComparison.Ordinal);
            return (ready, string.IsNullOrWhiteSpace(output) ? $"Exit {p.ExitCode}" : output);
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }
}
