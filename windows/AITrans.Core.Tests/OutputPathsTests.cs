using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

public sealed class OutputPathsTests
{
    [Fact]
    public void AcceptsValidSuffix()
    {
        Assert.Equal("_zh", OutputPaths.ValidateSuffix("  _zh  "));
    }

    [Theory]
    [InlineData("a:b")]
    [InlineData("a/b")]
    [InlineData("a\\b")]
    [InlineData("a*b")]
    [InlineData("a?b")]
    [InlineData("a\"b")]
    [InlineData("a<b")]
    [InlineData("a>b")]
    [InlineData("a|b")]
    public void RejectsIllegalCharacters(string suffix)
    {
        Assert.Throws<AITransException>(() => OutputPaths.ValidateSuffix(suffix));
    }

    [Fact]
    public void RejectsEmptySuffix()
    {
        Assert.Throws<AITransException>(() => OutputPaths.ValidateSuffix("   "));
    }

    [Fact]
    public void RejectsControlCharacters()
    {
        Assert.Throws<AITransException>(() => OutputPaths.ValidateSuffix("a\u0001b"));
    }

    [Fact]
    public void SourceModeAppendsSuffix()
    {
        var folder = Path.Combine(Path.GetTempPath(), "movies");
        var source = Path.Combine(folder, "movie.srt");

        var output = OutputPaths.OutputPathFor(source, OutputMode.source, "_translated", null, null);

        Assert.Equal(Path.Combine(folder, "movie_translated.srt"), output);
    }

    [Fact]
    public void OutputModeKeepsFileName()
    {
        var folder = Path.Combine(Path.GetTempPath(), "out");
        var source = Path.Combine(Path.GetTempPath(), "movies", "movie.srt");

        var output = OutputPaths.OutputPathFor(source, OutputMode.output, "_translated", folder, null);

        Assert.Equal(Path.Combine(folder, "movie.srt"), output);
    }

    [Fact]
    public void CustomModeRequiresDirectory()
    {
        Assert.Throws<AITransException>(() => OutputPaths.OutputPathFor(
            "movie.srt", OutputMode.custom, "_x", null, null));
    }

    [Fact]
    public void DetectsTwoSourcesCollidingOnOneOutput()
    {
        var root = Path.GetTempPath();
        var first = Path.Combine(root, "a", "movie.srt");
        var second = Path.Combine(root, "b", "movie.srt");

        var error = Assert.Throws<AITransException>(() => OutputPaths.PrepareOutputs(
            [first, second], OutputMode.output, "_x", Path.Combine(root, "out"), null));

        Assert.Contains("同一个输出文件", error.Message);
    }

    [Fact]
    public void CollectsSrtFilesFromDirectoryIgnoringOthers()
    {
        var directory = Path.Combine(Path.GetTempPath(), "aitrans-collect-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            File.WriteAllText(Path.Combine(directory, "b.srt"), "1");
            File.WriteAllText(Path.Combine(directory, "a.srt"), "1");
            File.WriteAllText(Path.Combine(directory, "note.txt"), "x");

            var files = OutputPaths.CollectSrtFiles([directory]);

            Assert.Equal(2, files.Count);
            Assert.All(files, file => Assert.Equal(".srt", Path.GetExtension(file)));
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void CollectRejectsNonSrtFile()
    {
        var path = Path.Combine(Path.GetTempPath(), "aitrans-note-" + Guid.NewGuid().ToString("N") + ".txt");
        File.WriteAllText(path, "x");
        try
        {
            Assert.Throws<AITransException>(() => OutputPaths.CollectSrtFiles([path]));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CollectRejectsMissingPath()
    {
        Assert.Throws<AITransException>(() => OutputPaths.CollectSrtFiles(["Z:\\definitely-missing\\x.srt"]));
    }
}
