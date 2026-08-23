using NextGPU.Core.Models;

namespace NextGPU.Core;

public static class RepoCatalog
{
    public static readonly IReadOnlyList<ServiceHealthItem> KnownServices =
    [
        new() { ServiceName = "cloudflared", DisplayName = "Cloudflare Tunnel", LogFileName = null },
        new() { ServiceName = "moonlight-web", DisplayName = "Moonlight Web", LogFileName = "moonlight-web.log" },
        new() { ServiceName = "gpu-sunshine", DisplayName = "GPU Sunshine", LogFileName = "sunshine.log" },
    ];

    public static readonly IReadOnlyList<ScheduledTaskTemplate> KnownScheduledTasks =
    [
        new()
        {
            TaskName = "nextGPU-Heartbeat",
            DisplayName = "GPU Heartbeat",
            Description = "Posts machine status to AWS every 5 minutes.",
            IntervalSummary = "Every 5 min",
            RegisterScriptRelativePath = @"scripts\tasks\Register-HeartbeatTask.ps1",
            StdoutLogFileName = "heartbeat.log",
            StderrLogFileName = "heartbeat-error.log"
        },
        new()
        {
            TaskName = "nextGPU-AutoRepair",
            DisplayName = "Auto-Repair",
            Description = "Health-checks cloudflared, Sunshine, Moonlight, and local HTTP every minute.",
            IntervalSummary = "Every 1 min",
            RegisterScriptRelativePath = @"scripts\tasks\Register-AutoRepairTask.ps1",
            StdoutLogFileName = "auto-repair.log",
            StderrLogFileName = "auto-repair-error.log"
        },
        new()
        {
            TaskName = "nextGPU-AutoUpdate",
            DisplayName = "Auto-Update",
            Description = "Checks Sunshine/Moonlight versions and applies updates every hour.",
            IntervalSummary = "Every 1 hour",
            RegisterScriptRelativePath = @"scripts\tasks\Register-AutoUpdateTask.ps1",
            StdoutLogFileName = "auto-update.log",
            StderrLogFileName = "auto-update-error.log"
        },
        new()
        {
            TaskName = "nextGPU-NvidiaLogon",
            DisplayName = "NVIDIA Logon",
            Description = "Starts NVIDIA App (Nvidia.exe) when any user logs on.",
            IntervalSummary = "At user logon",
            RegisterScriptRelativePath = @"scripts\tasks\Register-NvidiaLogonTask.ps1",
            ManualRunScriptRelativePath = @"scripts\provisioning\Start-Nvidia-InSession.ps1"
        },
        new()
        {
            TaskName = "nextGPU-PlayniteLogon",
            DisplayName = "Playnite Logon",
            Description = "At nextGPU logon: elevates Playnite.DesktopApp --startdesktop as NextGPU-Admin via NextGPUService.",
            IntervalSummary = "At user logon",
            RegisterScriptRelativePath = @"PlayNiteWatcher\Register-PlayniteLogonTask.ps1"
        },
        new()
        {
            TaskName = "auto game launch",
            DisplayName = "Auto Game Launch",
            Description = "At logon (SYSTEM): Sunshine launchGame.ps1 → NextGPUService. Steam = elevated steam.exe -applaunch; Epic = elevated Playnite --start; Desktop = direct exe.",
            IntervalSummary = "At user logon",
            RegisterScriptRelativePath = @"scripts\tasks\launchGameTaskScheduler.ps1",
            StdoutLogFileName = "launchGame.log"
        },
        new()
        {
            TaskName = "EndSession",
            DisplayName = "End Session",
            Description = "Runs endSession.ps1 when LogoffManager event 2002 fires.",
            IntervalSummary = "On logoff event",
            RegisterScriptRelativePath = @"scripts\tasks\Register-EndSessionTask.ps1"
        },
        new()
        {
            TaskName = "nextGPU-EndSessionRecoveryStartup",
            DisplayName = "End Session Recovery (Startup)",
            Description = "At startup (PT20S): EndSession recovery if pending flag exists; then publish updateStatus online on every boot.",
            IntervalSummary = "At startup +20s",
            RegisterScriptRelativePath = @"scripts\tasks\Register-NextGpuEndSessionRecoveryTask.ps1"
        },
        new()
        {
            TaskName = "nextGPU-SessionFolderRulesLogoff",
            DisplayName = "Session Folder Rules (Logoff)",
            Description = "Runs delete/replace session folder rules when nextGPU logs off.",
            IntervalSummary = "At nextGPU logoff",
            RegisterScriptRelativePath = @"scripts\runtime\Register-SessionFolderRulesTasks.ps1",
            StdoutLogFileName = "session-folder-rules.log"
        },
        new()
        {
            TaskName = "nextGPU-SessionFolderRulesLogon",
            DisplayName = "Session Folder Rules (Logon)",
            Description = "Verifies logoff rules completed; re-runs failed rules with logonFallback.",
            IntervalSummary = "At user logon",
            RegisterScriptRelativePath = @"scripts\runtime\Register-SessionFolderRulesTasks.ps1",
            ManualRunScriptRelativePath = @"scripts\runtime\Invoke-SessionFolderRules.ps1",
            StdoutLogFileName = "session-folder-rules.log"
        }
    ];

    public const string TaskSchedulerOrchestratorRelativePath = @"scripts\tasks\TaskScheduler.ps1";
    public const string TaskSchedulerVerifyRelativePath = @"scripts\tasks\Test-TaskSchedulerSetup.ps1";

    public static readonly IReadOnlyList<string> KnownLogFiles =
    [
        "nextgpu-controller.log",
        "wmi-probe.log",
        "sunshine-bind.log",
        "VDD-VAD.log",
        "ViGEmBus.log",
        "register_api_log.txt",
        "heartbeat.log",
        "heartbeat-error.log",
        "auto-repair.log",
        "auto-repair-error.log",
        "auto-update.log",
        "auto-update-error.log",
        "checking-update.log",
        "moonlight-web.log",
        "moonlight-web-error.log",
        "sunshine.log",
        "sunshine-error.log",
        "network_copy.log",
        "session-folder-rules.log",
        "uninstall-nextgpu.log",
    ];

    public const string SunshineExe = @"C:\Program Files\Sunshine\sunshine.exe";
    public const string SunshineServiceName = "gpu-sunshine";

    public const string PlayNiteWatcherRelativeDir = "PlayNiteWatcher";
    public const string PlayniteInstallPathFile = "PlayniteInstall.path";
    public const string PlayniteAllowlistRelativePath = @"PlayNiteWatcher\config\playnite\desktop-apps.allowlist.json";

    public const string PlayniteSetupLog = "Setup-PlayniteSteam.log";
    public const string PlayniteExportLog = "Export-SunshineFromPlaynite.log";
    public const string PlayniteWatcherInstallLog = "Install-PlayniteWatcher.log";
    public const string PlayniteLibraryUpdateLog = "Update-PlayniteLibraries.log";
    public const string PlayniteDesktopImportLog = "Import-PlayniteDesktopApps.log";
    public const string PlayniteWatcherRuntimeLog = "log.txt";

    public const string SessionFolderRulesLog = "session-folder-rules.log";
    public const string SessionFolderRulesTemplateRelativePath = @"config\session-folder-rules.json.template";
}
