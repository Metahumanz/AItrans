namespace AITrans.Core;

public enum RetryDecisionKind
{
    Retry,
    Fail,
}

public readonly record struct RetryDecision(RetryDecisionKind Kind, TimeSpan Delay)
{
    public static RetryDecision Retry(TimeSpan delay) => new(RetryDecisionKind.Retry, delay);
    public static RetryDecision Fail => new(RetryDecisionKind.Fail, TimeSpan.Zero);
}

/// <summary>失败重试的判定与退避，与 legacy 的 2^n 秒退避一致。</summary>
public sealed class RetryPolicy
{
    public int Retries { get; }
    public double BaseSeconds { get; }

    public RetryPolicy(int retries = Spec.DefaultRetries, double baseSeconds = 0)
    {
        Retries = Math.Max(0, retries);
        BaseSeconds = baseSeconds > 0 ? baseSeconds : Spec.RetryDelayBaseSeconds;
    }

    public TimeSpan DelayFor(int attempt) =>
        TimeSpan.FromSeconds(Math.Pow(BaseSeconds, attempt));

    public RetryDecision DecideForTransportError(int attempt) =>
        attempt >= Retries ? RetryDecision.Fail : RetryDecision.Retry(DelayFor(attempt));

    public RetryDecision DecideForStatus(int status, int attempt)
    {
        var retryable = Spec.RetryableHttpStatuses.Contains(status) || status >= Spec.RetryableHttpStatusAtLeast;
        if (!retryable || attempt >= Retries) return RetryDecision.Fail;
        return RetryDecision.Retry(DelayFor(attempt));
    }
}
