using System.ComponentModel;
using System.Runtime.CompilerServices;
using AITrans.Core;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;

namespace AITrans.App;

/// <summary>列表里的一行字幕文件，状态变化时通知界面刷新。</summary>
public sealed class FileItem : INotifyPropertyChanged
{
    private FileResult? _result;

    public FileItem(string path)
    {
        Path = path;
        Name = System.IO.Path.GetFileName(path);
        Folder = System.IO.Path.GetDirectoryName(path) ?? "";
    }

    public string Path { get; }

    public string Name { get; }

    public string Folder { get; }

    public FileResult? Result
    {
        get => _result;
        set
        {
            _result = value;
            OnPropertyChanged(nameof(StatusText));
            OnPropertyChanged(nameof(Glyph));
            OnPropertyChanged(nameof(GlyphBrush));
            OnPropertyChanged(nameof(StatusBrush));
        }
    }

    public string Glyph => Result?.Status switch
    {
        FileResult.StatusKind.success => "\uE73E",
        FileResult.StatusKind.skipped => "\uE8AB",
        FileResult.StatusKind.failed => "\uE7BA",
        _ => "\uE8A5",
    };

    public Brush GlyphBrush => Result?.Status switch
    {
        FileResult.StatusKind.success => UiBrush.Get("SystemFillColorSuccessBrush", Colors.SeaGreen),
        FileResult.StatusKind.skipped => UiBrush.Get("TextFillColorTertiaryBrush", Colors.Gray),
        FileResult.StatusKind.failed => UiBrush.Get("SystemFillColorCriticalBrush", Colors.IndianRed),
        _ => UiBrush.Get("TextFillColorSecondaryBrush", Colors.Gray),
    };

    public string StatusText => Result?.Status switch
    {
        FileResult.StatusKind.success =>
            Result.ErrorCount > 0 ? $"成功 {Result.TranslatedCount} 段，失败 {Result.ErrorCount} 段" : "完成",
        FileResult.StatusKind.skipped => "已存在，跳过",
        FileResult.StatusKind.failed => Result.Error ?? "失败",
        _ => "",
    };

    public Brush StatusBrush => Result?.Status switch
    {
        FileResult.StatusKind.failed => UiBrush.Get("SystemFillColorCriticalBrush", Colors.IndianRed),
        FileResult.StatusKind.skipped => UiBrush.Get("TextFillColorTertiaryBrush", Colors.Gray),
        _ => UiBrush.Get("TextFillColorSecondaryBrush", Colors.Gray),
    };

    public event PropertyChangedEventHandler? PropertyChanged;

    private void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

internal static class UiBrush
{
    public static Brush Get(string key, Color fallback) =>
        Application.Current.Resources.TryGetValue(key, out var value) && value is Brush brush
            ? brush
            : new SolidColorBrush(fallback);
}
