using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

public sealed class ProviderStoreTests
{
    private static Provider Sample(string id = "", string name = "测试提供商") => new()
    {
        Id = id,
        Name = name,
        BaseUrl = "https://api.example.com/v1/",
        Model = "test-model",
        ApiKey = "sk-secret",
        RequiresKey = true,
    };

    [Fact]
    public void NormalizesAndGeneratesId()
    {
        var provider = ProviderValidation.Normalize(Sample(), new HashSet<string>());
        Assert.Equal("https://api.example.com/v1", provider.BaseUrl);
        Assert.False(string.IsNullOrEmpty(provider.Id));
    }

    [Fact]
    public void RejectsInvalidUrl()
    {
        var broken = Sample();
        broken.BaseUrl = "ftp://example.com";
        Assert.Throws<AITransException>(() => ProviderValidation.Normalize(broken, new HashSet<string>()));
    }

    [Fact]
    public void RejectsEmptyName()
    {
        var broken = Sample();
        broken.Name = "   ";
        Assert.Throws<AITransException>(() => ProviderValidation.Normalize(broken, new HashSet<string>()));
    }

    [Fact]
    public void GeneratesUniqueIds()
    {
        var taken = new HashSet<string> { "provider", "provider-2" };
        var id = ProviderValidation.MakeId("Provider", taken);
        Assert.Equal("provider-3", id);
    }

    [Fact]
    public void SaveKeepsSecretsOutOfJson()
    {
        var secrets = new MemorySecretStore();
        var store = new ProviderStore(secrets);
        store.Upsert(Sample("acme"), activate: true);

        var path = Path.Combine(Path.GetTempPath(), "aitrans-providers-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            store.Save(path);
            var json = File.ReadAllText(path);
            Assert.DoesNotContain("sk-secret", json);
            Assert.Contains("\"acme\"", json);

            var reloaded = new ProviderStore(secrets);
            reloaded.Load(path);
            Assert.Equal("acme", reloaded.ActiveId);
            Assert.Equal("sk-secret", reloaded.Find("acme")!.ApiKey);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ImportsLegacyEnvFile()
    {
        var envPath = Path.Combine(Path.GetTempPath(), "aitrans-env-" + Guid.NewGuid().ToString("N"));
        File.WriteAllLines(envPath, new[]
        {
            "# 注释",
            "AI_PROVIDER=deepseek",
            "AI_PROVIDER_NAME=DeepSeek",
            "AI_API_KEY=sk-legacy",
            "AI_BASE_URL=https://api.deepseek.com",
            "AI_MODEL=deepseek-flash",
        });

        try
        {
            var store = new ProviderStore(new MemorySecretStore());
            var imported = store.ImportLegacy(null, envPath);
            Assert.Equal(1, imported);
            Assert.Equal("deepseek", store.ActiveId);
            Assert.Equal("sk-legacy", store.ActiveProvider!.ApiKey);
        }
        finally
        {
            File.Delete(envPath);
        }
    }
}

public sealed class SettingsStoreTests
{
    [Fact]
    public void SanitizesOutOfRangeValues()
    {
        var settings = new AppSettings { ApiWorkers = 999, ApiRetries = -3, Suffix = "  ", OllamaModel = "" };
        var clean = settings.Sanitized();

        Assert.Equal(64, clean.ApiWorkers);
        Assert.Equal(0, clean.ApiRetries);
        Assert.Equal("_translated", clean.Suffix);
        Assert.Equal("qwen2.5", clean.OllamaModel);
    }

    [Fact]
    public void RoundTripsWithLowercaseEnums()
    {
        var path = Path.Combine(Path.GetTempPath(), "aitrans-settings-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new SettingsStore();
            store.Update(settings =>
            {
                settings.Backend = Engine.ollama;
                settings.Lang = Language.ja;
                settings.OutputMode = OutputMode.custom;
            });
            store.Save(path);

            var json = File.ReadAllText(path);
            Assert.Contains("\"ollama\"", json);
            Assert.Contains("\"ja\"", json);
            Assert.Contains("\"custom\"", json);

            var reloaded = new SettingsStore();
            reloaded.Load(path);
            Assert.Equal(Engine.ollama, reloaded.Settings.Backend);
            Assert.Equal(Language.ja, reloaded.Settings.Lang);
            Assert.Equal(OutputMode.custom, reloaded.Settings.OutputMode);
        }
        finally
        {
            File.Delete(path);
        }
    }
}

public sealed class UpdateCheckerTests
{
    [Theory]
    [InlineData("2.0.0", "1.9.9", true)]
    [InlineData("1.0.0", "1.0.0", false)]
    [InlineData("1.0.1", "1.0.0", true)]
    [InlineData("1.10.0", "1.9.0", true)]
    [InlineData("1.0", "1.0.0", false)]
    public void ComparesVersions(string candidate, string current, bool expected)
    {
        Assert.Equal(expected, UpdateChecker.IsNewer(candidate, current));
    }
}
