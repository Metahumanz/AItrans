using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AITrans.Core;

public interface ISecretStore
{
    string? Get(string id);
    void Set(string id, string value);
    void Delete(string id);
}

/// <summary>测试与预览用的内存实现。</summary>
public sealed class MemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _values = new();

    public string? Get(string id) => _values.TryGetValue(id, out var value) ? value : null;

    public void Set(string id, string value)
    {
        // 与文件实现保持一致：空值表示删除。
        if (string.IsNullOrEmpty(value))
        {
            _values.Remove(id);
        }
        else
        {
            _values[id] = value;
        }
    }

    public void Delete(string id) => _values.Remove(id);
}

/// <summary>
/// 用 Windows DPAPI 按当前用户加密密钥，落盘为一个不透明文件。
/// 与 macOS 的本地 secrets.json 对应：密钥不进入 providers.json。
/// 空值表示删除；文件损坏或解密失败会抛 <see cref="AITransException"/>，不再静默当成「没有密钥」。
/// </summary>
public sealed class DpapiSecretStore : ISecretStore
{
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("AITrans.Secrets.v1");
    private readonly string _path;

    public DpapiSecretStore(string path)
    {
        _path = path;
    }

    private Dictionary<string, string> Load()
    {
        if (!File.Exists(_path)) return new Dictionary<string, string>();

        string text;
        try
        {
            text = File.ReadAllText(_path);
        }
        catch (Exception error)
        {
            throw new AITransException($"读取密钥文件失败：{_path}（{error.Message}）");
        }

        try
        {
            return JsonSerializer.Deserialize<Dictionary<string, string>>(text)
                   ?? new Dictionary<string, string>();
        }
        catch (JsonException)
        {
            throw new AITransException($"密钥文件格式不正确：{_path}");
        }
    }

    private void Save(Dictionary<string, string> values)
    {
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        File.WriteAllText(_path, JsonSerializer.Serialize(values));
    }

    public string? Get(string id)
    {
        if (!Load().TryGetValue(id, out var encoded)) return null;
        try
        {
            var bytes = ProtectedData.Unprotect(
                Convert.FromBase64String(encoded), Entropy, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch (Exception error)
        {
            throw new AITransException(
                $"密钥解密失败：{_path}（{error.Message}）。如果换了 Windows 用户或文件已损坏，" +
                "可在「提供商」里清除后重新填写。");
        }
    }

    public void Set(string id, string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            Delete(id);
            return;
        }

        var values = Load();
        var bytes = ProtectedData.Protect(
            Encoding.UTF8.GetBytes(value), Entropy, DataProtectionScope.CurrentUser);
        values[id] = Convert.ToBase64String(bytes);
        Save(values);
    }

    public void Delete(string id)
    {
        var values = Load();
        if (values.Remove(id)) Save(values);
    }
}

public static class ProviderValidation
{
    private static readonly Regex IdPattern = new("^[a-z0-9][a-z0-9_-]{0,63}$", RegexOptions.Compiled);
    private static readonly Regex NonIdChars = new("[^a-z0-9]+", RegexOptions.Compiled);

    public static string MakeId(string name, ISet<string> taken)
    {
        var replaced = NonIdChars.Replace(name.ToLowerInvariant(), "-").Trim('-');
        var shortened = replaced.Length > 40 ? replaced[..40] : replaced;
        var baseId = shortened.Length == 0 ? "provider" : shortened;

        var candidate = baseId;
        var index = 2;
        while (taken.Contains(candidate))
        {
            candidate = $"{baseId}-{index}";
            index++;
        }
        return candidate;
    }

    public static Provider Normalize(Provider provider, ISet<string> taken)
    {
        var name = provider.Name.Trim();
        var baseUrl = provider.BaseUrl.Trim().TrimEnd('/');
        var model = provider.Model.Trim();
        var apiKey = provider.ApiKey.Trim();

        if (name.Length == 0) throw new AITransException("请填写提供商名称。");

        foreach (var (label, value) in new[]
                 {
                     ("提供商名称", name), ("接口地址", baseUrl), ("模型名称", model), ("API Key", apiKey),
                 })
        {
            if (value.Any(c => c < 32))
            {
                throw new AITransException($"{label}不能包含换行或控制字符。");
            }
        }

        if (name.Length > 80) throw new AITransException("提供商名称不能超过 80 个字符。");
        if (baseUrl.Length == 0) throw new AITransException("请填写接口地址。");
        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)
            || (uri.Scheme != "http" && uri.Scheme != "https")
            || string.IsNullOrEmpty(uri.Host))
        {
            throw new AITransException("接口地址必须以 http:// 或 https:// 开头。");
        }
        if (baseUrl.Length > 500) throw new AITransException("接口地址过长。");
        if (model.Length == 0) throw new AITransException("请填写模型名称。");
        if (model.Length > 200) throw new AITransException("模型名称过长。");
        if (apiKey.Length > 1000) throw new AITransException("API Key 过长。");

