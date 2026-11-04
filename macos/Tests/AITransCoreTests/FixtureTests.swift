// FixtureTests.swift - 用 fixtures/ 黄金样本验证解析与组装行为
//
// 黄金样本由 tools/gen_fixtures.py 调用 legacy Python 实现生成，
// 因此这里比对的是「与现有行为等价」，而不是「我认为应该是什么」。

import XCTest
@testable import AITransCore

final class FixtureTests: XCTestCase {
    struct ExpectedBlock: Decodable {
        let valid: Bool
        let raw: String
        let index: String?
        let timeline: String?
        let original: String?
    }

    struct Case: Decodable {
        let blocks: [ExpectedBlock]
        let translateOutput: String
        let polishOutput: String
    }

    struct Document: Decodable {
        let translatePrefix: String
        let polishPrefix: String
        let cases: [String: Case]
    }

    static let repoRoot: URL = {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // FixtureTests.swift
            .deletingLastPathComponent()  // AITransCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // macos
    }()

    static var document: Document!

    override class func setUp() {
        super.setUp()
        let url = repoRoot.appending(path: "fixtures/expected/srt.json")
        do {
            let data = try Data(contentsOf: url)
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            XCTFail("无法读取黄金样本 \(url.path): \(error)")
        }
    }

    func testDecodingMatchesLegacy() throws {
        for (name, expected) in Self.document.cases {
            let url = Self.repoRoot.appending(path: "fixtures/srt/\(name)")
            let text = TextDecoding.decode(try Data(contentsOf: url))
            let blocks = SRT.splitBlocks(text)
            XCTAssertEqual(blocks.count, expected.blocks.count, "\(name) 块数量不一致")
        }
    }

    func testBlocksMatchLegacy() throws {
        for (name, expected) in Self.document.cases.sorted(by: { $0.key < $1.key }) {
            let url = Self.repoRoot.appending(path: "fixtures/srt/\(name)")
            let text = TextDecoding.decode(try Data(contentsOf: url))
            let blocks = SRT.splitBlocks(text)

            for (offset, block) in blocks.enumerated() {
                let want = expected.blocks[offset]
                XCTAssertEqual(block.raw, want.raw, "\(name) #\(offset) raw 不一致")
                XCTAssertEqual(block.isValid, want.valid, "\(name) #\(offset) valid 不一致")
                XCTAssertEqual(block.index, want.index ?? "", "\(name) #\(offset) index 不一致")
                XCTAssertEqual(block.timeline, want.timeline ?? "", "\(name) #\(offset) timeline 不一致")
                XCTAssertEqual(block.original, want.original ?? "", "\(name) #\(offset) original 不一致")
            }
        }
    }

    func testAssembleTranslateMatchesLegacy() throws {
        let prefix = Self.document.translatePrefix
        for (name, expected) in Self.document.cases {
            let url = Self.repoRoot.appending(path: "fixtures/srt/\(name)")
            let text = TextDecoding.decode(try Data(contentsOf: url))
            let blocks = SRT.splitBlocks(text)
            let translations: [String?] = blocks.map { $0.isValid ? prefix + $0.original : nil }
            XCTAssertEqual(
                SRT.assemble(blocks, translations: translations),
                expected.translateOutput,
                "\(name) 翻译组装结果不一致"
            )
        }
    }

    func testAssemblePolishMatchesLegacy() throws {
        let translatePrefix = Self.document.translatePrefix
        let polishPrefix = Self.document.polishPrefix
        for (name, expected) in Self.document.cases {
            let url = Self.repoRoot.appending(path: "fixtures/srt/\(name)")
            let text = TextDecoding.decode(try Data(contentsOf: url))
            let blocks = SRT.splitBlocks(text)
            let translations: [String?] = blocks.map {
                $0.isValid ? polishPrefix + translatePrefix + $0.original : nil
            }
            XCTAssertEqual(
                SRT.assemble(blocks, translations: translations),
                expected.polishOutput,
                "\(name) 润色组装结果不一致"
            )
        }
    }

    func testStripQuotes() {
        XCTAssertEqual(SRT.stripQuotes("“你好”"), "你好")
        XCTAssertEqual(SRT.stripQuotes("\"hello\""), "hello")
        XCTAssertEqual(SRT.stripQuotes("你好"), "你好")
        XCTAssertEqual(SRT.stripQuotes("“他说“你好””"), "他说“你好”")
    }
}
