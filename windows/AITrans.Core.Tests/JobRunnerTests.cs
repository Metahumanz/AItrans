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
    public async Task ReportsTranslateAndPolishProgress()
    {
        var file = CopyFixture("basic-utf8.srt");
        var settings = new AppSettings { OutputMode = OutputMode.source, Polish = true };
        var fileRecorder = new SyncProgress<JobProgress>();
        var cueRecorder = new SyncProgress<CueProgress>();

        var results = await Runner().RunAsync(
            [file], settings, Path.Combine(_workDir, "output"), null,
            fileProgress: fileRecorder, cueProgress: cueRecorder);

        Assert.Equal(FileResult.StatusKind.success, results[0].Status);
        Assert.Equal("basic-utf8.srt", fileRecorder.Values[0].CurrentName);
        Assert.Equal("", fileRecorder.Values[^1].CurrentName);
        Assert.Equal(1, fileRecorder.Values[^1].Completed);

        var cues = cueRecorder.Values;
        Assert.Equal("basic-utf8.srt", cues[0].FileName);
        Assert.Equal(JobStage.translating, cues[0].Stage);
        Assert.Equal(0, cues[0].Completed);
        Assert.Contains(cues, cue => cue.Stage == JobStage.polishing);
        Assert.Equal(JobStage.polishing, cues[^1].Stage);
        Assert.Equal(3, cues[^1].Completed);
        Assert.Equal(3, cues[^1].Total);
        Assert.Equal(0, cues[^1].ErrorCount);
    }

    [Fact]
    public async Task PauseGateStopsBeforeStartingFiles()
    {
        var file = CopyFixture("basic-utf8.srt");
        var settings = new AppSettings { OutputMode = OutputMode.source, Polish = false, Force = true };
        var gate = new PauseGate();
        gate.Pause();
        var fileRecorder = new SyncProgress<JobProgress>();

        var task = Runner().RunAsync(
            [file], settings, _workDir, null,
            pauseGate: gate, fileProgress: fileRecorder);

        await Task.Delay(100);
        Assert.Empty(fileRecorder.Values);

        gate.Resume();
        var results = await task;
        Assert.Equal(FileResult.StatusKind.success, results[0].Status);
    }

    [Fact]
    public async Task CancelWakesPausedJob()
    {
        var file = CopyFixture("basic-utf8.srt");
        var settings = new AppSettings { OutputMode = OutputMode.source, Polish = false };
        var gate = new PauseGate();
        gate.Pause();
        using var cts = new CancellationTokenSource();

        var task = Runner().RunAsync(
            [file], settings, _workDir, null,
            pauseGate: gate, cancellationToken: cts.Token);

        await Task.Delay(100);
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
        Assert.False(File.Exists(Path.Combine(_workDir, "basic-utf8_translated.srt")));
    }

    [Fact]
    public async Task OllamaBackendRunsWithSamePipeline()
    {
        var file = CopyFixture("basic-utf8.srt");
        var settings = new AppSettings
        {
            Backend = Engine.ollama,
            OutputMode = OutputMode.source,
            Polish = false,
        };

        var results = await Runner().RunAsync([file], settings, _workDir, null);

        Assert.Equal(FileResult.StatusKind.success, results[0].Status);
        var output = Path.Combine(_workDir, "basic-utf8_translated.srt");
        Assert.Contains("〔译〕", File.ReadAllText(output));
    }
}
