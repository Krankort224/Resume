using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace PickyVPN.App;

// The Windows product source is a CurrentUser-DPAPI blob. The engine config remains
// disposable derived state and is never used as the UI's credential source of truth.
internal static class CredentialStore
{
    private static readonly Regex Uuid = new("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", RegexOptions.CultureInvariant);
    private static string Path => ProductPaths.CredentialPath;

    internal static string? Load()
    {
        try
        {
            if (!File.Exists(Path)) return null;
            var bytes = ProtectedData.Unprotect(File.ReadAllBytes(Path), null, DataProtectionScope.CurrentUser);
            var credential = Encoding.UTF8.GetString(bytes);
            return IsValid(credential) ? credential : null;
        }
        catch (CryptographicException) { return null; }
        catch (IOException) { return null; }
    }

    internal static bool Save(string candidate)
    {
        var credential = candidate.Trim();
        if (!IsValid(credential)) return false;
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
        var temporary = Path + ".tmp";
        var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(credential), null, DataProtectionScope.CurrentUser);
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, Path, true);
        return true;
    }

    internal static void Clear()
    {
        try { File.Delete(Path); } catch (IOException) { }
    }

    internal static bool IsValid(string? credential) => credential is not null && Uuid.IsMatch(credential);
}
