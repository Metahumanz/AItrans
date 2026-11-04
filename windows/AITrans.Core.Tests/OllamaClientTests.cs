using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

public sealed class OllamaClientTests
{
    [Fact]
    public void PayloadUsesNonStreamingNativeShape()
    {
        var client = new OllamaClient("qwen2.5");
        var json = client.BuildPayloadJson([ChatMessage.User("你好")]);
        using var document = System.Text.Json.JsonDocument.Parse(json);
        var root = document.RootElement;

        Assert.Equal("qwen2.5", root.GetProperty("model").GetString());
        Assert.False(root.GetProperty("stream").GetBoolean());
        var message = root.GetProperty("messages")[0];
        Assert.Equal("user", message.GetProperty("role").GetString());
        Assert.Equal("你好", message.GetProperty("content").GetString());
    }

    [Fact]
    public void ParsesMessageContent()
    {
        var body = """{"message":{"role":"assistant","content":"  译文  "},"done":true}""";
        Assert.Equal("译文", OllamaClient.ParseContent(body));
    }

    [Fact]
    public void RejectsEmptyContent()
    {
        var body = """{"message":{"role":"assistant","content":"   "},"done":true}""";
        Assert.Throws<AITransException>(() => OllamaClient.ParseContent(body));
    }

    [Fact]
    public void RejectsUnexpectedShape()
    {
        Assert.Throws<AITransException>(() => OllamaClient.ParseContent("""{"choices":[]}"""));
    }
}
