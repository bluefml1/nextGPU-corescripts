using NextGPU.Core.Models;

namespace NextGPU.Core;

public static class DomainFileReader
{
    public static DomainInfo Read(string repoRoot)
    {
        var info = new DomainInfo();
        var path = RepoRootResolver.DomainFile(repoRoot);
        if (!File.Exists(path))
            return info;

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
                case "STATUS":
                    info.Status = value;
                    break;
            }
        }

        return info;
    }
}
