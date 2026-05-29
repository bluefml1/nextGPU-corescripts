using System.Windows;
using System.Windows.Controls;
using NextGPU.Core;

namespace NextGPU.App.Pages;

public partial class LoginPage : Page
{
    private readonly Action _onSuccess;

    public LoginPage(Action onSuccess)
    {
        _onSuccess = onSuccess;
        InitializeComponent();
        UsernameBox.Text = "bluefml1";
    }

    private void SignIn_Click(object sender, RoutedEventArgs e)
    {
        if (!AuthService.Validate(UsernameBox.Text, PasswordBox.Password))
        {
            ErrorText.Text = "Invalid username or password.";
            ErrorText.Visibility = Visibility.Visible;
            return;
        }

        ErrorText.Visibility = Visibility.Collapsed;
        _onSuccess();
    }
}
