namespace AITrans.Core;

/// <summary>应用数据目录（Windows）。</summary>
public static class AppPaths
{
    public static string SupportDirectory =>
        Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "AITrans");

    public static string SettingsFile => Path.Combine(SupportDirectory, "settings.json");
    public static string ProvidersFile => Path.Combine(SupportDirectory, "providers.json");
    public static string SecretsFile => Path.Combine(SupportDirectory, "secrets.dat");
    public static string DefaultOutputDirectory => Path.Combine(SupportDirectory, "output");
    public static string LogDirectory => Path.Combine(SupportDirectory, "logs");

    public static void Prepare()
    {
        foreach (var directory in new[] { SupportDirectory, DefaultOutputDirectory, LogDirectory })
        {
            Directory.CreateDirectory(directory);
        }
    }
}
