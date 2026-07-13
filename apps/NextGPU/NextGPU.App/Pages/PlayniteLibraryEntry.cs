using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace NextGPU.App.Pages;

public sealed class PlayniteLibraryEntry : INotifyPropertyChanged
{
    private bool _isSelected;

    public bool IsSelected
    {
        get => _isSelected;
        set
        {
            if (_isSelected == value)
                return;
            _isSelected = value;
            OnPropertyChanged();
        }
    }

    public string Name { get; set; } = "";
    public string Source { get; set; } = "";
    public string GameId { get; set; } = "";
    public string NameId { get; set; } = "";
    public string PlayniteId { get; set; } = "";
    public string PlayPath { get; set; } = "";
    public string Exe { get; set; } = "";

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
