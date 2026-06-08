using NextGPU.Core.Models;

namespace NextGPU.Core;

public static class RepoCatalog
{
    public static readonly IReadOnlyList<ServiceHealthItem> KnownServices =
    [
        new() { ServiceName = "cloudflared", DisplayName = "Cloudflare Tunnel", LogFileName = null },
        new() { ServiceName = "moonlight-web", DisplayName = "Moonlight Web", LogFileName = "moonlight-web.log" },
        new() { ServiceName = "gpu-heartbeat", DisplayName = "GPU Heartbeat", LogFileName = "heartbeat.log" },
        new() { ServiceName = "auto-repair", DisplayName = "Auto-Repair", LogFileName = "auto-repair.log" },
        new() { ServiceName = "gpu-sunshine", DisplayName = "GPU Sunshine", LogFileName = "sunshine.log" },
    ];

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
        "checking-update.log",
        "moonlight-web.log",
        "moonlight-web-error.log",
        "sunshine.log",
        "sunshine-error.log",
        "network_copy.log",
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
    public const string PlayniteWatcherRuntimeLog = "log.txt";
}
