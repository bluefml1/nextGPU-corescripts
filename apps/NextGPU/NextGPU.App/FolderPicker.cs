using System.IO;

namespace NextGPU.App;

internal static class FolderPicker
{
    public static string? PickFolder(string? initialPath = null, string? description = null)
    {
        using var dialog = new System.Windows.Forms.FolderBrowserDialog
        {
            Description = description ?? "Select a folder",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true
        };

        var start = ResolveInitialDirectory(initialPath);
        if (!string.IsNullOrWhiteSpace(start))
            dialog.InitialDirectory = start;

        return dialog.ShowDialog() == System.Windows.Forms.DialogResult.OK
            ? dialog.SelectedPath
            : null;
    }

    private static string? ResolveInitialDirectory(string? path)
    {
        var trimmed = (path ?? "").Trim();
        if (string.IsNullOrWhiteSpace(trimmed))
            return null;

        if (Directory.Exists(trimmed))
            return trimmed;

        var parent = Path.GetDirectoryName(trimmed);
        return !string.IsNullOrWhiteSpace(parent) && Directory.Exists(parent) ? parent : null;
    }
}
