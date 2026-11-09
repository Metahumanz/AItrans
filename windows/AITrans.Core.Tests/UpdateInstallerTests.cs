using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

public sealed class UpdateInstallerTests
{
    [Theory]
    [InlineData("https://example.com/AITrans-0.3.7-win-x64-setup.exe", true)]
    [InlineData("https://example.com/AITrans-0.3.7-win-x64-setup.EXE", true)]
    [InlineData("https://example.com/AITrans-0.3.7-win-x64.zip", false)]
    public void DetectsInstallerAssets(string url, bool expected)
    {
        Assert.Equal(expected, UpdateInstaller.IsInstallerAsset(url));
    }
}
