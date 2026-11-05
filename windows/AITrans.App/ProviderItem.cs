using AITrans.Core;
using Microsoft.UI.Xaml;

namespace AITrans.App;

/// <summary>提供商列表里的一行，附带「使用中」标记。</summary>
public sealed class ProviderItem
{
    public ProviderItem(Provider provider, bool isActive)
    {
        Provider = provider;
        IsActive = isActive;
    }

    public Provider Provider { get; }

    public bool IsActive { get; }

    public string Name => Provider.Name;

    public string BaseUrl => Provider.BaseUrl;

    public string Model => string.IsNullOrWhiteSpace(Provider.Model) ? "未指定模型" : Provider.Model;

    public string Badge => "使用中";

    public Visibility BadgeVisibility => IsActive ? Visibility.Visible : Visibility.Collapsed;
}
