using System.Text.RegularExpressions;
using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

/// <summary>与 tools/gen_fixtures.py 的假模型等价。</summary>
public sealed class FakeChatClient : IChatCompleter
{
    public const string TranslatePrefix = "〔译〕";
    public const string PolishPrefix = "〔润〕";

    private static readonly Regex BatchLine = new(
        @"^\[(\d+)\] (.*?)(?=\n\[\d+\] |\z)",
        RegexOptions.Singleline | RegexOptions.Multiline | RegexOptions.Compiled);

    public Task<string> CompleteAsync(IReadOnlyList<ChatMessage> messages, CancellationToken cancellationToken = default)
    {
        var system = messages[0].Content;
        var user = messages[1].Content;

        if (system.Contains("润色", StringComparison.Ordinal))
        {
            var section = user.Split("【本批次译文】").Last();
            var body = section.Split("\n\n请按")[0];
            var lines = BatchLine.Matches(body)
                .Select(match => $"[{match.Groups[1].Value}] {PolishPrefix}{match.Groups[2].Value}");
            return Task.FromResult(string.Join("\n", lines));
        }

        return Task.FromResult($"“{TranslatePrefix}{user}”");
    }
}

public sealed class TranslatorTests
{
    [Fact]
    public async Task TranslateOnlyMatchesLegacy()
    {
        var document = FixtureTests.Load();
        foreach (var (name, expected) in document.Cases)
        {
            var blocks = FixtureTests.Blocks(name);
            var translator = new Translator(new FakeChatClient());
            var outcome = await translator.TranslateAsync(blocks, Language.zh, workers: 3);

            Assert.Equal(0, outcome.ErrorCount);
            Assert.Equal(expected.TranslateOutput, Srt.Assemble(blocks, outcome.Translations));
        }
    }

    [Fact]
    public async Task TranslateThenPolishMatchesLegacy()
    {
        var document = FixtureTests.Load();
        foreach (var (name, expected) in document.Cases)
        {
            var blocks = FixtureTests.Blocks(name);
            var translator = new Translator(new FakeChatClient());
            var translated = await translator.TranslateAsync(blocks, Language.zh, workers: 3);
            var polished = await translator.PolishAsync(blocks, translated.Translations, batchSize: 8, workers: 2);

            Assert.Equal(0, polished.ErrorCount);
            Assert.Equal(expected.PolishOutput, Srt.Assemble(blocks, polished.Translations));
        }
    }

    [Fact]
    public async Task FailureKeepsOriginal()
    {
        var blocks = FixtureTests.Blocks("basic-utf8.srt");
        var translator = new Translator(new FailingClient());
        var outcome = await translator.TranslateAsync(blocks, Language.zh, workers: 2);

        Assert.Equal(0, outcome.SuccessCount);
        Assert.Equal(3, outcome.ErrorCount);
        Assert.Contains("Good morning, everyone.", Srt.Assemble(blocks, outcome.Translations));
    }

    [Fact]
    public void ParsesBracketFormat()
    {
        var parsed = Translator.ParseBatchResult("[0] 你好\n[1] 世界", [0, 1]);
        Assert.Equal("你好", parsed[0]);
        Assert.Equal("世界", parsed[1]);
    }

    [Fact]
    public void ParsesNumericDotFormat()
    {
        var parsed = Translator.ParseBatchResult("0. 你好\n1. 世界", [0, 1]);
        Assert.Equal("你好", parsed[0]);
        Assert.Equal("世界", parsed[1]);
    }

    [Fact]
    public void ParsesLinewiseFallback()
    {
        var parsed = Translator.ParseBatchResult("你好\n世界", [3, 4]);
        Assert.Equal("你好", parsed[3]);
        Assert.Equal("世界", parsed[4]);
    }

    [Fact]
    public void ParsesMultilineEntry()
    {
        var parsed = Translator.ParseBatchResult("[2] 第一行\n第二行\n[3] 别的", [2, 3]);
        Assert.Equal("第一行\n第二行", parsed[2]);
        Assert.Equal("别的", parsed[3]);
    }

    private sealed class FailingClient : IChatCompleter
    {
        public Task<string> CompleteAsync(IReadOnlyList<ChatMessage> messages, CancellationToken cancellationToken = default) =>
            throw new ChatHttpException(400, "HTTP 400: bad request");
    }
}
