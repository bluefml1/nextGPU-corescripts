using System.Windows;

namespace NextGPU.App;

public partial class InputDialog : Window
{
    public string Result { get; private set; } = "";

    public InputDialog(string prompt, Window? owner)
    {
        InitializeComponent();
        PromptText.Text = prompt;
        if (owner is not null)
            Owner = owner;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        Result = InputBox.Text;
        DialogResult = true;
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    public static string? Show(string prompt, Window? owner)
    {
        var dlg = new InputDialog(prompt, owner);
        return dlg.ShowDialog() == true ? dlg.Result : null;
    }
}
