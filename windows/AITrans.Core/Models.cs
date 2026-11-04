using System.Text.Json.Serialization;

namespace AITrans.Core;

public sealed record ProviderPreset(string Id, string Name, string BaseUrl, string Model, bool RequiresKey);

public sealed class Provider
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";

    [JsonPropertyName("base_url")]
    public string BaseUrl { get; set; } = "";

    public string Model { get; set; } = "";

    [JsonPropertyName("api_key")]
    public string ApiKey { get; set; } = "";

    [JsonPropertyName("requires_key")]
    public bool RequiresKey { get; set; } = true;

    public Provider Clone() => new()
    {
        Id = Id,
        Name = Name,
        BaseUrl = BaseUrl,
        Model = Model,
        ApiKey = ApiKey,
        RequiresKey = RequiresKey,
    };
}

public enum Engine
{
    api,
    ollama,
}

public enum OutputMode
{
    source,
    output,
    custom,
}

public enum Language
{
    zh,
    en,
    ja,
    ko,
}

public static class LanguageNames
{
    public static string DisplayName(this Language language) =>
        Spec.Languages.TryGetValue(language.ToString(), out var name) ? name : "中文";
}

/// <summary>界面设置，持久化到 settings.json。</summary>
public sealed class AppSettings
{
    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("backend")] public Engine Backend { get; set; } = Engine.api;
    [JsonPropertyName("api_model")] public string ApiModel { get; set; } = "";
    [JsonPropertyName("ollama_model")] public string OllamaModel { get; set; } = "qwen2.5";
    [JsonPropertyName("lang")] public Language Lang { get; set; } = Language.zh;
    [JsonPropertyName("translate")] public bool Translate { get; set; } = true;
    [JsonPropertyName("polish")] public bool Polish { get; set; } = true;
    [JsonPropertyName("output_mode")] public OutputMode OutputMode { get; set; } = OutputMode.source;
    [JsonPropertyName("suffix")] public string Suffix { get; set; } = "_translated";
    [JsonPropertyName("custom_dir")] public string CustomDir { get; set; } = "";
    [JsonPropertyName("force")] public bool Force { get; set; }
    [JsonPropertyName("api_workers")] public int ApiWorkers { get; set; } = 20;
    [JsonPropertyName("api_retries")] public int ApiRetries { get; set; } = 2;
    [JsonPropertyName("ollama_workers")] public int OllamaWorkers { get; set; } = 2;
    [JsonPropertyName("ollama_retries")] public int OllamaRetries { get; set; } = 1;

    public AppSettings Clone() => (AppSettings)MemberwiseClone();

    /// <summary>与 v1 的 _clean_settings 对齐。</summary>
    public AppSettings Sanitized()
    {
        var copy = Clone();
        copy.Version = 1;
        copy.ApiWorkers = Math.Clamp(copy.ApiWorkers, 1, 64);
        copy.OllamaWorkers = Math.Clamp(copy.OllamaWorkers, 1, 64);
        copy.ApiRetries = Math.Clamp(copy.ApiRetries, 0, 5);
        copy.OllamaRetries = Math.Clamp(copy.OllamaRetries, 0, 5);
        if (string.IsNullOrWhiteSpace(copy.Suffix)) copy.Suffix = "_translated";
        if (string.IsNullOrWhiteSpace(copy.OllamaModel)) copy.OllamaModel = "qwen2.5";
        return copy;
    }
}

public sealed class FileResult
{
    public enum StatusKind
    {
        success,
        skipped,
        failed,
    }

    public string Name { get; set; } = "";
    public string? RelativeName { get; set; }
    public StatusKind Status { get; set; }
    public string? OutputPath { get; set; }
    public string? Error { get; set; }
    public int TranslatedCount { get; set; }
    public int ErrorCount { get; set; }
}

/// <summary>可直接展示给用户的错误。</summary>
public sealed class AITransException : Exception
{
    public AITransException(string message) : base(message)
    {
    }
}
