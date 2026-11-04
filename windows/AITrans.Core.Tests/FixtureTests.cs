using System.Text.Json;
using System.Text.Json.Serialization;
using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

/// <summary>
/// 用 fixtures/ 黄金样本验证解析与组装。
/// 黄金样本由 tools/gen_fixtures.py 调用 legacy Python 实现生成。
/// </summary>
public sealed class FixtureTests
{
    public sealed class ExpectedBlock
    {
        [JsonPropertyName("valid")] public bool Valid { get; set; }
        [JsonPropertyName("raw")] public string Raw { get; set; } = "";
        [JsonPropertyName("index")] public string? Index { get; set; }
        [JsonPropertyName("timeline")] public string? Timeline { get; set; }
        [JsonPropertyName("original")] public string? Original { get; set; }
    }

    public sealed class ExpectedCase
    {
        [JsonPropertyName("blocks")] public List<ExpectedBlock> Blocks { get; set; } = [];
        [JsonPropertyName("translateOutput")] public string TranslateOutput { get; set; } = "";
        [JsonPropertyName("polishOutput")] public string PolishOutput { get; set; } = "";
    }

    public sealed class Document
    {
        [JsonPropertyName("translatePrefix")] public string TranslatePrefix { get; set; } = "";
        [JsonPropertyName("polishPrefix")] public string PolishPrefix { get; set; } = "";
        [JsonPropertyName("cases")] public Dictionary<string, ExpectedCase> Cases { get; set; } = [];
    }

    internal static string RepoRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "fixtures")))
            {
                return directory.FullName;
            }
            directory = directory.Parent;
        }
        throw new InvalidOperationException("找不到仓库根目录（fixtures/）");
    }

    internal static Document Load()
    {
        var path = Path.Combine(RepoRoot(), "fixtures", "expected", "srt.json");
        return JsonSerializer.Deserialize<Document>(File.ReadAllText(path))
               ?? throw new InvalidOperationException("无法解析黄金样本");
    }

    internal static IReadOnlyList<SrtBlock> Blocks(string name)
    {
        var path = Path.Combine(RepoRoot(), "fixtures", "srt", name);
        return Srt.SplitBlocks(TextDecoding.Decode(File.ReadAllBytes(path)));
    }

    [Fact]
    public void DecodingMatchesLegacy()
    {
        var document = Load();
        foreach (var (name, expected) in document.Cases)
        {
            var blocks = Blocks(name);
            Assert.Equal(expected.Blocks.Count, blocks.Count);
        }
    }

    [Fact]
    public void BlocksMatchLegacy()
    {
        var document = Load();
        foreach (var (name, expected) in document.Cases.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            var blocks = Blocks(name);
            for (var index = 0; index < blocks.Count; index++)
            {
                var want = expected.Blocks[index];
                Assert.Equal(want.Raw, blocks[index].Raw);
                Assert.Equal(want.Valid, blocks[index].IsValid);
                Assert.Equal(want.Index ?? "", blocks[index].Index);
                Assert.Equal(want.Timeline ?? "", blocks[index].Timeline);
                Assert.Equal(want.Original ?? "", blocks[index].Original);
            }
        }
    }

    [Fact]
    public void AssembleTranslateMatchesLegacy()
    {
        var document = Load();
        foreach (var (name, expected) in document.Cases)
        {
            var blocks = Blocks(name);
            var translations = blocks
                .Select(block => block.IsValid ? document.TranslatePrefix + block.Original : null)
                .ToList();
            Assert.Equal(expected.TranslateOutput, Srt.Assemble(blocks, translations));
        }
    }

    [Fact]
    public void AssemblePolishMatchesLegacy()
    {
        var document = Load();
        foreach (var (name, expected) in document.Cases)
        {
            var blocks = Blocks(name);
            var translations = blocks
                .Select(block => block.IsValid
                    ? document.PolishPrefix + document.TranslatePrefix + block.Original
                    : null)
                .ToList();
            Assert.Equal(expected.PolishOutput, Srt.Assemble(blocks, translations));
        }
    }

    [Fact]
    public void StripQuotesHandlesBothQuoteStyles()
    {
        Assert.Equal("你好", Srt.StripQuotes("“你好”"));
        Assert.Equal("hello", Srt.StripQuotes("\"hello\""));
        Assert.Equal("你好", Srt.StripQuotes("你好"));
        Assert.Equal("他说“你好”", Srt.StripQuotes("“他说“你好””"));
    }
}
