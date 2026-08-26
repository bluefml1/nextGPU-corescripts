using NextGPU.Core.Models;

namespace NextGPU.Core;

public static class DomainFileReader
{
    private static readonly string MachineStatusFlagPath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "nextGPU", "machine-status.flag");

    public static DomainInfo Read(string repoRoot)
    {
        var info = new DomainInfo();
        var path = RepoRootResolver.DomainFile(repoRoot);
        if (File.Exists(path))
        {
            foreach (var line in File.ReadAllLines(path))
            {
                var idx = line.IndexOf('=');
                if (idx <= 0)
                    continue;
                var key = line[..idx].Trim();
                var value = line[(idx + 1)..].Trim();
                switch (key.ToUpperInvariant())
                {
                    case "DOMAIN":
                        info.Domain = value;
                        break;
                    case "PUBLIC_IP":
                        info.PublicIp = value;
                        break;
                    case "COMPUTER_NAME":
                        info.ComputerName = value;
                        break;
                    // STATUS no longer lives in domain.txt; see machine-status.flag
                }
            }
        }

        info.Status = ReadMachineStatusFlag();
        return info;
    }

    private static string? ReadMachineStatusFlag()
    {
        try
        {
            if (!File.Exists(MachineStatusFlagPath))
                return "online";

            var raw = File.ReadAllText(MachineStatusFlagPath).Trim();
            if (string.IsNullOrWhiteSpace(raw))
                return "online";

            var status = raw.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries)[0]
                .Trim()
                .ToLowerInvariant();
            return status is "online" or "updating" or "update_fail" ? status : "online";
        }
        catch
        {
            return "online";
        }
    }
}
