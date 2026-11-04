using System.Text.RegularExpressions;

namespace AITrans.Core;

public sealed record TranslateFailure(int Index, string Message);

public sealed class TranslateOutcome
{
    public required IReadOnlyList<string?> Translations { get; init; }
    public required int SuccessCount { get; init; }
    public required int ErrorCount { get; init; }
    public required IReadOnlyList<TranslateFailure> Failures { get; init; }
}

public sealed class PolishOutcome
{
    public required IReadOnlyList<string?> Translations { get; init; }
    public required int PolishedCount { get; init; }
    public required int ErrorCount { get; init; }
}

/// <summary>
/// 并发翻译与分批润色，与 legacy 行为一致：
/// 逐块并发、失败保留原文；润色每批 8 条并取前两批作为上下文。
/// </summary>
public sealed class Translator
{
    private readonly IChatCompleter _client;

    public Translator(IChatCompleter client)
    {
        _client = client;
    }

    public async Task<TranslateOutcome> TranslateAsync(
        IReadOnlyList<SrtBlock> blocks,
        Language language,
        int workers = Spec.DefaultTranslateWorkers,
        IProgress<int>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var indices = Enumerable.Range(0, blocks.Count).Where(i => blocks[i].IsValid).ToList();
        var translations = new string?[blocks.Count];
        var failures = new List<TranslateFailure>();
        var system = Spec.TranslateSystemPrompt.Replace("{{lang}}", language.DisplayName());
        var width = Math.Max(1, workers);
        var finished = 0;

        for (var start = 0; start < indices.Count; start += width)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var wave = indices.Skip(start).Take(width).ToList();

            var tasks = wave.Select(async index =>
            {
                try
                {
                    var messages = new[]
                    {
                        ChatMessage.System(system),
                        ChatMessage.User(Spec.TranslateUserTemplate.Replace("{{text}}", blocks[index].Original)),
                    };
                    var answer = await _client.CompleteAsync(messages, cancellationToken).ConfigureAwait(false);
                    return (Index: index, Text: (string?)Srt.StripQuotes(answer), Error: (string?)null);
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    return (Index: index, Text: (string?)null, Error: (string?)error.Message);
                }
            });

            foreach (var result in await Task.WhenAll(tasks).ConfigureAwait(false))
            {
                if (result.Text is not null)
                {
                    translations[result.Index] = result.Text;
                }
                else
                {
                    failures.Add(new TranslateFailure(result.Index, result.Error ?? "未知错误"));
                }
            }

            finished += wave.Count;
            progress?.Report(finished);
        }

