using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace AITrans.Core;

/// <summary>
/// 本地 Ollama 引擎，走原生 /api/chat 接口。
/// </summary>
public sealed class OllamaClient : IChatCompleter
{
    public const string DefaultBaseUrl = "http://127.0.0.1:11434";

    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string _model;
    private readonly TimeSpan _timeout;
    private readonly RetryPolicy _policy;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;

    public OllamaClient(
        string model,
        string baseUrl = DefaultBaseUrl,
        TimeSpan? timeout = null,
        RetryPolicy? policy = null,
        HttpClient? http = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _model = model;
        _baseUrl = baseUrl.TrimEnd('/');
        _timeout = timeout ?? TimeSpan.FromSeconds(Spec.DefaultTimeoutSeconds);
        _policy = policy ?? new RetryPolicy();
        _http = http ?? new HttpClient();
        _delay = delay ?? ((span, token) => Task.Delay(span, token));
    }

    public string BuildPayloadJson(IReadOnlyList<ChatMessage> messages)
    {
        var payload = new Dictionary<string, object?>
        {
            ["model"] = _model,
            ["messages"] = messages
                .Select(m => new Dictionary<string, string> { ["role"] = m.Role, ["content"] = m.Content })
                .ToList(),
            ["stream"] = false,
        };
        return JsonSerializer.Serialize(payload);
    }

    public async Task<string> CompleteAsync(
        IReadOnlyList<ChatMessage> messages,
        CancellationToken cancellationToken = default)
    {
        var payload = BuildPayloadJson(messages);
        var endpoint = new Uri($"{_baseUrl}/api/chat");

        for (var attempt = 0; attempt <= _policy.Retries; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
                {
                    Content = new StringContent(payload, Encoding.UTF8, "application/json"),
                };
                using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                timeoutSource.CancelAfter(_timeout);

                using var response = await _http.SendAsync(request, timeoutSource.Token).ConfigureAwait(false);
                var body = await response.Content.ReadAsStringAsync(timeoutSource.Token).ConfigureAwait(false);

                if (!response.IsSuccessStatusCode)
                {
                    var status = (int)response.StatusCode;
                    var decision = _policy.DecideForStatus(status, attempt);
                    if (decision.Kind == RetryDecisionKind.Retry)
                    {
                        await _delay(decision.Delay, cancellationToken).ConfigureAwait(false);
                        continue;
                    }
                    var detail = body.Trim();
                    if (detail.Length > 200) detail = detail[..200];
                    throw new AITransException($"Ollama 返回 HTTP {status}{(detail.Length == 0 ? "" : $"：{detail}")}");
                }

                return ParseContent(body);
            }
            catch (AITransException)
            {
                throw;
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception error) when (error is HttpRequestException or TaskCanceledException or IOException)
            {
                var decision = _policy.DecideForTransportError(attempt);
                if (decision.Kind == RetryDecisionKind.Retry)
                {
                    await _delay(decision.Delay, cancellationToken).ConfigureAwait(false);
                    continue;
                }
                throw new AITransException("无法连接 Ollama，请确认服务已启动（ollama serve）。");
            }
        }

        throw new AITransException("Ollama 请求失败：重试次数已用完");
    }

    public static string ParseContent(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var content = document.RootElement
                .GetProperty("message")
                .GetProperty("content")
                .GetString();
            var text = (content ?? "").Trim();
            if (text.Length == 0)
            {
                throw new AITransException("Ollama 返回了空内容");
            }
            return text;
        }
        catch (AITransException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new AITransException("Ollama 返回格式异常");
        }
    }

    /// <summary>已安装的模型名列表。</summary>
    public static async Task<IReadOnlyList<string>> ModelsAsync(
        string baseUrl = DefaultBaseUrl,
        HttpClient? http = null,
        CancellationToken cancellationToken = default)
    {
        using var client = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(5) };
        var trimmed = baseUrl.TrimEnd('/');
        var body = await client.GetStringAsync($"{trimmed}/api/tags", cancellationToken).ConfigureAwait(false);

        using var document = JsonDocument.Parse(body);
        if (!document.RootElement.TryGetProperty("models", out var models)
            || models.ValueKind != JsonValueKind.Array)
        {
            throw new AITransException("Ollama 返回格式异常");
        }

        var names = new List<string>();
        foreach (var model in models.EnumerateArray())
        {
            if (model.TryGetProperty("name", out var name) && name.GetString() is { Length: > 0 } value)
            {
                names.Add(value);
            }
        }
        return names;
    }
}

/// <summary>本地 Ollama 服务的启动与检查。</summary>
public static class OllamaService
{
    public static async Task<bool> IsRunningAsync(string baseUrl = OllamaClient.DefaultBaseUrl)
    {
        try
        {
            await OllamaClient.ModelsAsync(baseUrl).ConfigureAwait(false);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public static string? FindExecutable()
    {
        var local = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs", "Ollama", "ollama.exe");
        if (File.Exists(local)) return local;

        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(Path.PathSeparator))
        {
            if (directory.Length == 0) continue;
            var candidate = Path.Combine(directory, "ollama.exe");
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>确保服务在跑；必要时拉起 `ollama serve`。</summary>
    public static async Task EnsureRunningAsync(
        string baseUrl = OllamaClient.DefaultBaseUrl,
        CancellationToken cancellationToken = default)
    {
        if (await IsRunningAsync(baseUrl).ConfigureAwait(false)) return;

        var executable = FindExecutable();
        if (executable is null)
        {
            throw new AITransException("没有找到 Ollama。请先安装并打开 Ollama，或切换到 API 提供商。");
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = executable,
                Arguments = "serve",
                UseShellExecute = false,
                CreateNoWindow = true,
            });
        }
        catch (Exception error)
        {
            throw new AITransException($"无法启动 Ollama：{error.Message}");
        }

        for (var attempt = 0; attempt < 30; attempt++)
        {
            await Task.Delay(1000, cancellationToken).ConfigureAwait(false);
            if (await IsRunningAsync(baseUrl).ConfigureAwait(false)) return;
        }
        throw new AITransException("Ollama 启动超时，请手动运行 `ollama serve` 后重试。");
    }

    /// <summary>检查模型是否已安装（允许 name 与 name:latest 互相匹配）。</summary>
    public static async Task EnsureModelAsync(
        string name,
        string baseUrl = OllamaClient.DefaultBaseUrl,
        CancellationToken cancellationToken = default)
    {
        var installed = await OllamaClient.ModelsAsync(baseUrl, cancellationToken: cancellationToken)
            .ConfigureAwait(false);
        var wanted = name.Split(':')[0];
        var found = installed.Any(candidate => candidate.Split(':')[0] == wanted);
        if (!found)
        {
            throw new AITransException($"尚未安装模型 {name}。请在终端运行 ollama pull {name}，完成后重试。");
        }
    }
}
