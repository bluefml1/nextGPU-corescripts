namespace NextGPU.Core.Models;

public enum ScheduledTaskState
{
    Unknown,
    Ready,
    Disabled,
    NotInstalled,
    Running
}

public sealed class ScheduledTaskTemplate
{
    public required string TaskName { get; init; }
    public required string DisplayName { get; init; }
    public string? Description { get; init; }
    public string? IntervalSummary { get; init; }
    public string? RegisterScriptRelativePath { get; init; }
    public string? StdoutLogFileName { get; init; }
    public string? StderrLogFileName { get; init; }
    public string? ManualRunScriptRelativePath { get; init; }
}

public sealed class ScheduledTaskItem
{
    public required string TaskName { get; init; }
    public required string DisplayName { get; init; }
    public string? Description { get; init; }
    public string? IntervalSummary { get; init; }
    public string? RegisterScriptRelativePath { get; init; }
    public string? StdoutLogFileName { get; init; }
    public string? StderrLogFileName { get; init; }
    public string? ManualRunScriptRelativePath { get; init; }
    public ScheduledTaskState State { get; set; }
    public string? LastRunTime { get; set; }
    public string? NextRunTime { get; set; }
    public int? LastResult { get; set; }
    public string? TaskToRun { get; set; }
    public string? Detail { get; set; }
}
