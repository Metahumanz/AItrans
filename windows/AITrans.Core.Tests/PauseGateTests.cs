using AITrans.Core;
using Xunit;

namespace AITrans.Core.Tests;

public sealed class PauseGateTests
{
    [Fact]
    public async Task WaitReturnsImmediatelyWhenNotPaused()
    {
        var gate = new PauseGate();
        await gate.WaitIfPausedAsync();
        Assert.False(gate.IsPaused);
    }

    [Fact]
    public async Task PauseBlocksUntilResume()
    {
        var gate = new PauseGate();
        gate.Pause();
        Assert.True(gate.IsPaused);

        var resumed = false;
        var task = Task.Run(async () =>
        {
            await gate.WaitIfPausedAsync();
            resumed = true;
        });

        await Task.Delay(100);
        Assert.False(resumed);

        gate.Resume();
        await task;
        Assert.True(resumed);
    }

    [Fact]
    public async Task CancellationUnblocksPausedWait()
    {
        var gate = new PauseGate();
        gate.Pause();

        using var cts = new CancellationTokenSource();
        var task = gate.WaitIfPausedAsync(cts.Token);
        await Task.Delay(100);
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => task);
    }
}
