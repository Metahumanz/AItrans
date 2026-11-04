using System.Net;
using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

/// <summary>用假 HttpMessageHandler 验证重试与错误分类，不联网。</summary>
public sealed class ChatClientRetryTests
{
    private sealed class StubHandler : HttpMessageHandler
    {
        private readonly Func<int, HttpResponseMessage> _responder;
        public int Calls { get; private set; }

        public StubHandler(Func<int, HttpResponseMessage> responder)
        {
            _responder = responder;
        }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            return Task.FromResult(_responder(Calls));
        }
    }

    private static HttpResponseMessage Json(HttpStatusCode status, string body) =>
        new(status) { Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json") };

    private static ChatClient Client(StubHandler handler, int retries) => new(
        "https://example.invalid",
        "sk-test",
        "test-model",
        policy: new RetryPolicy(retries),
        http: new HttpClient(handler),
        delay: (_, _) => Task.CompletedTask);

    [Fact]
    public async Task RetriesOn429ThenSucceeds()
    {
        var handler = new StubHandler(call => call == 1
            ? Json((HttpStatusCode)429, """{"error":{"message":"rate limited"}}""")
            : Json(HttpStatusCode.OK, """{"choices":[{"message":{"content":"你好"}}]}"""));

        var text = await Client(handler, retries: 2)
            .CompleteAsync([ChatMessage.User("hi")]);

        Assert.Equal("你好", text);
        Assert.Equal(2, handler.Calls);
    }

    [Fact]
    public async Task DoesNotRetryOn400()
    {
        var handler = new StubHandler(_ =>
            Json(HttpStatusCode.BadRequest, """{"error":{"message":"bad request"}}"""));

        var error = await Assert.ThrowsAsync<ChatHttpException>(
            () => Client(handler, retries: 3).CompleteAsync([ChatMessage.User("hi")]));

        Assert.Equal(400, error.Status);
        Assert.Contains("bad request", error.Message);
        Assert.Equal(1, handler.Calls);
    }

    [Fact]
    public async Task GivesUpAfterRetryBudget()
    {
        var handler = new StubHandler(_ => Json(HttpStatusCode.ServiceUnavailable, "{}"));

        var error = await Assert.ThrowsAsync<ChatHttpException>(
            () => Client(handler, retries: 1).CompleteAsync([ChatMessage.User("hi")]));

        Assert.Equal(503, error.Status);
        Assert.Equal(2, handler.Calls);
    }

    [Fact]
    public void DisablesThinkingForDeepSeekHost()
    {
        var deepseek = new ChatClient("https://api.deepseek.com", "k", "m");
        Assert.Contains("thinking", deepseek.BuildPayloadJson([ChatMessage.User("hi")]));

        var other = new ChatClient("https://api.openai.com/v1", "k", "m");
        Assert.DoesNotContain("thinking", other.BuildPayloadJson([ChatMessage.User("hi")]));
    }

    [Fact]
    public void ExtractsProviderErrorMessage()
    {
        var message = ChatClient.ErrorMessage("""{"error":{"message":"invalid key"}}""", 401);
        Assert.Equal("HTTP 401: invalid key", message);
    }
}

/// <summary>取消必须及时生效，且不留下半截输出文件。</summary>
public sealed class CancellationTests : IDisposable
{
    private readonly string _workDir;

    public CancellationTests()
    {
        _workDir = Path.Combine(Path.GetTempPath(), "aitrans-cancel-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_workDir);
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_workDir, recursive: true);
        }
        catch (IOException)
        {
            // 忽略清理失败。
        }
    }

    private sealed class BlockingClient : IChatCompleter
    {
        public async Task<string> CompleteAsync(
            IReadOnlyList<ChatMessage> messages, CancellationToken cancellationToken = default)
        {
            await Task.Delay(Timeout.Infinite, cancellationToken).ConfigureAwait(false);
            return "";
        }
    }

    [Fact]
    public async Task CancellingMidRunStopsWithoutOutput()
    {
        var source = Path.Combine(_workDir, "movie.srt");
        File.Copy(
            Path.Combine(FixtureTests.RepoRoot(), "fixtures", "srt", "basic-utf8.srt"),
            source);

        var runner = new JobRunner(new Translator(new BlockingClient()));
        var settings = new AppSettings { OutputMode = OutputMode.source, Polish = false };

        using var cts = new CancellationTokenSource();
        var task = runner.RunAsync([source], settings, _workDir, null, cancellationToken: cts.Token);
        cts.CancelAfter(150);

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);

        var output = Path.Combine(_workDir, "movie_translated.srt");
        Assert.False(File.Exists(output), "取消后不应留下输出文件");
    }
}
