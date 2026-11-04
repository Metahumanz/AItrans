// ProviderStore.swift - 提供商配置与密钥存储
//
// 与 v1 的差异：API Key 不再写进 providers.json，而是进系统钥匙串。
// JSON 结构保持兼容，便于从旧文件导入。

import Foundation
import Security

// MARK: - 密钥存储

public protocol SecretStoring: AnyObject, Sendable {
    func secret(for id: String) throws -> String?
    func setSecret(_ value: String, for id: String) throws
    func deleteSecret(for id: String) throws
}

/// macOS 钥匙串实现。
public final class KeychainSecretStore: SecretStoring, @unchecked Sendable {
    private let service: String

    public init(service: String = "com.metahumanz.aitrans.provider") {
        self.service = service
    }

    private func query(for id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
    }

    public func secret(for id: String) throws -> String? {
        var request = query(for: id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AITransError("读取钥匙串失败（\(status)）")
        }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String, for id: String) throws {
        let data = Data(value.utf8)
        let base = query(for: id)
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw AITransError("写入钥匙串失败（\(updateStatus)）")
        }

        var insert = base
        insert[kSecValueData as String] = data
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw AITransError("写入钥匙串失败（\(addStatus)）")
        }
    }

    public func deleteSecret(for id: String) throws {
        let status = SecItemDelete(query(for: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AITransError("删除钥匙串条目失败（\(status)）")
        }
    }
}

/// 测试与预览用的内存实现。
public final class MemorySecretStore: SecretStoring, @unchecked Sendable {
    private var values: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func secret(for id: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[id]
    }

    public func setSecret(_ value: String, for id: String) throws {
        lock.lock(); defer { lock.unlock() }
        values[id] = value
    }

    public func deleteSecret(for id: String) throws {
        lock.lock(); defer { lock.unlock() }
        values.removeValue(forKey: id)
    }
}

// MARK: - 校验

public enum ProviderValidation {
    static let idPattern = "^[a-z0-9][a-z0-9_-]{0,63}$"

    public static func makeID(name: String, taken: Set<String>) -> String {
        let lowered = name.lowercased()
        let replaced = lowered.replacingOccurrences(
            of: "[^a-z0-9]+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let shortened = String(trimmed.prefix(40))
        let base = shortened.isEmpty ? "provider" : shortened

        var candidate = base
        var index = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(index)"
            index += 1
        }
        return candidate
    }

    public static func normalize(_ provider: Provider, taken: Set<String>) throws -> Provider {
        let name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while baseURL.hasSuffix("/") { baseURL.removeLast() }
        let model = provider.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else { throw AITransError("请填写提供商名称。") }
        for (label, value) in [("提供商名称", name), ("接口地址", baseURL), ("模型名称", model), ("API Key", apiKey)] {
            guard !value.contains(where: { $0.asciiValue.map { $0 < 32 } ?? false }) else {
                throw AITransError("\(label)不能包含换行或控制字符。")
            }
        }
        guard name.count <= 80 else { throw AITransError("提供商名称不能超过 80 个字符。") }
        guard !baseURL.isEmpty else { throw AITransError("请填写接口地址。") }
        guard let url = URL(string: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            throw AITransError("接口地址必须以 http:// 或 https:// 开头。")
        }
        guard baseURL.count <= 500 else { throw AITransError("接口地址过长。") }
        guard !model.isEmpty else { throw AITransError("请填写模型名称。") }
        guard model.count <= 200 else { throw AITransError("模型名称过长。") }
        guard apiKey.count <= 1000 else { throw AITransError("API Key 过长。") }

        let rawID = provider.id.trimmingCharacters(in: .whitespaces)
        let id: String
        if rawID.isEmpty {
            id = makeID(name: name, taken: taken)
        } else {
            guard rawID.range(of: idPattern, options: .regularExpression) != nil else {
                throw AITransError("提供商标识只能包含小写字母、数字、- 和 _。")
            }
            id = rawID
        }

        return Provider(
            id: id,
            name: name,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            requiresKey: provider.requiresKey
        )
    }
}

// MARK: - 存储

public final class ProviderStore: @unchecked Sendable {
    public private(set) var providers: [Provider] = []
    public private(set) var activeID: String?

    private let secrets: SecretStoring

