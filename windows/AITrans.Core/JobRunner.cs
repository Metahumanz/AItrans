namespace AITrans.Core;

public sealed record JobProgress(int Completed, int Total, string CurrentName);

/// <summary>
/// 把「文件列表 + 设置」跑成结果，对应 v1 的 process_ori_folder：
/// 跳过已存在输出、按设置决定翻译/润色、输出 UTF-8 + LF。
/// </summary>
public sealed class JobRunner
{
    public const int MaxFiles = 200;

    private readonly Translator _translator;

    public JobRunner(Translator translator)
    {
        _translator = translator;
    }

    public async Task<IReadOnlyList<FileResult>> RunAsync(
        IReadOnlyList<string> files,
        AppSettings settings,
        string outputDirectory,
        string? customDirectory,
        IProgress<JobProgress>? fileProgress = null,
        IProgress<int>? cueProgress = null,
        CancellationToken cancellationToken = default)
    {
        if (files.Count > MaxFiles)
        {
            throw new AITransException($"一次最多处理 {MaxFiles} 个文件。");
        }
        if (settings.Backend != Engine.api)
        {
            throw new AITransException("本地 Ollama 引擎尚未接入 v2 客户端。");
        }

        var pairs = OutputPaths.PrepareOutputs(
            files, settings.OutputMode, settings.Suffix, outputDirectory, customDirectory);

        var results = new List<FileResult>(pairs.Count);
        for (var offset = 0; offset < pairs.Count; offset++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var (source, output) = pairs[offset];
            fileProgress?.Report(new JobProgress(offset, pairs.Count, Path.GetFileName(source)));

            var name = Path.GetFileName(source);
            if (!settings.Force && File.Exists(output) && new FileInfo(output).Length > 0)
            {
                results.Add(new FileResult
                {
                    Name = name,
                    RelativeName = name,
                    Status = FileResult.StatusKind.skipped,
                    OutputPath = output,
                });
                continue;
            }

            try
            {
                var text = TextDecoding.DecodeFile(source);
                var blocks = Srt.SplitBlocks(text);
                if (blocks.Count == 0)
                {
                    results.Add(new FileResult
                    {
                        Name = name,
                        RelativeName = name,
                        Status = FileResult.StatusKind.skipped,
                    });
                    continue;
                }

                var translated = await _translator.TranslateAsync(
                    blocks, settings.Lang, settings.ApiWorkers, cueProgress, cancellationToken)
                    .ConfigureAwait(false);

                var translations = translated.Translations;
                if (settings.Polish)
                {
                    var polished = await _translator.PolishAsync(
                        blocks, translations, Spec.DefaultPolishBatchSize, Spec.DefaultPolishWorkers,
                        progress: null, cancellationToken: cancellationToken).ConfigureAwait(false);
                    translations = polished.Translations;
                }

                var assembled = Srt.Assemble(blocks, translations);
                var directory = Path.GetDirectoryName(output);
                if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                await File.WriteAllTextAsync(output, assembled, new System.Text.UTF8Encoding(false), cancellationToken)
                    .ConfigureAwait(false);

                results.Add(new FileResult
                {
                    Name = name,
                    RelativeName = name,
                    Status = FileResult.StatusKind.success,
                    OutputPath = output,
                    TranslatedCount = translated.SuccessCount,
                    ErrorCount = translated.ErrorCount,
                });
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error)
            {
                results.Add(new FileResult
                {
                    Name = name,
                    RelativeName = name,
                    Status = FileResult.StatusKind.failed,
                    Error = error.Message,
                });
            }
        }

        fileProgress?.Report(new JobProgress(pairs.Count, pairs.Count, ""));
        return results;
    }
}
