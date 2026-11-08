namespace AITrans.Core.Tests;

/// <summary>
/// 同步执行的进度收集器。
/// <see cref="Progress{T}"/> 会把回调投递到同步上下文，测试里会丢顺序，
/// 所以测试统一用这个实现按上报顺序记录。
/// </summary>
public sealed class SyncProgress<T> : IProgress<T>
{
    private readonly List<T> _values = [];

    public IReadOnlyList<T> Values => _values;

    public void Report(T value) => _values.Add(value);
}
