using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace AITrans.Core;

public sealed record ChatMessage(string Role, string Content)
{
    public static ChatMessage System(string content) => new("system", content);
    public static ChatMessage User(string content) => new("user", content);
}

/// <summary>供 Translator 依赖的抽象，测试时替换为假实现。</summary>
public interface IChatCompleter
{
    Task<string> CompleteAsync(IReadOnlyList<ChatMessage> messages, CancellationToken cancellationToken = default);
}

public sealed class ChatHttpException : Exception
{
    public int Status { get; }

    public ChatHttpException(int status, string message) : base(message)
    {
        Status = status;
    }
}

/// <summary>OpenAI 兼容接口调用，与 legacy 的 request_chat_completion 对齐。</summary>
public sealed class ChatClient : IChatCompleter
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string _apiKey;
    private readonly string _model;
    private readonly TimeSpan _timeout;
    private readonly RetryPolicy _policy;
    private readonly Func<TimeSpan, CancellationToken, Task> _delay;

    public ChatClient(
        string baseUrl,
        string apiKey,
        string model,
        TimeSpan? timeout = null,
        RetryPolicy? policy = null,
        HttpClient? http = null,
        Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _baseUrl = baseUrl.TrimEnd('/');
        _apiKey = apiKey;
        _model = model;
        _timeout = timeout ?? TimeSpan.FromSeconds(Spec.DefaultTimeoutSeconds);
        _policy = policy ?? new RetryPolicy();
        _http = http ?? new HttpClient();
        _delay = delay ?? ((span, token) => Task.Delay(span, token));
    }

    /// <summary>DeepSeek 域名默认关闭思考模式；可用 AI_THINKING 覆盖。</summary>
    public static bool ShouldDisableThinking(string baseUrl)
    {
        var over = (Environment.GetEnvironmentVariable(Spec.ThinkingOverrideEnvVar) ?? "").Trim().ToLowerInvariant();
        if (over is "off" or "0" or "false" or "disabled") return false;
        if (over is "on" or "1" or "true" or "enabled") return true;

        if (!Uri.TryCreate(baseUrl, UriKind.Absolute, out var uri)) return false;
        return uri.Host.Contains(Spec.ThinkingHostKeyword, StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>构造请求体（拆出来便于单测）。</summary>
    public string BuildPayloadJson(IReadOnlyList<ChatMessage> messages)
    {
        var payload = new Dictionary<string, object?>
        {
            ["model"] = _model,
            ["messages"] = messages
                .Select(m => new Dictionary<string, string> { ["role"] = m.Role, ["content"] = m.Content })
                .ToList(),
        };
        if (ShouldDisableThinking(_baseUrl))
        {
            payload["thinking"] = new Dictionary<string, string> { ["type"] = "disabled" };
        }
        return JsonSerializer.Serialize(payload);
    }

    public async Task<string> CompleteAsync(
        IReadOnlyList<ChatMessage> messages,
        CancellationToken cancellationToken = default)
    {
        var payload = BuildPayloadJson(messages);
        var endpoint = new Uri($"{_baseUrl}/chat/completions");

        for (var attempt = 0; attempt <= _policy.Retries; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Post, endpoint)
                {
                    Content = new StringContent(payload, Encoding.UTF8, "application/json"),
                };
                if (!string.IsNullOrEmpty(_apiKey))
                {
                    request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);
                }

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
                    throw new ChatHttpException(status, ErrorMessage(body, status));
                }

                return ParseContent(body);
            }
            catch (ChatHttpException)
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
                throw new AITransException(TransportMessage(error));
            }
        }

        throw new AITransException("请求失败：重试次数已用完");
    }

    public static string ParseContent(string body)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            var content = document.RootElement
                .GetProperty("choices")[0]
                .GetProperty("message")
                .GetProperty("content")
                .GetString();
            var text = (content ?? "").Trim();
            if (text.Length == 0)
            {
                throw new AITransException("API 返回了空内容");
            }
            return text;
        }
        catch (AITransException)
        {
            throw;
        }
        catch (Exception)
        {
            throw new AITransException("API 返回格式异常");
        }
    }

    public static string ErrorMessage(string body, int status)
    {
        try
        {
            using var document = JsonDocument.Parse(body);
            if (document.RootElement.TryGetProperty("error", out var error)
                && error.ValueKind == JsonValueKind.Object
                && error.TryGetProperty("message", out var message)
                && message.GetString() is { Length: > 0 } text)
            {
                return $"HTTP {status}: {text}";
            }
        }
        catch (JsonException)
        {
            // 忽略，退回原始文本。
        }

        var trimmed = body.Trim();
        if (trimmed.Length > 200) trimmed = trimmed[..200];
        return trimmed.Length == 0 ? $"HTTP {status}" : $"HTTP {status}: {trimmed}";
    }

    private static string TransportMessage(Exception error) => error switch
    {
        TaskCanceledException => "网络错误：请求超时",
        HttpRequestException { StatusCode: HttpStatusCode.NotFound } => "网络错误：接口地址不存在",
        HttpRequestException => "网络错误：无法连接服务器",
        _ => $"网络错误：{error.Message}",
    };
}
