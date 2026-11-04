// TranslatorTests.swift - 端到端验证：翻译 + 润色 + 组装 与 legacy 一致
//
// 假模型的行为与 tools/gen_fixtures.py 中的 fake_chat_completion 完全一致，
// 因此最终文本可以直接与 Python 生成的黄金样本比对。

import XCTest
@testable import AITransCore

/// 与 tools/gen_fixtures.py 的假模型等价。
struct FakeChatClient: ChatCompleting {
    static let translatePrefix = "〔译〕"
    static let polishPrefix = "〔润〕"

    func complete(messages: [ChatMessage]) async throws -> String {
        let system = messages[0].content
        let user = messages[1].content

        if system.contains("润色") {
            let section = user.components(separatedBy: "【本批次译文】").last ?? ""
            let body = section.components(separatedBy: "\n\n请按").first ?? section
            let regex = try! NSRegularExpression(
                pattern: #"^\[(\d+)\] (.*?)(?=\n\[\d+\] |\z)"#,
                options: [.dotMatchesLineSeparators, .anchorsMatchLines]
            )
            let ns = body as NSString
            let matches = regex.matches(in: body, range: NSRange(location: 0, length: ns.length))
            let lines = matches.compactMap { match -> String? in
                guard match.numberOfRanges >= 3 else { return nil }
                let number = ns.substring(with: match.range(at: 1))
                let text = ns.substring(with: match.range(at: 2))
                return "[\(number)] \(Self.polishPrefix)\(text)"
            }
            return lines.joined(separator: "\n")
        }

        return "“\(Self.translatePrefix)\(user)”"
    }
}

final class TranslatorTests: XCTestCase {
    typealias Document = FixtureTests.Document
    typealias Case = FixtureTests.Case

    static let document: Document = {
        let url = FixtureTests.repoRoot.appending(path: "fixtures/expected/srt.json")
        do {
            return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
        } catch {
            fatalError("无法读取黄金样本：\(error)")
        }
    }()

    func testTranslateOnlyMatchesLegacy() async throws {
        for (name, expected) in Self.document.cases {
            let blocks = try loadBlocks(name)
            let translator = Translator(client: FakeChatClient())
            let outcome = try await translator.translate(blocks: blocks, language: .zh, workers: 3)
            XCTAssertEqual(outcome.errorCount, 0, "\(name) 不应有失败")
            XCTAssertEqual(
                SRT.assemble(blocks, translations: outcome.translations),
                expected.translateOutput,
                "\(name) 翻译结果不一致"
            )
        }
    }

    func testTranslateThenPolishMatchesLegacy() async throws {
        for (name, expected) in Self.document.cases {
            let blocks = try loadBlocks(name)
            let translator = Translator(client: FakeChatClient())
            let translated = try await translator.translate(blocks: blocks, language: .zh, workers: 3)
            let polished = try await translator.polish(
                blocks: blocks,
                translations: translated.translations,
                batchSize: 8,
                workers: 2
            )
            XCTAssertEqual(polished.errorCount, 0, "\(name) 润色不应有失败")
            XCTAssertEqual(
                SRT.assemble(blocks, translations: polished.translations),
                expected.polishOutput,
                "\(name) 润色结果不一致"
            )
        }
    }

    func testTranslateFailureKeepsOriginal() async throws {
        struct FailingClient: ChatCompleting {
            func complete(messages: [ChatMessage]) async throws -> String {
                throw ChatHTTPError(status: 400, message: "HTTP 400: bad request")
            }
        }
        let blocks = try loadBlocks("basic-utf8.srt")
        let translator = Translator(client: FailingClient())
        let outcome = try await translator.translate(blocks: blocks, language: .zh, workers: 2)
        XCTAssertEqual(outcome.successCount, 0)
        XCTAssertEqual(outcome.errorCount, 3)
        // 失败块回退为原文，输出仍应可组装。
        let text = SRT.assemble(blocks, translations: outcome.translations)
        XCTAssertTrue(text.contains("Good morning, everyone."))
    }

    // MARK: - 批量解析的三种格式

    func testParseBracketFormat() {
        let parsed = Translator.parseBatchResult("[0] 你好\n[1] 世界", indices: [0, 1])
        XCTAssertEqual(parsed[0], "你好")
        XCTAssertEqual(parsed[1], "世界")
    }

    func testParseNumericDotFormat() {
        let parsed = Translator.parseBatchResult("0. 你好\n1. 世界", indices: [0, 1])
        XCTAssertEqual(parsed[0], "你好")
        XCTAssertEqual(parsed[1], "世界")
    }

    func testParseLinewiseFallback() {
        let parsed = Translator.parseBatchResult("你好\n世界", indices: [3, 4])
        XCTAssertEqual(parsed[3], "你好")
        XCTAssertEqual(parsed[4], "世界")
    }

    func testParseMultilineEntry() {
        let parsed = Translator.parseBatchResult("[2] 第一行\n第二行\n[3] 别的", indices: [2, 3])
        XCTAssertEqual(parsed[2], "第一行\n第二行")
        XCTAssertEqual(parsed[3], "别的")
    }

    // MARK: - helpers

    private func loadBlocks(_ name: String) throws -> [SRTBlock] {
        let url = FixtureTests.repoRoot.appending(path: "fixtures/srt/\(name)")
        return SRT.splitBlocks(TextDecoding.decode(try Data(contentsOf: url)))
    }
}