    public init(secrets: SecretStoring = KeychainSecretStore()) {
        self.secrets = secrets
    }

    public var activeProvider: Provider? {
        guard let activeID else { return nil }
        return providers.first { $0.id == activeID }
    }

    public func provider(id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    // MARK: 读写

    /// 读取 providers.json；密钥从钥匙串补齐。
    public func load(from url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            providers = []
            activeID = nil
            return
        }
        let data = try Data(contentsOf: url)
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let root else { throw AITransError("providers.json 格式不正确。") }

        let rawProviders = root["providers"] as? [[String: Any]] ?? []
        var loaded: [Provider] = []
        for item in rawProviders {
            guard let id = item["id"] as? String, !id.isEmpty else { continue }
            var provider = Provider(
                id: id,
                name: item["name"] as? String ?? id,
                baseURL: item["base_url"] as? String ?? "",
                model: item["model"] as? String ?? "",
                apiKey: item["api_key"] as? String ?? "",
                requiresKey: item["requires_key"] as? Bool ?? true
            )
            // 旧文件里可能有明文 key：优先用文件里的值并迁移到钥匙串。
            if !provider.apiKey.isEmpty {
                try? secrets.setSecret(provider.apiKey, for: id)
            } else {
                provider.apiKey = (try? secrets.secret(for: id)) ?? ""
            }
            loaded.append(provider)
        }
        providers = loaded
        activeID = root["active"] as? String
        if activeID != nil, provider(id: activeID!) == nil {
            activeID = providers.first?.id
        }
    }

    /// 保存 providers.json；密钥只进钥匙串。
    public func save(to url: URL) throws {
        let payload: [String: Any] = [
            "version": 1,
            "active": activeID.map { $0 as Any } ?? NSNull(),
            "providers": providers.map { item -> [String: Any] in
                [
                    "id": item.id,
                    "name": item.name,
                    "base_url": item.baseURL,
                    "model": item.model,
                    "requires_key": item.requiresKey,
                ]
            },
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: 变更

    @discardableResult
    public func upsert(_ provider: Provider, activate: Bool = false) throws -> Provider {
        let taken = Set(providers.filter { $0.id != provider.id }.map(\.id))
        let normalized = try ProviderValidation.normalize(provider, taken: taken)

        if let index = providers.firstIndex(where: { $0.id == normalized.id }) {
            providers[index] = normalized
        } else {
            providers.append(normalized)
        }
        try secrets.setSecret(normalized.apiKey, for: normalized.id)

        if activate || activeID == nil {
            activeID = normalized.id
        }
        return normalized
    }

    public func delete(id: String) throws {
        providers.removeAll { $0.id == id }
        try? secrets.deleteSecret(for: id)
        if activeID == id {
            activeID = providers.first?.id
        }
    }

    public func setActive(id: String) throws {
        guard providers.contains(where: { $0.id == id }) else {
            throw AITransError("提供商不存在：\(id)")
        }
        activeID = id
    }

    // MARK: 迁移

    /// 从 v1 的 providers.json / .env 导入。返回导入条数。
    @discardableResult
    public func importLegacy(profiles: URL?, env: URL?) throws -> Int {
        var imported = 0

        if let profiles, FileManager.default.fileExists(atPath: profiles.path) {
            try load(from: profiles)
            imported = providers.count
        }

        if imported == 0, let env, FileManager.default.fileExists(atPath: env.path) {
            let text = try String(contentsOf: env, encoding: .utf8)
            var values: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
                let key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                values[key] = value
            }
            let key = values["AI_API_KEY"] ?? values["DEEPSEEK_API_KEY"] ?? ""
            let baseURL = values["AI_BASE_URL"] ?? values["DEEPSEEK_BASE_URL"] ?? "https://api.deepseek.com"
            let model = values["AI_MODEL"] ?? "deepseek-flash"
            if !baseURL.isEmpty, !model.isEmpty {
                let provider = Provider(
                    id: values["AI_PROVIDER"] ?? "deepseek",
                    name: values["AI_PROVIDER_NAME"] ?? "DeepSeek",
                    baseURL: baseURL,
                    model: model,
                    apiKey: key,
                    requiresKey: true
                )
                _ = try upsert(provider, activate: true)
                imported = 1
            }
        }

        return imported
    }
}