        var rawId = provider.Id.Trim();
        string id;
        if (rawId.Length == 0)
        {
            id = MakeId(name, taken);
        }
        else
        {
            if (!IdPattern.IsMatch(rawId))
            {
                throw new AITransException("提供商标识只能包含小写字母、数字、- 和 _。");
            }
            id = rawId;
        }

        return new Provider
        {
            Id = id,
            Name = name,
            BaseUrl = baseUrl,
            Model = model,
            ApiKey = apiKey,
            RequiresKey = provider.RequiresKey,
        };
    }
}

public sealed class ProviderStore
{
    private readonly ISecretStore _secrets;

    public ProviderStore(ISecretStore secrets)
    {
        _secrets = secrets;
    }

    public List<Provider> Providers { get; private set; } = [];
    public string? ActiveId { get; private set; }

    public Provider? ActiveProvider => ActiveId is null
        ? null
        : Providers.FirstOrDefault(provider => provider.Id == ActiveId);

    public Provider? Find(string id) => Providers.FirstOrDefault(provider => provider.Id == id);

    /// <summary>
    /// 按需从加密存储补齐密钥，与 macOS 的 <c>ProviderStore.hydrate</c> 对应。
    /// 内存里已有 key 时原样返回，不额外访问密钥存储；需要补齐时返回副本，不改动列表里的条目。
    /// </summary>
    public Provider Hydrate(Provider provider)
    {
        if (!string.IsNullOrEmpty(provider.ApiKey) || string.IsNullOrEmpty(provider.Id))
        {
            return provider;
        }

        var hydrated = provider.Clone();
        hydrated.ApiKey = _secrets.Get(provider.Id) ?? "";
        return hydrated;
    }

    private sealed class StoreFile
    {
        [System.Text.Json.Serialization.JsonPropertyName("version")]
        public int Version { get; set; } = 1;

        [System.Text.Json.Serialization.JsonPropertyName("active")]
        public string? Active { get; set; }

        [System.Text.Json.Serialization.JsonPropertyName("providers")]
        public List<Provider> Providers { get; set; } = [];
    }

    public void Load(string path)
    {
        if (!File.Exists(path))
        {
            Providers = [];
            ActiveId = null;
            return;
        }

        StoreFile? file;
        try
        {
            file = JsonSerializer.Deserialize<StoreFile>(File.ReadAllText(path));
        }
        catch (JsonException)
        {
            throw new AITransException("providers.json 格式不正确。");
        }
        if (file is null) throw new AITransException("providers.json 格式不正确。");

        // 旧文件里的明文 api_key 先留在内存里，由调用方在载入后调用 MigratePlaintextKeys 迁移。
        // 这里不读密钥存储：启动阶段不碰 secrets.dat，开始任务 / 测试连接 / 编辑时才按需补齐。
        Providers = file.Providers;
        ActiveId = file.Active;
        if (ActiveId is not null && Find(ActiveId) is null)
        {
            ActiveId = Providers.FirstOrDefault()?.Id;
        }
    }

