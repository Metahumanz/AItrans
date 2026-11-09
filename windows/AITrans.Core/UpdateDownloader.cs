namespace AITrans.Core;

/// <summary>
/// 下载新版本到本地。安装版的静默升级见 <see cref="UpdateInstaller"/>；
/// 便携版仍由用户退出后手动替换。
/// </summary>
public static class UpdateDownloader
{
    public static string DownloadsDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");

    public static async Task<string> DownloadAsync(
        UpdateInfo info,
        string? directory = null,
        CancellationToken cancellationToken = default)
    {
        var target = directory ?? DownloadsDirectory;
        Directory.CreateDirectory(target);

        var name = Path.GetFileName(new Uri(info.DownloadUrl).LocalPath);
        if (string.IsNullOrEmpty(name))
        {
            name = $"AITrans-{info.Version}.zip";
        }
        var destination = Path.Combine(target, name);

        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        using var response = await http.GetAsync(info.DownloadUrl, cancellationToken).ConfigureAwait(false);
        if (!response.IsSuccessStatusCode)
        {
            throw new AITransException("下载失败，请稍后重试或打开下载页。");
        }

        await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        await using var file = File.Create(destination);
        await stream.CopyToAsync(file, cancellationToken).ConfigureAwait(false);
        return destination;
    }

    public const string InstallHint =
        "已下载到「下载」文件夹。退出 AITrans，解压后用新文件覆盖当前目录即可。";
}
