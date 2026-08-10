using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace NextGPU.App.Pages;

public sealed class SessionFolderRuleEntry : INotifyPropertyChanged
{
    private bool _isSelected;
    private string _id = "";
    private string _title = "";
    private string _action = "";
    private string _target = "";
    private string _source = "";
    private string _preserveText = "";
    private string _stopProcessesText = "";
    private bool _logonFallback = true;

    public string OriginalId { get; set; } = "";

    public bool IsSelected
    {
        get => _isSelected;
        set => SetField(ref _isSelected, value);
    }

    public string Id
    {
        get => _id;
        set => SetField(ref _id, value);
    }

    public string Title
    {
        get => _title;
        set => SetField(ref _title, value);
    }

    public string Action
    {
        get => _action;
        set => SetField(ref _action, value);
    }

    public string Target
    {
        get => _target;
        set => SetField(ref _target, value);
    }

    public string Source
    {
        get => _source;
        set => SetField(ref _source, value);
    }

    public string PreserveText
    {
        get => _preserveText;
        set => SetField(ref _preserveText, value);
    }

    public string StopProcessesText
    {
        get => _stopProcessesText;
        set => SetField(ref _stopProcessesText, value);
    }

    public bool LogonFallback
    {
        get => _logonFallback;
        set => SetField(ref _logonFallback, value);
    }

    public string[] Preserve { get; set; } = [];
    public string[] StopProcesses { get; set; } = [];

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
