namespace AITrans.Core;

/// <summary>
/// 任务暂停/继续的协作开关。
///
/// 翻译按波次（并发数）推进，暂停只在波次之间生效：已经发出的请求会跑完，
/// 不会留下半截结果；继续后从下一波接着处理。取消通过 CancellationToken 触发，
/// 暂停中的等待也必须能被取消唤醒，否则「取消」按钮会失效。
/// </summary>
public sealed class PauseGate
{
    private readonly object _gate = new();
    private readonly List<TaskCompletionSource<bool>> _waiters = [];
    private bool _paused;

    public bool IsPaused
    {
        get
        {
            lock (_gate) return _paused;
        }
    }

    public void Pause()
    {
        lock (_gate) _paused = true;
    }

    public void Resume()
    {
        TaskCompletionSource<bool>[] pending;
        lock (_gate)
        {
            _paused = false;
            pending = _waiters.ToArray();
            _waiters.Clear();
        }

        foreach (var waiter in pending)
        {
            waiter.TrySetResult(true);
        }
    }

    /// <summary>暂停时挂起，继续或取消时返回；取消会抛 <see cref="OperationCanceledException"/>。</summary>
    public async Task WaitIfPausedAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();

        TaskCompletionSource<bool> signal;
        lock (_gate)
        {
            if (!_paused) return;
            signal = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            _waiters.Add(signal);
        }

        using var registration = cancellationToken.Register(() => signal.TrySetCanceled(cancellationToken));
        try
        {
            await signal.Task.ConfigureAwait(false);
        }
        finally
        {
            lock (_gate) _waiters.Remove(signal);
        }
    }
}
