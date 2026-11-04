namespace AITrans.Core;

/// <summary>输入收集与输出路径规则，对应 legacy 的 translation_paths.py。</summary>
public static class OutputPaths
{
    private static readonly char[] InvalidSuffixCharacters = ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];

    public static string ValidateSuffix(string suffix)
    {
        var clean = (suffix ?? "").Trim();
        if (clean.Length == 0)
        {
            throw new AITransException("保存到源文件目录时必须提供文件名后缀。");
        }
        var bad = clean.Where(c => InvalidSuffixCharacters.Contains(c) || c < 32).Distinct().ToList();
        if (bad.Count > 0)
        {
            var shown = string.Join(" ", bad.Select(c => $"「{c}」"));
            throw new AITransException($"文件名后缀不能包含这些字符：{shown}。");
        }
        return clean;
    }

    /// <summary>文件夹按修改时间升序，显式文件保持顺序，按真实路径去重。</summary>
    public static IReadOnlyList<string> CollectSrtFiles(IEnumerable<string> inputs)
    {
        var files = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var raw in inputs)
        {
            var path = Path.GetFullPath(raw);
            if (Directory.Exists(path))
            {
                var candidates = Directory.EnumerateFiles(path)
                    .Where(f => string.Equals(Path.GetExtension(f), ".srt", StringComparison.OrdinalIgnoreCase))
                    .OrderBy(File.GetLastWriteTimeUtc)
                    .ToList();

                foreach (var candidate in candidates)
                {
                    if (seen.Add(Path.GetFullPath(candidate)))
                    {
                        files.Add(candidate);
                    }
                }
            }
            else if (File.Exists(path))
            {
                if (!string.Equals(Path.GetExtension(path), ".srt", StringComparison.OrdinalIgnoreCase))
                {
                    throw new AITransException($"不是 SRT 文件：{path}");
                }
                if (seen.Add(path))
                {
                    files.Add(path);
                }
            }
            else
            {
                throw new AITransException($"路径不存在：{path}");
            }
        }

        return files;
    }

    public static string OutputPathFor(
        string source,
        OutputMode mode,
        string suffix,
        string? outputDirectory,
        string? customDirectory)
    {
        return mode switch
        {
            OutputMode.source => Path.Combine(
                Path.GetDirectoryName(source) ?? "",
                $"{Path.GetFileNameWithoutExtension(source)}{ValidateSuffix(suffix)}.srt"),
            OutputMode.output => Path.Combine(
                outputDirectory ?? throw new AITransException("未指定输出目录。"),
                Path.GetFileName(source)),
            OutputMode.custom => Path.Combine(
                customDirectory ?? throw new AITransException("请选择自定义输出目录。"),
                Path.GetFileName(source)),
            _ => throw new AITransException("未知的输出位置。"),
        };
    }

    public static IReadOnlyList<(string Source, string Output)> PrepareOutputs(
        IEnumerable<string> sources,
        OutputMode mode,
        string suffix,
        string? outputDirectory,
        string? customDirectory)
    {
        var pairs = new List<(string, string)>();
        var used = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (var source in sources)
        {
            var output = Path.GetFullPath(OutputPathFor(source, mode, suffix, outputDirectory, customDirectory));
            if (string.Equals(Path.GetFullPath(source), output, StringComparison.OrdinalIgnoreCase))
            {
                throw new AITransException($"输出路径与源文件相同，会覆盖原文件：{output}");
            }
            if (used.TryGetValue(output, out var existing))
            {
                throw new AITransException(
                    $"多个源文件会写入同一个输出文件：{Path.GetFileName(output)}\n  - {existing}\n  - {source}");
            }
            used[output] = source;
            pairs.Add((source, output));
        }

        return pairs;
    }
}
