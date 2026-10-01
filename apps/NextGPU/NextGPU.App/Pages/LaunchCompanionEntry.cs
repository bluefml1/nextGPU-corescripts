using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace NextGPU.App.Pages;

/// <summary>One row of %ProgramData%\nextGPU\launch-companions.json (main app exe -> companion exe).</summary>
public sealed class LaunchCompanionEntry : INotifyPropertyChanged
{
    private bool _isSelected;
    private string _mainExe = "";
    private string _exeName = "";
    private string _exe = "";
    private string _searchDir = "";
    private int _delayMs = 2000;
    private string _status = "";

    public bool IsSelected
    {
        get => _isSelected;
        set => Set(ref _isSelected, value);
    }

    public string MainExe
    {
        get => _mainExe;
        set => Set(ref _mainExe, value ?? "");
    }

    public string ExeName
    {
        get => _exeName;
        set => Set(ref _exeName, value ?? "");
    }

    public string Exe
    {
        get => _exe;
        set => Set(ref _exe, value ?? "");
    }

    public string SearchDir
    {
        get => _searchDir;
        set => Set(ref _searchDir, value ?? "");
    }

    public int DelayMs
    {
        get => _delayMs;
        set => Set(ref _delayMs, Math.Clamp(value, 0, 2000));
    }

    public string Status
    {
        get => _status;
        set => Set(ref _status, value ?? "");
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void Set<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return;
        field = value;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
