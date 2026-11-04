// RetryPolicy.swift - 失败重试的判定与退避

import Foundation

/// 一次请求失败后是否值得重试。
public enum RetryDecision: Equatable, Sendable {
    case retry(afterSeconds: TimeInterval)
    case fail
}

public struct RetryPolicy: Sendable {
    public let retries: Int
    public let baseSeconds: Double

    public init(retries: Int = Spec.defaultRetries, baseSeconds: Double = Double(Spec.retryDelayBaseSeconds)) {
        self.retries = max(0, retries)
        self.baseSeconds = baseSeconds
    }

    /// 第 `attempt` 次（从 0 开始）失败后的退避时长：1、2、4、8…
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        pow(baseSeconds, Double(attempt))
    }

    /// 传输层错误（超时、断网、连接被拒）一律可重试。
    public func decision(forTransportErrorAt attempt: Int) -> RetryDecision {
        attempt >= retries ? .fail : .retry(afterSeconds: delay(forAttempt: attempt))
    }

    /// HTTP 状态码：429 与 5xx 可重试，其余 4xx 直接失败。
    public func decision(forStatus status: Int, attempt: Int) -> RetryDecision {
        let retryable = Spec.retryableHTTPStatuses.contains(status) || status >= Spec.retryableHTTPStatusAtLeast
        guard retryable, attempt < retries else { return .fail }
        return .retry(afterSeconds: delay(forAttempt: attempt))
    }
}
