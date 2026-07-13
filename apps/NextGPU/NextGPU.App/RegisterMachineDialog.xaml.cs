using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using NextGPU.Core;

namespace NextGPU.App;

public partial class RegisterMachineDialog : Window
{
    public RegisterMachineFormConfig? Result { get; private set; }

    public RegisterMachineDialog()
    {
        InitializeComponent();
        AdminAccountBox.Text = Environment.UserName;
        WirePasswordPlaceholder(CfTokenBox, CfTokenPlaceholder);
        WirePasswordPlaceholder(ApiKeyBox, ApiKeyPlaceholder);
        WireTextPlaceholder(PriceBox, PricePlaceholder);
    }

    private static void WirePasswordPlaceholder(PasswordBox box, TextBlock placeholder)
    {
        void Update()
        {
            placeholder.Visibility = string.IsNullOrEmpty(box.Password)
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        box.PasswordChanged += (_, _) => Update();
        box.GotFocus += (_, _) => placeholder.Visibility = Visibility.Collapsed;
        box.LostFocus += (_, _) => Update();
        Update();
    }

    private static void WireTextPlaceholder(TextBox box, TextBlock placeholder)
    {
        void Update()
        {
            placeholder.Visibility = string.IsNullOrWhiteSpace(box.Text)
                ? Visibility.Visible
                : Visibility.Collapsed;
        }

        box.TextChanged += (_, _) => Update();
        box.GotFocus += (_, _) => placeholder.Visibility = Visibility.Collapsed;
        box.LostFocus += (_, _) => Update();
        Update();
    }

    private void Cancel_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
    }

    private void Ok_Click(object sender, RoutedEventArgs e)
    {
        ErrorText.Visibility = Visibility.Collapsed;
        ErrorText.Text = "";

        var cfToken = CfTokenBox.Password.Trim();
        var accountId = AccountIdBox.Text.Trim();
        var apiKey = ApiKeyBox.Password.Trim();
        var computerName = ComputerNameBox.Text.Trim();
        var priceText = PriceBox.Text.Trim();
        var adminAccount = AdminAccountBox.Text.Trim();
        var vendorId = VendorIdBox.Text.Trim();

        if (string.IsNullOrWhiteSpace(cfToken))
        {
            ShowError("Cloudflare API Token is required.");
            return;
        }
        if (string.IsNullOrWhiteSpace(accountId))
        {
            ShowError("Cloudflare Account ID is required.");
            return;
        }
        if (string.IsNullOrWhiteSpace(apiKey))
        {
            ShowError("API Key is required.");
            return;
        }
        if (string.IsNullOrWhiteSpace(computerName))
        {
            ShowError("Computer Name is required.");
            return;
        }
        if (string.IsNullOrWhiteSpace(priceText))
        {
            ShowError("Original Price is required.");
            return;
        }
        if (!decimal.TryParse(priceText, NumberStyles.Number, CultureInfo.InvariantCulture, out _)
            && !decimal.TryParse(priceText, NumberStyles.Number, CultureInfo.CurrentCulture, out _))
        {
            ShowError("Original Price must be a valid number (e.g. 10.99).");
            return;
        }
        if (string.IsNullOrWhiteSpace(adminAccount))
        {
            ShowError("Admin account username is required.");
            return;
        }

        var enableVdd = VddCombo.SelectedItem is ComboBoxItem item
            && string.Equals(item.Content?.ToString(), "Yes", StringComparison.OrdinalIgnoreCase);

        Result = new RegisterMachineFormConfig
        {
            EnableVdd = enableVdd,
            CfApiToken = cfToken,
            AccountId = accountId,
            ApiKey = apiKey,
            ComputerName = computerName,
            Price = priceText,
            VendorId = string.IsNullOrWhiteSpace(vendorId) ? null : vendorId,
            AdminAccountName = adminAccount
        };
        DialogResult = true;
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorText.Visibility = Visibility.Visible;
    }
}
