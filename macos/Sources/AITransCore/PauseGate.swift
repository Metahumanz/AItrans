// PauseGate.swift - 任务暂停/继续的协作开关
//
// 翻译按波次（并发数）推进，暂停只在波次之间生效：已经发出的请求会跑完，
// 不会留下半截结果；继续后从下一波接着处理。取消通过 Task 取消触发，
// 暂停中的等待也必须能被取消唤醒，否则按钮会失效。

import Foundation

public final class PauseGate: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    public init() {}

    public var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    public func pause() {
        lock.lock()
        paused = true
        lock.unlock()
    }

    public func resume() {
        lock.lock()
        paused = false
        let pending = waiters
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume()
        }
    }

    /// 暂停时挂起，继续或取消时返回；取消会抛 `CancellationError`。
    public func waitIfPaused() async throws {
        try Task.checkCancellation()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !paused {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            cancelWaiters()
        }
    }

    private func cancelWaiters() {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()

        for waiter in pending {
            waiter.resume(throwing: CancellationError())
        }
    }
}
