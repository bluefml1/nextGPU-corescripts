using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace NextGPU.App.Pages;

public sealed class BypassSyncListEntry : INotifyPropertyChanged
{
    private bool _isSelected;
    private string _title = "";
    private string _gameId = "";
    private string _nameId = "";
    private string _shortcutName = "";
    private string _preLaunchesText = "";

    public string OriginalShortcutName { get; set; } = "";

    public bool IsSelected
    {
        get => _isSelected;
        set => SetField(ref _isSelected, value);
    }

    public string Title
    {
        get => _title;
        set => SetField(ref _title, value);
    }

    public string GameId
    {
        get => _gameId;
        set => SetField(ref _gameId, value);
    }

    public string NameId
    {
        get => _nameId;
        set => SetField(ref _nameId, value);
    }

    public string ShortcutName
    {
        get => _shortcutName;
        set => SetField(ref _shortcutName, value);
    }

    public string PreLaunchesText
    {
        get => _preLaunchesText;
        set => SetField(ref _preLaunchesText, value);
    }

    public List<BypassSyncLaunchItem> Launches { get; set; } = [];

    public event PropertyChangedEventHandler? PropertyChanged;

    private void SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return;
        field = value;
        OnPropertyChanged(propertyName);
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
