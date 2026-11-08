// TestSupport.swift - 测试共用的小工具

import AITransCore
import Foundation

/// 线程安全的进度回调收集器：回调可能在并发任务里触发。
final class ProgressRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
