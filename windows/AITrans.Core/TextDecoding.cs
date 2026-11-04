using System.Text;

namespace AITrans.Core;

/// <summary>
/// 字幕文件编码探测，与 legacy 的 read_text_file 一致：
/// 带 BOM 的 UTF-16 → UTF-8（含 BOM）→ GB18030 → 有损 UTF-8。
/// </summary>
public static class TextDecoding
{
    private static readonly Encoding StrictUtf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true);
    private static readonly Encoding Gb18030;

    static TextDecoding()
    {
        Encoding.RegisterProvider(CodePagesEncodingProvider.Instance);
        Gb18030 = Encoding.GetEncoding("GB18030");
    }

    public static string Decode(byte[] data)
    {
        if (data.Length >= 2 && data[0] == 0xFF && data[1] == 0xFE)
        {
            return Encoding.Unicode.GetString(data, 2, data.Length - 2);
        }
        if (data.Length >= 2 && data[0] == 0xFE && data[1] == 0xFF)
        {
            return Encoding.BigEndianUnicode.GetString(data, 2, data.Length - 2);
        }
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF)
        {
            return Encoding.UTF8.GetString(data, 3, data.Length - 3);
        }

        try
        {
            return StrictUtf8.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            // 继续尝试 GB18030。
        }

        try
        {
            return Gb18030.GetString(data);
        }
        catch (DecoderFallbackException)
        {
            return Encoding.UTF8.GetString(data);
        }
    }

    public static string DecodeFile(string path) => Decode(File.ReadAllBytes(path));
}
