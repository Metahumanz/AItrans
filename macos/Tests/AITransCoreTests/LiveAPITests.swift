// LiveAPITests.swift - 真实接口测试（默认跳过）
//
// CI 不设置环境变量，因此这些用例在 CI 中会跳过。
// 本地验证：
//   AITRANS_LIVE_TEST=1 AITRANS_LIVE_KEY=... swift test --filter LiveAPITests

import XCTest
@testable import AITransCore

final class LiveAPITests: XCTestCase {
    private func liveClient() throws -> ChatClient {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AITRANS_LIVE_TEST"] == "1" else {
            throw XCTSkip("未开启真实接口测试")
        }
        guard let key = environment["AITRANS_LIVE_KEY"], !key.isEmpty else {
            throw XCTSkip("缺少 AITRANS_LIVE_KEY")
        }
        return ChatClient(
            baseURL: environment["AITRANS_LIVE_BASE"] ?? "https://api.deepseek.com",
            apiKey: key,
            model: environment["AITRANS_LIVE_MODEL"] ?? "deepseek-flash",
            policy: RetryPolicy(retries: 1)
        )
    }

    private func sampleBlocks() -> [SRTBlock] {
        [
            SRTBlock(
                raw: "1\n00:00:01,000 --> 00:00:03,000\nGood morning, everyone.",
                isValid: true,
                index: "1",
                timeline: "00:00:01,000 --> 00:00:03,000",
                original: "Good morning, everyone."
            ),
            SRTBlock(
                raw: "2\n00:00:03,500 --> 00:00:06,000\nLet's begin the meeting.",
                isValid: true,
                index: "2",
                timeline: "00:00:03,500 --> 00:00:06,000",
                original: "Let's begin the meeting."
            ),
        ]
    }

    func testTranslateAgainstRealProvider() async throws {
        let client = try liveClient()
        let translator = Translator(client: client)
        let blocks = sampleBlocks()

        let outcome = try await translator.translate(blocks: blocks, language: .zh, workers: 2)

        XCTAssertEqual(outcome.successCount, 2, "失败详情：\(outcome.failures)")
        for translation in outcome.translations {
            XCTAssertFalse(translation?.isEmpty ?? true)
        }
        let assembled = SRT.assemble(blocks, translations: outcome.translations)
        XCTAssertTrue(assembled.contains("Good morning, everyone."), "原文必须保留")
    }

    func testTranslateAndPolishAgainstRealProvider() async throws {
        let client = try liveClient()
        let translator = Translator(client: client)
        let blocks = sampleBlocks()

        let translated = try await translator.translate(blocks: blocks, language: .zh, workers: 2)
        let polished = try await translator.polish(
            blocks: blocks,
            translations: translated.translations,
            batchSize: 8,
            workers: 1
        )

        XCTAssertEqual(polished.errorCount, 0)
        XCTAssertFalse(polished.translations[0]?.isEmpty ?? true)
    }
}
