using System.Net.Http;
using NextGPU.Core.Models;

namespace NextGPU.Core;

public sealed class HealthMonitor : IDisposable
{
    private readonly WindowsServiceManager _services;
    private readonly HttpClient _http;

    public HealthMonitor(WindowsServiceManager services)
    {
        _services = services;
        var handler = new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback = (_, _, _, _) => true
        };
        _http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) };
    }

    public async Task<HealthReport> CollectAsync(string repoRoot, CancellationToken cancellationToken = default)
    {
        var report = new HealthReport
        {
            RepoRoot = repoRoot,
            MachineName = Environment.MachineName,
            Domain = DomainFileReader.Read(repoRoot),
            RefreshedAt = DateTime.Now
        };

        foreach (var template in RepoCatalog.KnownServices)
        {
            var state = _services.GetState(template.ServiceName);
            report.Services.Add(new ServiceHealthItem
            {
                ServiceName = template.ServiceName,
                DisplayName = template.DisplayName,
                LogFileName = template.LogFileName,
                State = state,
                Detail = state.ToString()
            });
        }

        var (vddReady, vddDetail) = await Task.Run(() => PnpProbe.ProbeVdd(), cancellationToken).ConfigureAwait(false);
        var (vadReady, vadDetail) = await Task.Run(() => PnpProbe.ProbeVad(), cancellationToken).ConfigureAwait(false);
        report.VddReady = vddReady;
        report.VddDetail = vddDetail;
        report.VadReady = vadReady;
        report.VadDetail = vadDetail;

        try
        {
            using var moon = await _http.GetAsync("http://127.0.0.1:8080/", cancellationToken).ConfigureAwait(false);
            report.MoonlightHttpStatus = (int)moon.StatusCode;
            report.MoonlightHttpOk = moon.IsSuccessStatusCode;
        }
        catch
        {
            report.MoonlightHttpOk = false;
        }

        try
        {
            using var sun = await _http.GetAsync("https://localhost:47990/", cancellationToken).ConfigureAwait(false);
            report.SunshineHttpStatus = (int)sun.StatusCode;
            report.SunshineHttpOk = sun.IsSuccessStatusCode;
        }
        catch
        {
            report.SunshineHttpOk = false;
        }

        return report;
    }

    public void Dispose() => _http.Dispose();
}
