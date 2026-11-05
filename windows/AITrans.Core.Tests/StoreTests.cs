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
    public void UpsertWithoutKeyKeepsExistingSecret()
    {
        var secrets = new MemorySecretStore();
        var store = new ProviderStore(secrets);
        store.Upsert(Sample("acme"), activate: true);

        var cleared = Sample("acme");
        cleared.ApiKey = "";
        store.Upsert(cleared);

        Assert.Equal("sk-secret", secrets.Get("acme"));
        Assert.Equal("", store.Find("acme")!.ApiKey);
    }

    [Fact]
    public void HydrateRestoresKeyLeftEmptyInMemory()
    {
        var secrets = new MemorySecretStore();
        var store = new ProviderStore(secrets);
        store.Upsert(Sample("acme"), activate: true);

        var cleared = Sample("acme");
        cleared.ApiKey = "";
        store.Upsert(cleared);

        var hydrated = store.Hydrate(store.Find("acme")!);

        Assert.Equal("sk-secret", hydrated.ApiKey);
        Assert.Equal("", store.Find("acme")!.ApiKey); // 补齐只返回副本，不改列表条目
    }

    [Fact]
    public void HydrateSkipsSecretStoreWhenKeyAlreadyLoaded()
    {
        var secrets = new CountingSecretStore(new MemorySecretStore());
        var store = new ProviderStore(secrets);
        store.Upsert(Sample("acme"), activate: true);

        var hydrated = store.Hydrate(store.Find("acme")!);

        Assert.Equal("sk-secret", hydrated.ApiKey);
        Assert.Equal(0, secrets.Reads);
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

    /// <summary>统计读次数，用来断言 Hydrate 不会多余地碰密钥存储。</summary>
    private sealed class CountingSecretStore : ISecretStore
    {
        private readonly ISecretStore _inner;

        public CountingSecretStore(ISecretStore inner) => _inner = inner;

        public int Reads { get; private set; }

        public string? Get(string id)
        {
            Reads++;
            return _inner.Get(id);
        }

        public void Set(string id, string value) => _inner.Set(id, value);

        public void Delete(string id) => _inner.Delete(id);
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

    [Fact]
    public void AutoCheckDefaultsToOnAndRoundTrips()
    {
        var path = Path.Combine(Path.GetTempPath(), "aitrans-settings-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            var store = new SettingsStore();
            Assert.True(store.Settings.AutoCheckUpdates);

            store.Update(settings => settings.AutoCheckUpdates = false);
            store.Save(path);
            Assert.Contains("\"auto_check_updates\": false", File.ReadAllText(path));

            var reloaded = new SettingsStore();
            reloaded.Load(path);
            Assert.False(reloaded.Settings.AutoCheckUpdates);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void MissingAutoCheckKeyKeepsDefault()
    {
        var path = Path.Combine(Path.GetTempPath(), "aitrans-settings-" + Guid.NewGuid().ToString("N") + ".json");
        try
        {
            // 老版本写下的配置里没有 auto_check_updates，加载时应该回退到默认（开）。
            File.WriteAllText(
                path,
                """
                { "version": 1, "backend": "api", "lang": "zh", "translate": true,
                  "polish": true, "output_mode": "source", "suffix": "_translated" }
                """);

            var store = new SettingsStore();
            store.Load(path);
            Assert.True(store.Settings.AutoCheckUpdates);
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

    private const string ReleaseJson = """
        {
          "tag_name": "v9.9.9",
          "body": "更新说明",
          "html_url": "https://example.com/release",
          "assets": [
            { "name": "AITrans-9.9.9-arm64.zip", "browser_download_url": "https://example.com/a.zip" },
            { "name": "AITrans-9.9.9-win-x64-setup.exe", "browser_download_url": "https://example.com/a-setup.exe" },
            { "name": "AITrans-9.9.9-arm64.dmg", "browser_download_url": "https://example.com/a.dmg" }
          ]
        }
        """;

    private static async Task<UpdateInfo?> CheckAsync(string json, params string[] preferred)
    {
        using var http = new HttpClient(new StubHandler(json));
        var checker = new UpdateChecker(http: http)
        {
            CurrentVersion = "1.0.0",
            PreferredExtensions = preferred,
        };
        return await checker.CheckAsync();
    }

    [Fact]
    public async Task PrefersInstallerOnWindows()
    {
        var info = await CheckAsync(ReleaseJson, ".exe");
        Assert.Equal("9.9.9", info!.Version);
        Assert.Equal("https://example.com/a-setup.exe", info.DownloadUrl);
    }

    [Fact]
    public async Task PrefersDmgOnMac()
    {
        var info = await CheckAsync(ReleaseJson, ".dmg");
        Assert.Equal("https://example.com/a.dmg", info!.DownloadUrl);
    }

    [Fact]
    public async Task FallsBackToZipWhenNothingMatches()
    {
        var info = await CheckAsync(ReleaseJson, ".msi");
        Assert.Equal("https://example.com/a.zip", info!.DownloadUrl);
    }

    [Fact]
    public async Task ThrowsWhenNoDownloadableAsset()
    {
        var json = """{ "tag_name": "v9.9.9", "html_url": "https://example.com/r", "assets": [] }""";
        await Assert.ThrowsAsync<AITransException>(() => CheckAsync(json, ".exe"));
    }

    [Fact]
    public async Task ReturnsNullWhenAlreadyLatest()
    {
        var json = """
            { "tag_name": "v0.9.0", "html_url": "https://example.com/r", "assets": [
                { "name": "x.zip", "browser_download_url": "https://example.com/x.zip" } ] }
            """;
        Assert.Null(await CheckAsync(json, ".zip"));
    }

    private sealed class StubHandler(string json) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK)
            {
                Content = new StringContent(json),
            });
    }
}