        return new TranslateOutcome
        {
            Translations = translations,
            SuccessCount = translations.Count(t => t is not null),
            ErrorCount = failures.Count,
            Failures = failures,
        };
    }

    public async Task<PolishOutcome> PolishAsync(
        IReadOnlyList<SrtBlock> blocks,
        IReadOnlyList<string?> translations,
        int batchSize = Spec.DefaultPolishBatchSize,
        int workers = Spec.DefaultPolishWorkers,
        IProgress<int>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var working = translations.ToArray();
        var indices = Enumerable.Range(0, blocks.Count)
            .Where(i => blocks[i].IsValid && translations[i] is not null)
            .ToList();

        if (indices.Count == 0)
        {
            return new PolishOutcome { Translations = working, PolishedCount = 0, ErrorCount = 0 };
        }

        var size = Math.Max(1, batchSize);
        var batches = new List<List<int>>();
        for (var start = 0; start < indices.Count; start += size)
        {
            batches.Add(indices.Skip(start).Take(size).ToList());
        }

        var width = Math.Max(1, workers);
        var polished = 0;
        var errors = 0;
        var finishedBatches = 0;

        for (var start = 0; start < batches.Count; start += width)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var wave = Enumerable.Range(start, Math.Min(width, batches.Count - start)).ToList();

            var prepared = wave.Select(batchNumber => (
                BatchNumber: batchNumber,
                Batch: batches[batchNumber],
                Messages: new[]
                {
                    ChatMessage.System(Spec.PolishSystemPrompt),
                    ChatMessage.User(BuildPolishPrompt(batchNumber, batches, working)),
                }
            )).ToList();

            var tasks = prepared.Select(async item =>
            {
                try
                {
                    var answer = await _client.CompleteAsync(item.Messages, cancellationToken).ConfigureAwait(false);
                    return (item.BatchNumber, Parsed: (IReadOnlyDictionary<int, string>?)ParseBatchResult(answer, item.Batch), Error: (string?)null);
                }
                catch (Exception error) when (error is not OperationCanceledException)
                {
                    return (item.BatchNumber, Parsed: (IReadOnlyDictionary<int, string>?)null, Error: (string?)error.Message);
                }
            });

            foreach (var result in await Task.WhenAll(tasks).ConfigureAwait(false))
            {
                var batch = batches[result.BatchNumber];
                if (result.Parsed is null)
                {
                    errors += batch.Count;
                    continue;
                }

                var applied = 0;
                foreach (var index in batch)
                {
                    if (!result.Parsed.TryGetValue(index, out var raw)) continue;
                    var text = Srt.StripQuotes(raw);
                    if (text.Length == 0) continue;
                    working[index] = text;
                    applied++;
                }
                polished += applied;
                errors += batch.Count - applied;
            }

            finishedBatches += wave.Count;
            progress?.Report(finishedBatches);
        }

        return new PolishOutcome
        {
            Translations = working,
            PolishedCount = polished,
            ErrorCount = errors,
        };
    }

    private static string BuildPolishPrompt(int batchNumber, List<List<int>> batches, IReadOnlyList<string?> translations)
    {
        static string Numbered(IEnumerable<int> indexes, IReadOnlyList<string?> values) =>
            string.Join("\n", indexes.Select(index =>
                Spec.PolishNumberedLine
                    .Replace("{{index}}", index.ToString())
                    .Replace("{{text}}", values[index] ?? "")));

        var numbered = Numbered(batches[batchNumber], translations);
        var contextStart = Math.Max(0, batchNumber - Spec.PolishContextBatches);
        var contextIndices = batches.Skip(contextStart).Take(batchNumber - contextStart).SelectMany(b => b).ToList();
        var context = Numbered(contextIndices, translations);

        return context.Length == 0
            ? Spec.PolishUserWithoutContext.Replace("{{numbered_text}}", numbered)
            : Spec.PolishUserWithContext
                .Replace("{{recent_context}}", context)
                .Replace("{{numbered_text}}", numbered);
    }

    /// <summary>与 legacy 的 parse_batch_result 一致，三种格式依次回退。</summary>
    public static IReadOnlyDictionary<int, string> ParseBatchResult(string text, IReadOnlyList<int> indices)
    {
        var allowed = indices.ToHashSet();
        var parsed = new Dictionary<int, string>();

        foreach (var match in Matches(Spec.BatchResultPatterns[0], text))
        {
            if (!int.TryParse(match.Number, out var index) || !allowed.Contains(index)) continue;
            parsed[index] = match.Text.Trim();
        }

        if (parsed.Count < indices.Count / 2)
        {
            var fallback = Matches(Spec.BatchResultPatterns[1], text);
            if (fallback.Count > 0 && fallback.Count >= parsed.Count)
            {
                parsed.Clear();
                foreach (var match in fallback)
                {
                    if (!int.TryParse(match.Number, out var index) || !allowed.Contains(index)) continue;
                    parsed[index] = match.Text.Trim();
                }
            }
        }

        if (parsed.Count < indices.Count / 2)
        {
            var lines = text
                .Split(new[] { "\r\n", "\n", "\r" }, StringSplitOptions.RemoveEmptyEntries)
                .Select(line => line.Trim())
                .Where(line => line.Length > 0)
                .ToList();

            if (lines.Count == indices.Count)
            {
                parsed.Clear();
                for (var position = 0; position < indices.Count; position++)
                {
                    var cleaned = Srt.LeadingNumberRegex.Replace(lines[position], "").Trim();
                    if (cleaned.Length > 0)
                    {
                        parsed[indices[position]] = cleaned;
                    }
                }
            }
        }

        return parsed;
    }

    private static List<(string Number, string Text)> Matches(string pattern, string text)
    {
        // Python 的 \Z 是绝对结尾，.NET 的 \Z 允许末尾换行，这里统一换成 \z。
        var normalized = pattern.Replace(@"\Z", @"\z");
        var regex = new Regex(normalized, RegexOptions.Singleline | RegexOptions.Compiled);
        return regex.Matches(text)
            .Select(match => (match.Groups[1].Value, match.Groups[2].Value))
            .ToList();
    }
}
