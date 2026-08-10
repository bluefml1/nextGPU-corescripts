using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.EventLog;
using NextGPU.Service;

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService();

var logDir = Path.Combine(
    Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
    "NextGPU", "Logs");
Directory.CreateDirectory(logDir);
var logFile = Path.Combine(logDir, "NextGPUService.log");

builder.Logging.ClearProviders();
builder.Logging.AddEventLog(new EventLogSettings
{
    SourceName = "NextGPUService",
    LogName = "Application"
});
builder.Logging.AddSimpleConsole(o =>
{
    o.SingleLine = true;
    o.TimestampFormat = "HH:mm:ss.fff ";
});
builder.Logging.AddProvider(new FileLoggerProvider(logFile));
builder.Logging.SetMinimumLevel(LogLevel.Debug);

builder.Services
    .AddSingleton<AllowlistService>()
    .AddSingleton<CredentialService>()
    .AddSingleton<SessionLauncher>()
    .AddSingleton<ElevatedLauncher>()
    .AddSingleton<LaunchPipeServer>()
    .AddHostedService<NextGPUService>();

var host = builder.Build();
host.Run();
