using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace NextGPU.Service;

public sealed class NextGPUService : BackgroundService
{
    private readonly ILogger<NextGPUService> _log;
    private readonly LaunchPipeServer _pipeServer;

    public NextGPUService(
        ILogger<NextGPUService> log,
        LaunchPipeServer pipeServer)
    {
        _log = log;
        _pipeServer = pipeServer;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        LaunchInterop.EnsureInitialized();
        _log.LogInformation("NextGPUService starting...");

        try
        {
            await _pipeServer.RunAsync(stoppingToken);
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
        {
            _log.LogInformation("NextGPUService shutting down");
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "NextGPUService encountered an error");
        }
    }

    public override void Dispose()
    {
        _pipeServer.Dispose();
        base.Dispose();
    }
}
