using System.Diagnostics;

namespace AITrans.Core;

/// <summary>
/// Windows 安装版的自更新：下载 Inno Setup 安装包后静默覆盖当前安装目录。
///
/// 安装包带 <c>/CLOSEAPPLICATIONS</c>，会先关掉正在运行的 AITrans；
/// 安装完成后由 <c>/RESTARTAPPLICATIONS</c> 重新拉起。便携版（解压即用）
/// 目录里没有 unins000.exe，仍走下载 zip + 手动替换。
/// </summary>
public static class UpdateInstaller
{
    public static bool IsInstalled =>
        File.Exists(Path.Combine(AppContext.BaseDirectory, "unins000.exe"));

    /// <summary>只有安装包（.exe）才能静默升级；zip 是便携版产物。</summary>
    public static bool CanSelfInstall(UpdateInfo info) =>
        IsInstalled && IsInstallerAsset(info.DownloadUrl);

    public static bool IsInstallerAsset(string url) =>
        url.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);

    public static void Run(string installerPath)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = installerPath,
            Arguments = "/SILENT /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS /SP-",
            UseShellExecute = true,
        });
    }
}
