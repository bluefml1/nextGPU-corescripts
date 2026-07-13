using System.IO;
using System.Text.Json;
using System.Windows;
using NextGPU.Core;

namespace NextGPU.App;

public static class RegisterMachineLauncher
{
    public const string UiConfigFileName = "register-machine-ui-config.json";

    public static void RunWithForm(Window? owner, bool keepConsoleOpen = true)
    {
        if (string.IsNullOrWhiteSpace(App.Session.RepoRoot) || App.Session.Scripts is null)
        {
            MessageBox.Show("Repo not configured.", "NextGPU", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        var dialog = new RegisterMachineDialog();
        if (owner is not null)
            dialog.Owner = owner;
        if (dialog.ShowDialog() != true || dialog.Result is null)
            return;

        var logsDir = Path.Combine(App.Session.RepoRoot, "logs");
        Directory.CreateDirectory(logsDir);
        var configPath = Path.Combine(logsDir, UiConfigFileName);

        var json = JsonSerializer.Serialize(dialog.Result, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(configPath, json);

        var args = "/UiConfig";
        var r = App.Session.Scripts.RunBatchRelative(
            @"RegisterMachine_Beta.bat",
            elevated: true,
            arguments: args,
            keepConsoleOpen: keepConsoleOpen);

        MessageBox.Show(r.Message, "NextGPU", MessageBoxButton.OK,
            r.Success ? MessageBoxImage.Information : MessageBoxImage.Warning);
    }
}
