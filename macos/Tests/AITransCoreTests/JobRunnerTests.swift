// JobRunnerTests.swift - 文件级流程：跳过、强制、输出位置、错误处理

import XCTest
@testable import AITransCore

final class JobRunnerTests: XCTestCase {
    var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appending(path: "aitrans-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    private func makeRunner() -> JobRunner {
        JobRunner(translator: Translator(client: FakeChatClient()))
    }

    private func copyFixture(_ name: String, to directory: URL) throws -> URL {
        let source = FixtureTests.repoRoot.appending(path: "fixtures/srt/\(name)")
        let destination = directory.appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func testWritesTranslatedFileNextToSource() async throws {
        let file = try copyFixture("basic-utf8.srt", to: workDir)
        var settings = AppSettings()
        settings.outputMode = .source
        settings.polish = false
        settings.force = false

        let results = try await makeRunner().run(
            files: [file],
            settings: settings,
            outputDirectory: workDir.appending(path: "output"),
            customDirectory: nil
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].status, .success)

        let output = workDir.appending(path: "basic-utf8_translated.srt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("〔译〕Good morning, everyone."))
        XCTAssertTrue(text.contains("Good morning, everyone."))
    }

    func testSkipsExistingOutputWithoutForce() async throws {
        let file = try copyFixture("basic-utf8.srt", to: workDir)
        let output = workDir.appending(path: "basic-utf8_translated.srt")
        try "已有内容".write(to: output, atomically: true, encoding: .utf8)

        var settings = AppSettings()
        settings.outputMode = .source
        settings.force = false

        let results = try await makeRunner().run(
            files: [file],
            settings: settings,
            outputDirectory: workDir,
            customDirectory: nil
        )

        XCTAssertEqual(results[0].status, .skipped)
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "已有内容")
    }

    func testForceOverwritesExistingOutput() async throws {
        let file = try copyFixture("basic-utf8.srt", to: workDir)
        let output = workDir.appending(path: "basic-utf8_translated.srt")
        try "旧内容".write(to: output, atomically: true, encoding: .utf8)

        var settings = AppSettings()
        settings.outputMode = .source
        settings.force = true
        settings.polish = false

        let results = try await makeRunner().run(
            files: [file],
            settings: settings,
            outputDirectory: workDir,
            customDirectory: nil
        )

        XCTAssertEqual(results[0].status, .success)
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertNotEqual(text, "旧内容")
        XCTAssertTrue(text.contains("〔译〕"))
    }

    func testOutputDirectoryModeKeepsFileName() async throws {
        let file = try copyFixture("gbk.srt", to: workDir)
        let outputDir = workDir.appending(path: "out")
        var settings = AppSettings()
        settings.outputMode = .output
        settings.polish = false

        _ = try await makeRunner().run(
            files: [file],
            settings: settings,
            outputDirectory: outputDir,
            customDirectory: nil
        )

        let output = outputDir.appending(path: "gbk.srt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let text = try String(contentsOf: output, encoding: .utf8)
        XCTAssertTrue(text.contains("早上好，各位。"))
    }

    func testRejectsTooManyFiles() async throws {
        let files = (0...JobRunner.maxFiles).map { workDir.appending(path: "f\($0).srt") }
        var settings = AppSettings()
        settings.outputMode = .output

        do {
            _ = try await makeRunner().run(
                files: files,
                settings: settings,
                outputDirectory: workDir,
                customDirectory: nil
            )
            XCTFail("应当拒绝超过上限的文件数")
        } catch let error as AITransError {
            XCTAssertTrue(error.message.contains("最多"))
        }
    }

    func testOllamaBackendRunsWithSamePipeline() async throws {
        let file = try copyFixture("basic-utf8.srt", to: workDir)
        var settings = AppSettings()
        settings.backend = .ollama
        settings.outputMode = .source
        settings.polish = false

        let results = try await makeRunner().run(
            files: [file],
            settings: settings,
            outputDirectory: workDir,
            customDirectory: nil
        )

        XCTAssertEqual(results[0].status, .success)
        let output = workDir.appending(path: "basic-utf8_translated.srt")
        XCTAssertTrue(try String(contentsOf: output, encoding: .utf8).contains("〔译〕"))
    }
}
