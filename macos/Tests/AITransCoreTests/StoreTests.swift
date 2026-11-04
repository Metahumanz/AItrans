// StoreTests.swift - 提供商与设置的持久化、校验

import XCTest
@testable import AITransCore

final class ProviderStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "aitrans-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sample(id: String = "", name: String = "测试提供商") -> Provider {
        Provider(
            id: id,
            name: name,
            baseURL: "https://api.example.com/v1/",
            model: "test-model",
            apiKey: "sk-secret",
            requiresKey: true
        )
    }

    func testNormalizesAndGeneratesId() throws {
        let provider = try ProviderValidation.normalize(sample(), taken: [])
        XCTAssertEqual(provider.baseURL, "https://api.example.com/v1")
        XCTAssertFalse(provider.id.isEmpty)
    }

    func testRejectsInvalidURL() {
        var broken = sample()
        broken.baseURL = "ftp://example.com"
        XCTAssertThrowsError(try ProviderValidation.normalize(broken, taken: []))
    }

    func testRejectsEmptyName() {
        var broken = sample()
        broken.name = "   "
        XCTAssertThrowsError(try ProviderValidation.normalize(broken, taken: []))
    }

    func testRejectsControlCharacters() {
        var broken = sample()
        broken.name = "bad\nname"
        XCTAssertThrowsError(try ProviderValidation.normalize(broken, taken: []))
    }

    func testGeneratesUniqueIDs() {
        let id = ProviderValidation.makeID(name: "Provider", taken: ["provider", "provider-2"])
        XCTAssertEqual(id, "provider-3")
    }

    func testSaveKeepsSecretsOutOfJSON() throws {
        let secrets = MemorySecretStore()
        let store = ProviderStore(secrets: secrets)
        _ = try store.upsert(sample(id: "acme"), activate: true)

        let path = tempDir.appending(path: "providers.json")
        try store.save(to: path)

        let json = try String(contentsOf: path, encoding: .utf8)
        XCTAssertFalse(json.contains("sk-secret"), "密钥不应写进 JSON")
        XCTAssertTrue(json.contains("\"acme\""))

        let reloaded = ProviderStore(secrets: secrets)
        try reloaded.load(from: path)
        XCTAssertEqual(reloaded.activeID, "acme")
        XCTAssertEqual(reloaded.provider(id: "acme")?.apiKey, "sk-secret")
    }

    func testLoadMigratesPlaintextKeyIntoKeychain() throws {
        let path = tempDir.appending(path: "providers.json")
        let legacy = """
        {
          "version": 1,
          "active": "old",
          "providers": [
            {"id": "old", "name": "旧版", "base_url": "https://api.example.com", "model": "m", "api_key": "sk-plain", "requires_key": true}
          ]
        }
        """
        try legacy.write(to: path, atomically: true, encoding: .utf8)

        let secrets = MemorySecretStore()
        let store = ProviderStore(secrets: secrets)
        try store.load(from: path)

        XCTAssertEqual(store.provider(id: "old")?.apiKey, "sk-plain")
        XCTAssertEqual(try secrets.secret(for: "old"), "sk-plain", "明文 key 应迁移到密钥存储")
    }

    func testDeleteClearsActiveWhenNeeded() throws {
        let store = ProviderStore(secrets: MemorySecretStore())
        _ = try store.upsert(sample(id: "one"), activate: true)
        _ = try store.upsert(sample(id: "two", name: "第二个"))

        try store.delete(id: "one")
        XCTAssertEqual(store.activeID, "two")
    }

    func testImportLegacyEnv() throws {
        let env = tempDir.appending(path: ".env")
        try """
        # 注释
        AI_PROVIDER=deepseek
        AI_PROVIDER_NAME=DeepSeek
        AI_API_KEY=sk-legacy
        AI_BASE_URL=https://api.deepseek.com
        AI_MODEL=deepseek-flash
        """.write(to: env, atomically: true, encoding: .utf8)

        let store = ProviderStore(secrets: MemorySecretStore())
        let imported = try store.importLegacy(profiles: nil, env: env)

        XCTAssertEqual(imported, 1)
        XCTAssertEqual(store.activeID, "deepseek")
        XCTAssertEqual(store.activeProvider?.apiKey, "sk-legacy")
    }
}

final class SettingsStoreTests: XCTestCase {
    func testSanitizesOutOfRangeValues() {
        var settings = AppSettings()
        settings.apiWorkers = 999
        settings.apiRetries = -3
        settings.suffix = "   "
        settings.ollamaModel = ""

        let clean = SettingsStore.sanitize(settings)
        XCTAssertEqual(clean.apiWorkers, 64)
        XCTAssertEqual(clean.apiRetries, 0)
        XCTAssertEqual(clean.suffix, "_translated")
        XCTAssertEqual(clean.ollamaModel, "qwen2.5")
    }

    func testReplacePersistsSanitizedValues() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aitrans-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appending(path: "settings.json")
        let store = SettingsStore()
        var changed = store.settings
        changed.apiWorkers = 999
        changed.apiRetries = 9

        store.replace(with: changed)
        try store.save(to: path)

        XCTAssertEqual(store.settings.apiWorkers, 64)
        XCTAssertEqual(store.settings.apiRetries, 5)

        let reloaded = SettingsStore()
        try reloaded.load(from: path)
        XCTAssertEqual(reloaded.settings.apiWorkers, 64)
        XCTAssertEqual(reloaded.settings.apiRetries, 5)
    }

    func testRoundTripUsesContractKeys() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aitrans-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appending(path: "settings.json")
        let store = SettingsStore()
        store.update { settings in
            settings.backend = .ollama
            settings.lang = .ja
            settings.outputMode = .custom
        }
        try store.save(to: path)

        let json = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(json.contains("\"backend\""))
        XCTAssertTrue(json.contains("\"output_mode\""))
        XCTAssertTrue(json.contains("\"ollama\""))

        let reloaded = SettingsStore()
        try reloaded.load(from: path)
        XCTAssertEqual(reloaded.settings.backend, .ollama)
        XCTAssertEqual(reloaded.settings.lang, .ja)
        XCTAssertEqual(reloaded.settings.outputMode, .custom)
    }
}

final class UpdateCheckerTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }
}
