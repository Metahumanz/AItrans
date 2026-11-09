// PauseGateTests.swift - 暂停/继续与取消的协作开关

import XCTest
@testable import AITransCore

private actor Flag {
    private(set) var value = false

    func set() {
        value = true
    }
}

final class PauseGateTests: XCTestCase {
    func testWaitReturnsImmediatelyWhenNotPaused() async throws {
        let gate = PauseGate()
        try await gate.waitIfPaused()
        XCTAssertFalse(gate.isPaused)
    }

    func testPauseBlocksUntilResume() async throws {
        let gate = PauseGate()
        gate.pause()
        XCTAssertTrue(gate.isPaused)

        let flag = Flag()
        let task = Task {
            try await gate.waitIfPaused()
            await flag.set()
        }

        try await Task.sleep(for: .milliseconds(100))
        let blocked = await flag.value
        XCTAssertFalse(blocked)

        gate.resume()
        try await task.value
        let resumed = await flag.value
        XCTAssertTrue(resumed)
    }

    func testCancellationUnblocksPausedWait() async throws {
        let gate = PauseGate()
        gate.pause()

        let task = Task {
            try await gate.waitIfPaused()
        }

        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        do {
            try await task.value
            XCTFail("暂停中的等待应当被取消唤醒")
        } catch is CancellationError {
            // 预期路径。
        } catch {
            XCTFail("应抛出 CancellationError，实际：\(error)")
        }
    }
}
