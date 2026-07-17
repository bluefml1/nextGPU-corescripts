using System.ComponentModel;

namespace NextGPU.App.Pages;

public sealed class BypassSeedShortcutRow : INotifyPropertyChanged
{
    private bool _isSelected;

    public string Shortcut { get; init; } = "";
    public string Role { get; init; } = "";
    public string ForTitle { get; init; } = "";
    public string SeedStatus { get; init; } = "";

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected == value)
                return;
            _isSelected = value;
            PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(IsSelected)));
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;
}
