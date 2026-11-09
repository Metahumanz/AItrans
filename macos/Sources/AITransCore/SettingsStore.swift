// SettingsStore.swift - 设置持久化与取值范围收敛

import Foundation

public final class SettingsStore: @unchecked Sendable {
    public private(set) var settings: AppSettings

    public init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    public func load(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        guard let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            throw AITransError("settings.json 格式不正确，已使用默认设置。")
        }
        settings = Self.sanitize(decoded)
    }

    public func save(to url: URL) throws {
        settings = Self.sanitize(settings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// 用外部传入的设置替换当前值（会先收敛）。
    public func replace(with newSettings: AppSettings) {
        settings = Self.sanitize(newSettings)
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        settings = Self.sanitize(settings)
    }

    /// 与 v1 的 _clean_settings 对齐：并发 1–64、重试 0–5、后缀非空。
    public static func sanitize(_ input: AppSettings) -> AppSettings {
        var result = input
        result.version = 1
        result.apiWorkers = min(64, max(1, result.apiWorkers))
        result.ollamaWorkers = min(64, max(1, result.ollamaWorkers))
        result.apiRetries = min(5, max(0, result.apiRetries))
        result.ollamaRetries = min(5, max(0, result.ollamaRetries))
        if result.suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.suffix = "_translated"
        }
        if result.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.ollamaModel = "qwen2.5"
        }
        result.downloadDir = result.downloadDir
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
