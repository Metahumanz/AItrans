using System.Text.Json;
using System.Text.Json.Serialization;

namespace AITrans.Core;

/// <summary>settings.json 的读写与取值范围收敛。</summary>
public sealed class SettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    public AppSettings Settings { get; private set; } = new();

    public void Load(string path)
    {
        if (!File.Exists(path)) return;
        try
        {
            var loaded = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Options);
            if (loaded is not null)
            {
                Settings = loaded.Sanitized();
            }
        }
        catch (Exception error) when (error is JsonException or IOException)
        {
            throw new AITransException("settings.json 格式不正确，已使用默认设置。");
        }
    }

    public void Save(string path)
    {
        Settings = Settings.Sanitized();
        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        File.WriteAllText(path, JsonSerializer.Serialize(Settings, Options));
    }

    public void Update(Action<AppSettings> mutate)
    {
        mutate(Settings);
        Settings = Settings.Sanitized();
    }
}
