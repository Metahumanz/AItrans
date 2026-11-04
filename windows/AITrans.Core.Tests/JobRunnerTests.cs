using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

public sealed class JobRunnerTests : IDisposable
{
    private readonly string _workDir;

    public JobRunnerTests()
    {
        _workDir = Path.Combine(Path.GetTempPath(), "aitrans-tests-" + Guid.NewGuid().ToString("N"));
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

    private JobRunner Runner() => new(new Translator(new FakeChatClient()));

    private string CopyFixture(string name)
    {
        var source = Path.Combine(FixtureTests.RepoRoot(), "fixtures", "srt", name);
        var destination = Path.Combine(_workDir, name);
        File.Copy(source, destination);
        return destination;
    }

    [Fact]
    public async Task WritesTranslatedFileNextToSource()
    {
        var file = CopyFixture("basic-utf8.srt");
        var settings = new AppSettings { OutputMode = OutputMode.source, Polish = false, Force = false };

        var results = await Runner().RunAsync([file], settings, Path.Combine(_workDir, "output"), null);

        Assert.Single(results);
        Assert.Equal(FileResult.StatusKind.success, results[0].Status);

        var output = Path.Combine(_workDir, "basic-utf8_translated.srt");
        Assert.True(File.Exists(output));
        var text = File.ReadAllText(output);
        Assert.Contains("〔译〕Good morning, everyone.", text);
        Assert.Contains("Good morning, everyone.", text);
    }

    [Fact]
    public async Task SkipsExistingOutputWithoutForce()
    {
        var file = CopyFixture("basic-utf8.srt");
        var output = Path.Combine(_workDir, "basic-utf8_translated.srt");
        File.WriteAllText(output, "已有内容");

        var settings = new AppSettings { OutputMode = OutputMode.source, Force = false };
        var results = await Runner().RunAsync([file], settings, _workDir, null);

        Assert.Equal(FileResult.StatusKind.skipped, results[0].Status);
        Assert.Equal("已有内容", File.ReadAllText(output));
    }

    [Fact]
    public async Task ForceOverwritesExistingOutput()
    {
        var file = CopyFixture("basic-utf8.srt");
        var output = Path.Combine(_workDir, "basic-utf8_translated.srt");
        File.WriteAllText(output, "旧内容");

        var settings = new AppSettings { OutputMode = OutputMode.source, Force = true, Polish = false };
        var results = await Runner().RunAsync([file], settings, _workDir, null);

        Assert.Equal(FileResult.StatusKind.success, results[0].Status);
        var text = File.ReadAllText(output);
        Assert.NotEqual("旧内容", text);
        Assert.Contains("〔译〕", text);
    }

    [Fact]
    public async Task OutputDirectoryModeKeepsFileName()
    {
        var file = CopyFixture("gbk.srt");
        var outputDir = Path.Combine(_workDir, "out");
        var settings = new AppSettings { OutputMode = OutputMode.output, Polish = false };

        await Runner().RunAsync([file], settings, outputDir, null);

        var output = Path.Combine(outputDir, "gbk.srt");
        Assert.True(File.Exists(output));
        Assert.Contains("早上好，各位。", File.ReadAllText(output));
    }

    [Fact]
    public async Task RejectsTooManyFiles()
    {
        var files = Enumerable.Range(0, JobRunner.MaxFiles + 1)
            .Select(index => Path.Combine(_workDir, $"f{index}.srt"))
            .ToList();
        var settings = new AppSettings { OutputMode = OutputMode.output };

        var error = await Assert.ThrowsAsync<AITransException>(
            () => Runner().RunAsync(files, settings, _workDir, null));
        Assert.Contains("最多", error.Message);
    }

    [Fact]
    public async Task RejectsOllamaBackendForNow()
    {
        var file = CopyFixture("basic-utf8.srt");
        var settings = new AppSettings { Backend = Engine.ollama };

        var error = await Assert.ThrowsAsync<AITransException>(
            () => Runner().RunAsync([file], settings, _workDir, null));
        Assert.Contains("Ollama", error.Message);
    }
}
