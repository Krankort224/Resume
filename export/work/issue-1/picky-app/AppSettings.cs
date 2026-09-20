using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PickyVPN.App;

internal enum KillSwitchModeChoice
{
    Soft,
    Strict,
}

internal sealed record AppSettings(
    [property: JsonPropertyName("schema")] string Schema,
    [property: JsonPropertyName("kill_switch_enabled")] bool KillSwitchEnabled,
    [property: JsonPropertyName("kill_switch_mode")] KillSwitchModeChoice KillSwitchMode)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        Converters = { new JsonStringEnumConverter() },
    };

    internal static AppSettings Default => new("pickyvpn-app-settings-v1", false, KillSwitchModeChoice.Soft);

    internal static AppSettings Load()
    {
        try
        {
            if (!File.Exists(SettingsPath)) return Default;
            var settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(SettingsPath), JsonOptions);
            return settings?.Schema == "pickyvpn-app-settings-v1" ? settings : Default;
        }
        catch
        {
            return Default;
        }
    }

    internal void Save()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(SettingsPath)!);
        var temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, JsonOptions));
        File.Move(temporary, SettingsPath, true);
    }

    private static string SettingsPath => ProductPaths.SettingsPath;
}
