using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace NextGPU.App.Pages;

public sealed class PlayniteAllowlistEntry : INotifyPropertyChanged
{
    private bool _isSelected;
    private bool _skipAclGrant;

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

    public string Exe { get; set; } = "";
    public string NameId { get; set; } = "";
    public string Title { get; set; } = "";
    public string Type { get; set; } = "";

    public bool SkipAclGrant
    {
        get => _skipAclGrant;
        set
        {
            if (_skipAclGrant == value)
                return;
            _skipAclGrant = value;
            OnPropertyChanged();
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
}
