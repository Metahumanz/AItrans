using System.Text.Json;

namespace AITrans.Core;

public sealed record UpdateInfo(string Version, string Notes, string DownloadUrl, string PageUrl);

/// <summary>通过 GitHub Releases 检查更新。</summary>
public sealed class UpdateChecker
{
    private readonly HttpClient _http;
    private readonly string _repository;

    public UpdateChecker(string repository = "Metahumanz/AItrans", HttpClient? http = null)
    {
        _repository = repository;
        _http = http ?? new HttpClient();
    }

    public string CurrentVersion { get; set; } = "0.0.0";

    public async Task<UpdateInfo?> CheckAsync(CancellationToken cancellationToken = default)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Get,
            $"https://api.github.com/repos/{_repository}/releases/latest");
        request.Headers.Add("Accept", "application/vnd.github+json");
        request.Headers.Add("User-Agent", "AITrans-Desktop");

        using var response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        var status = (int)response.StatusCode;
        if (status == 404)
        {
            throw new AITransException("仓库还没有发布版本。");
        }
        if (!response.IsSuccessStatusCode)
        {
            throw new AITransException($"检查更新失败（HTTP {status}）。");
        }

        var body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
        using var document = JsonDocument.Parse(body);
        var root = document.RootElement;

        var tag = (root.TryGetProperty("tag_name", out var tagElement) ? tagElement.GetString() ?? "" : "")
            .TrimStart('v', 'V');
        var notes = root.TryGetProperty("body", out var bodyElement) ? bodyElement.GetString() ?? "" : "";
        var page = root.TryGetProperty("html_url", out var pageElement) ? pageElement.GetString() ?? "" : "";

        string? download = null;
        if (root.TryGetProperty("assets", out var assets) && assets.ValueKind == JsonValueKind.Array)
        {
            foreach (var asset in assets.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var nameElement) ? nameElement.GetString() ?? "" : "";
                if (!name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) continue;
                download = asset.TryGetProperty("browser_download_url", out var urlElement)
                    ? urlElement.GetString()
                    : null;
                break;
            }
        }

        if (string.IsNullOrEmpty(download) || string.IsNullOrEmpty(page))
        {
            throw new AITransException("该版本没有可下载的压缩包。");
        }

        return IsNewer(tag, CurrentVersion)
            ? new UpdateInfo(tag, notes, download, page)
            : null;
    }

    /// <summary>语义化版本比较；非数字段按字符串比较。</summary>
    public static bool IsNewer(string candidate, string current)
    {
        var left = candidate.Split('.');
        var right = current.Split('.');
        for (var index = 0; index < Math.Max(left.Length, right.Length); index++)
        {
            var l = index < left.Length ? left[index] : "0";
            var r = index < right.Length ? right[index] : "0";
            if (int.TryParse(l, out var ln) && int.TryParse(r, out var rn))
            {
                if (ln != rn) return ln > rn;
            }
            else if (!string.Equals(l, r, StringComparison.Ordinal))
            {
                return string.CompareOrdinal(l, r) > 0;
            }
        }
        return false;
    }
}
