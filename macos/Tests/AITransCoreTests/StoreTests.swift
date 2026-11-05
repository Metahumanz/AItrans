// StoreTests.swift - 提供商与设置的持久化、校验

import XCTest
@testable import AITransCore

private final class CountingSecretStore: SecretStoring, @unchecked Sendable {
    private let inner = MemorySecretStore()
    private(set) var reads = 0
    private(set) var writes = 0

    func secret(for id: String) throws -> String? {
        reads += 1
        return try inner.secret(for: id)
    }

    func setSecret(_ value: String, for id: String) throws {
        writes += 1
        try inner.setSecret(value, for: id)
    }

    func deleteSecret(for id: String) throws {
        try inner.deleteSecret(for: id)
    }
}

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
        XCTAssertEqual(reloaded.provider(id: "acme")?.apiKey, "", "加载阶段不应读密钥存储")
        let hydrated = try reloaded.hydrate(XCTUnwrap(reloaded.provider(id: "acme")))
        XCTAssertEqual(hydrated.apiKey, "sk-secret")
    }

    func testLoadDefersSecretReadsUntilHydrate() throws {
        let secrets = CountingSecretStore()
        let writer = ProviderStore(secrets: secrets)
        _ = try writer.upsert(sample(id: "acme"), activate: true)

        let path = tempDir.appending(path: "providers.json")
        try writer.save(to: path)
        let readsAfterWrite = secrets.reads

        let store = ProviderStore(secrets: secrets)
        try store.load(from: path)
        XCTAssertEqual(secrets.reads, readsAfterWrite, "load 不应访问密钥存储")
        XCTAssertEqual(store.provider(id: "acme")?.apiKey, "")

        let hydrated = try store.hydrate(XCTUnwrap(store.provider(id: "acme")))
        XCTAssertEqual(hydrated.apiKey, "sk-secret")
        XCTAssertEqual(secrets.reads, readsAfterWrite + 1)
    }

    func testSaveMigratesPlaintextKeyIntoSecretStore() throws {
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
        XCTAssertNil(try secrets.secret(for: "old"), "加载阶段不应写密钥存储")

        try store.save(to: path)
        XCTAssertEqual(try secrets.secret(for: "old"), "sk-plain", "保存时明文 key 应迁移到密钥存储")
    }

    func testFileSecretStoreRoundTripAndPermissions() throws {
        let path = tempDir.appending(path: "secrets.json")
        let store = FileSecretStore(path: path)

        XCTAssertNil(try store.secret(for: "deepseek"))
        try store.setSecret("sk-local", for: "deepseek")
        XCTAssertEqual(try store.secret(for: "deepseek"), "sk-local")

        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try store.setSecret("", for: "deepseek")
        XCTAssertNil(try store.secret(for: "deepseek"), "空值应删除对应条目")

        try store.setSecret("sk-delete", for: "other")
        try store.deleteSecret(for: "other")
        XCTAssertNil(try store.secret(for: "other"))
    }

    func testFileSecretStoreRejectsCorruptFile() throws {
        let path = tempDir.appending(path: "secrets.json")
        try "not json".write(to: path, atomically: true, encoding: .utf8)

        let store = FileSecretStore(path: path)
        XCTAssertThrowsError(try store.secret(for: "deepseek"))
    }

    func testProviderStorePersistsSecretsInLocalFile() throws {
        let secretsPath = tempDir.appending(path: "secrets.json")
        let providersPath = tempDir.appending(path: "providers.json")
        let store = ProviderStore(secrets: FileSecretStore(path: secretsPath))
        _ = try store.upsert(sample(id: "acme"), activate: true)
        try store.save(to: providersPath)

        let providersJSON = try String(contentsOf: providersPath, encoding: .utf8)
        XCTAssertFalse(providersJSON.contains("sk-secret"), "密钥不应写进 providers.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: secretsPath.path))

        let reloaded = ProviderStore(secrets: FileSecretStore(path: secretsPath))
        try reloaded.load(from: providersPath)
        XCTAssertEqual(reloaded.provider(id: "acme")?.apiKey, "")
        let hydrated = try reloaded.hydrate(XCTUnwrap(reloaded.provider(id: "acme")))
        XCTAssertEqual(hydrated.apiKey, "sk-secret")
    }

    func testDeleteClearsActiveWhenNeeded() throws {
        let secrets = MemorySecretStore()
        let store = ProviderStore(secrets: secrets)
        _ = try store.upsert(sample(id: "one"), activate: true)
        _ = try store.upsert(sample(id: "two", name: "第二个"))

        try store.delete(id: "one")
        XCTAssertEqual(store.activeID, "two")
        XCTAssertNil(try secrets.secret(for: "one"), "删除提供商时应同时删除密钥")
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

    func testAutoCheckDefaultsToOnAndRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "aitrans-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appending(path: "settings.json")
        let store = SettingsStore()
        XCTAssertTrue(store.settings.autoCheckUpdates)

        store.update { $0.autoCheckUpdates = false }
        try store.save(to: path)
        // Foundation 的 prettyPrinted 输出是 `"key" : value`，只断言键名和值。
        let json = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(json.contains("\"auto_check_updates\""))
        XCTAssertTrue(json.contains("false"))

        let reloaded = SettingsStore()
        try reloaded.load(from: path)
        XCTAssertFalse(reloaded.settings.autoCheckUpdates)
    }

    func testMissingAutoCheckKeyKeepsDefault() throws {
        // 老版本写下的配置里没有 auto_check_updates：不能整份解码失败，也不能丢掉其它字段。
        let dir = FileManager.default.temporaryDirectory.appending(path: "aitrans-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let path = dir.appending(path: "settings.json")
        let legacy = """
        { "version": 1, "backend": "api", "lang": "zh", "translate": true,
          "polish": true, "output_mode": "source", "suffix": "_translated" }
        """
        try legacy.write(to: path, atomically: true, encoding: .utf8)

        let store = SettingsStore()
        try store.load(from: path)
        XCTAssertTrue(store.settings.autoCheckUpdates)
        XCTAssertTrue(store.settings.translate)
        XCTAssertEqual(store.settings.suffix, "_translated")
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
