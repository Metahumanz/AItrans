using System.Text.RegularExpressions;

namespace AITrans.Core;

public sealed class SrtBlock
{
    public string Raw { get; init; } = "";
    public bool IsValid { get; init; }
    public string Index { get; init; } = "";
    public string Timeline { get; init; } = "";
    public string Original { get; init; } = "";
}

/// <summary>
/// SRT 分块、解析与组装。行为必须与 legacy Python 一致：
/// 以空行切块；不足 3 行的块原样保留；译文在上、原文在下。
/// </summary>
public static class Srt
{
    private static readonly Regex Separator = new(Spec.BlockSplitPattern, RegexOptions.Compiled);
    private static readonly string[] LineBreaks = ["\r\n", "\n", "\r"];
    private static readonly Regex LeadingNumber = new(@"^\[?\d+\]?[.:\s]*", RegexOptions.Compiled);

    public static IReadOnlyList<SrtBlock> SplitBlocks(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0) return [];

        return Separator.Split(trimmed).Select(ParseBlock).ToList();
    }

    private static SrtBlock ParseBlock(string block)
    {
        var lines = SplitLines(block);
        if (lines.Count < Spec.MinLinesForValidBlock)
        {
            return new SrtBlock { Raw = block, IsValid = false };
        }

        return new SrtBlock
        {
            Raw = block,
            IsValid = true,
            Index = lines[0],
            Timeline = lines[1],
            Original = string.Join("\n", lines.Skip(2)),
        };
    }

    private static List<string> SplitLines(string block)
    {
        var lines = block.Split(LineBreaks, StringSplitOptions.None).ToList();
        // Python 的 splitlines 不保留末尾空行。
        if (lines.Count > 0 && lines[^1].Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }
        return lines;
    }

    public static string Assemble(IReadOnlyList<SrtBlock> blocks, IReadOnlyList<string?> translations)
    {
        var output = new List<string>(blocks.Count);
        for (var index = 0; index < blocks.Count; index++)
        {
            var block = blocks[index];
            var translated = index < translations.Count ? translations[index] : null;
            if (!block.IsValid || translated is null)
            {
                output.Add(block.Raw);
                continue;
            }
            output.Add($"{block.Index}\n{block.Timeline}\n{translated}\n{block.Original}");
        }
        return string.Join(Spec.BlockSeparator, output);
    }

    /// <summary>去掉译文首尾的中英文引号。</summary>
    public static string StripQuotes(string text)
    {
        if (text.Length == 0) return text;
        var start = text[0] is '"' or '“' ? 1 : 0;
        var end = text.Length - 1;
        if (end >= start && text[end] is '"' or '”')
        {
            end--;
        }
        return start == 0 && end == text.Length - 1 ? text : text[start..(end + 1)];
    }

    public static Regex LeadingNumberRegex => LeadingNumber;
}
