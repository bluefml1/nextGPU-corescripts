namespace NextGPU.Core;

public static class AuthService
{
    private const string ValidUsername = "bluefml1";
    private const string ValidPassword = "letmeinpls";

    public static bool Validate(string username, string password)
    {
        return string.Equals(username?.Trim(), ValidUsername, StringComparison.Ordinal)
            && string.Equals(password, ValidPassword, StringComparison.Ordinal);
    }
}
