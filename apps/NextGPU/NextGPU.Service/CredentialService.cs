using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Extensions.Logging;

namespace NextGPU.Service;

// Reads the NextGPU-Admin credential from C:\ProgramData\nextGPU\admincred.dat
// and decrypts it via DPAPI LocalMachine scope. The service runs as SYSTEM and is
// the only process that should read this file (admincred.dat ACL: SYSTEM allow,
// Administrators allow, nextGPU explicit deny).
//
// The password bytes are kept in a SecureString-ish backing field; callers should
// read via ReadAdminPassword() and not retain references longer than necessary.
public sealed class CredentialService
{
    private const string CredPath = @"C:\ProgramData\nextGPU\admincred.dat";
    private const string DefaultAdminUsername = "NextGPU-Admin";
    private const string DefaultAdminDomain = ".";

    private readonly ILogger<CredentialService> _log;

    public CredentialService(ILogger<CredentialService> log)
    {
        _log = log;
    }

    // Account used for elevated launches. Mirrors the launcher's constants.
    public string AdminUsername => DefaultAdminUsername;
    public string AdminDomain => DefaultAdminDomain;

    // Decrypts admincred.dat via DPAPI LocalMachine scope. Returns null on any
    // failure (missing file, decrypt error, empty result). Tries CurrentUser as a
    // fallback so legacy installers that encrypted with the per-user scope still
    // work.
    public string? ReadAdminPassword()
    {
        if (!File.Exists(CredPath))
        {
            _log.LogError("admincred.dat not found at {Path}", CredPath);
            return null;
        }

        byte[] protectedBytes;
        try
        {
            protectedBytes = File.ReadAllBytes(CredPath);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Failed to read admincred.dat");
            return null;
        }

        foreach (DataProtectionScope scope in new[] { DataProtectionScope.LocalMachine, DataProtectionScope.CurrentUser })
        {
            try
            {
                byte[] decrypted = ProtectedData.Unprotect(protectedBytes, null, scope);
                string plain = Encoding.UTF8.GetString(decrypted);
                Array.Clear(decrypted, 0, decrypted.Length);
                if (!string.IsNullOrEmpty(plain))
                    return plain;
            }
            catch (CryptographicException)
            {
                // Try the next scope.
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "DPAPI unprotect failed for scope {Scope}", scope);
            }
        }

        _log.LogError("DPAPI unprotect failed for both LocalMachine and CurrentUser scopes");
        return null;
    }
}
