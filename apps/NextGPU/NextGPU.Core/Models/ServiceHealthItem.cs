namespace NextGPU.Core.Models;

public enum ServiceRunState
{
    Unknown,
    Running,
    Stopped,
    NotInstalled
}

public sealed class ServiceHealthItem
{
    public required string ServiceName { get; init; }
    public required string DisplayName { get; init; }
    public ServiceRunState State { get; set; }
    public string? Detail { get; set; }
    public string? LogFileName { get; init; }
}
