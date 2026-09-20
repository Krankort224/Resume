using System.IO;

namespace PickyVPN.App;

// Product-owned mutable state is deliberately below app/. The parent also owns
// developer secrets and toolchains and must never be claimed by product cleanup.
internal static class ProductPaths
{
    private static readonly string LocalRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "PickyVPN");

    internal static string AppStateRoot => Path.Combine(LocalRoot, "app");
    internal static string SettingsPath => Path.Combine(AppStateRoot, "settings.json");
    internal static string CredentialPath => Path.Combine(AppStateRoot, "credential.bin");
    internal static string RuntimeRoot => Path.Combine(AppStateRoot, "runtime");

}