    public void Save(string path)
    {
        var file = new StoreFile
        {
            Version = 1,
            Active = ActiveId,
            // 密钥只进加密存储，不写入 JSON。
            Providers = Providers.Select(provider => new Provider
            {
                Id = provider.Id,
                Name = provider.Name,
                BaseUrl = provider.BaseUrl,
                Model = provider.Model,
                ApiKey = "",
                RequiresKey = provider.RequiresKey,
            }).ToList(),
        };

        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
        File.WriteAllText(path, JsonSerializer.Serialize(file, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// <summary>
    /// 把旧 providers.json 里的明文 key 迁移到 DPAPI 存储并重写文件，返回迁移条数。
    /// 应在 <see cref="Load"/> 之后、<see cref="Hydrate"/> 之前调用；只处理内存里带 key 的条目，
    /// 因此重复调用是安全的。
    /// </summary>
    public int MigratePlaintextKeys(string path)
    {
        var pending = Providers.Where(provider => !string.IsNullOrEmpty(provider.ApiKey)).ToList();
        if (pending.Count == 0) return 0;

        foreach (var provider in pending)
        {
            _secrets.Set(provider.Id, provider.ApiKey);
        }
        foreach (var provider in pending)
        {
            provider.ApiKey = "";
        }
        Save(path);
        return pending.Count;
    }

    /// <summary>清除某个提供商已保存的密钥；提供商本身保留。</summary>
    public void ClearKey(string id)
    {
        _secrets.Delete(id);
        var provider = Find(id);
        if (provider is not null) provider.ApiKey = "";
    }

    public Provider Upsert(Provider provider, bool activate = false)
    {
        var taken = Providers.Where(existing => existing.Id != provider.Id).Select(existing => existing.Id).ToHashSet();
        var normalized = ProviderValidation.Normalize(provider, taken);

        // 空 key 表示「保留已有密钥」，不拿空值覆盖加密存储里的旧值。
        // 旧值仍留在 secrets.dat 里，下次 Hydrate 时再读回来。
        if (!string.IsNullOrEmpty(normalized.ApiKey))
        {
            _secrets.Set(normalized.Id, normalized.ApiKey);
        }

        var index = Providers.FindIndex(existing => existing.Id == normalized.Id);
        if (index >= 0)
        {
            Providers[index] = normalized;
        }
        else
        {
            Providers.Add(normalized);
        }

        if (activate || ActiveId is null)
        {
            ActiveId = normalized.Id;
        }
        return normalized;
    }

    public void Delete(string id)
    {
        if (Find(id) is null) return;
        // 先删密钥：失败时保留提供商，避免留下无法再被清理的孤儿密钥。
        _secrets.Delete(id);
        Providers.RemoveAll(provider => provider.Id == id);
        if (ActiveId == id)
        {
            ActiveId = Providers.FirstOrDefault()?.Id;
        }
    }

    public void SetActive(string id)
    {
        if (Find(id) is null) throw new AITransException($"提供商不存在：{id}");
        ActiveId = id;
    }

    /// <summary>从 v1 的 providers.json / .env 导入，返回导入条数。</summary>
    public int ImportLegacy(string? profilesPath, string? envPath)
    {
        var imported = 0;

        if (!string.IsNullOrEmpty(profilesPath) && File.Exists(profilesPath))
        {
            Load(profilesPath);
            // v1 的 providers.json 里是明文 key：写进加密存储后清掉内存明文，不重写源文件。
            var plaintext = Providers.Where(provider => !string.IsNullOrEmpty(provider.ApiKey)).ToList();
            foreach (var provider in plaintext)
            {
                _secrets.Set(provider.Id, provider.ApiKey);
                provider.ApiKey = "";
            }
            imported = Providers.Count;
        }

        if (imported == 0 && !string.IsNullOrEmpty(envPath) && File.Exists(envPath))
        {
            var values = new Dictionary<string, string>();
            foreach (var line in File.ReadAllLines(envPath))
            {
                var trimmed = line.Trim();
                if (trimmed.Length == 0 || trimmed.StartsWith('#')) continue;
                var separator = trimmed.IndexOf('=');
                if (separator <= 0) continue;
                values[trimmed[..separator].Trim()] = trimmed[(separator + 1)..].Trim();
            }

            var key = values.GetValueOrDefault("AI_API_KEY") ?? values.GetValueOrDefault("DEEPSEEK_API_KEY") ?? "";
            var baseUrl = values.GetValueOrDefault("AI_BASE_URL") ?? values.GetValueOrDefault("DEEPSEEK_BASE_URL") ?? "https://api.deepseek.com";
            var model = values.GetValueOrDefault("AI_MODEL") ?? "deepseek-flash";

            if (baseUrl.Length > 0 && model.Length > 0)
            {
                Upsert(new Provider
                {
                    Id = values.GetValueOrDefault("AI_PROVIDER") ?? "deepseek",
                    Name = values.GetValueOrDefault("AI_PROVIDER_NAME") ?? "DeepSeek",
                    BaseUrl = baseUrl,
                    Model = model,
                    ApiKey = key,
                    RequiresKey = true,
                }, activate: true);
                imported = 1;
            }
        }

        return imported;
    }
}
