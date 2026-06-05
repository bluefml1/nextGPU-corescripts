namespace NextGPU.Core.Models;

public sealed class HealthReport
{
    public string MachineName { get; set; } = Environment.MachineName;
    public DomainInfo Domain { get; set; } = new();
    public List<ServiceHealthItem> Services { get; set; } = [];
    public bool MoonlightHttpOk { get; set; }
    public int? MoonlightHttpStatus { get; set; }
    public bool SunshineHttpOk { get; set; }
    public int? SunshineHttpStatus { get; set; }
    public bool VddReady { get; set; }
    public string? VddDetail { get; set; }
    public bool VadReady { get; set; }
    public string? VadDetail { get; set; }
    public string? RepoRoot { get; set; }
    public DateTime RefreshedAt { get; set; } = DateTime.Now;
}
