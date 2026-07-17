using System.Text.Json.Serialization;

namespace NextGPU.Core;

/// <summary>Provisioning fields collected by the NextGPU Register Machine UI form.</summary>
public sealed class RegisterMachineFormConfig
{
    [JsonPropertyName("enableVdd")]
    public bool EnableVdd { get; set; } = true;

    [JsonPropertyName("cfApiToken")]
    public string CfApiToken { get; set; } = "";

    [JsonPropertyName("accountId")]
    public string AccountId { get; set; } = "";

    [JsonPropertyName("apiKey")]
    public string ApiKey { get; set; } = "";

    [JsonPropertyName("computerName")]
    public string ComputerName { get; set; } = "";

    [JsonPropertyName("price")]
    public string Price { get; set; } = "";

    [JsonPropertyName("vendorId")]
    public string? VendorId { get; set; }

    [JsonPropertyName("adminAccountName")]
    public string AdminAccountName { get; set; } = "";

    [JsonPropertyName("adminPasswordEncrypted")]
    public string? AdminPasswordEncrypted { get; set; }
}
