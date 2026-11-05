// ProviderStore.swift - 提供商配置与密钥存储
//
// 与 v1 的差异：API Key 不写进 providers.json，而是保存在本地 secrets.json（0600）。
// 不使用 macOS 钥匙串：避免 ad-hoc 签名变化后每次升级都触发 ACL 授权框。
// JSON 结构保持兼容，便于从旧文件导入。

import Darwin
import Foundation

// MARK: - 密钥存储

public protocol SecretStoring: AnyObject, Sendable {
    func secret(for id: String) throws -> String?
    func setSecret(_ value: String, for id: String) throws
    func deleteSecret(for id: String) throws
}

/// 本地密钥文件实现。
///
/// 密钥保存在 `secrets.json`，文件权限 0600；不进入 `providers.json`，也不访问钥匙串。
/// 代价是文件本身为明文，安全性依赖用户目录权限；这是为了摆脱 Keychain ACL 授权框做的取舍。
public final class FileSecretStore: SecretStoring, @unchecked Sendable {
    private let path: URL

    /// 同进程内按路径共享锁：两个实例同时读改写时先在 NSLock 上排队，
    /// 避免各自拿 flock 互相等待（flock 按 open file description 计，同进程不同 fd 也会阻塞）。
    private static let registryLock = NSLock()
    private static var sharedLocks: [String: NSLock] = [:]

    public init(path: URL = AppPaths.secretsFile) {
        self.path = path
    }

    private static func sharedLock(for path: String) -> NSLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = sharedLocks[path] { return existing }
        let created = NSLock()
        sharedLocks[path] = created
        return created
    }

    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw AITransError("密钥文件格式不正确：\(path.lastPathComponent)")
        }
        return object
    }

    private func ensurePrivateDirectory() throws {
        let directory = path.deletingLastPathComponent()
        guard directory.path.hasPrefix("/") else {
            throw AITransError("密钥文件路径必须是绝对路径：\(path.path)")
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // 原子写会先在同目录生成临时文件。先把目录收紧到 0700，
        // 临时文件在最终 chmod 之前也不会被其他用户读到。
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func save(_ values: [String: String]) throws {
        try ensurePrivateDirectory()
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    /// 用跨进程文件锁包住读改写；同进程内先过共享 NSLock，避免两个实例互等。
    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        let lock = Self.sharedLock(for: path.path)
        lock.lock()
        defer { lock.unlock() }

        try ensurePrivateDirectory()
        let lockPath = path.path + ".lock"
        let descriptor = open(lockPath, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw AITransError("无法打开密钥锁文件：\(lockPath)")
        }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw AITransError("无法锁定密钥文件：\(lockPath)")
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// 读取不加锁、不创建目录或锁文件：写入是「临时文件 + rename」的原子替换，
    /// 读到的要么是旧文件要么是新文件。这样打开提供商面板不会在磁盘上留下额外文件。
    public func secret(for id: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        return try load()[id]
    }

    public func setSecret(_ value: String, for id: String) throws {
        if value.isEmpty, !FileManager.default.fileExists(atPath: path.path) { return }
        try withFileLock {
            var values = try load()
            if value.isEmpty {
                values.removeValue(forKey: id)
            } else {
                values[id] = value
            }
            try save(values)
        }
    }

    public func deleteSecret(for id: String) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        try withFileLock {
            var values = try load()
            if values.removeValue(forKey: id) != nil {
                try save(values)
            }
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
        if value.isEmpty {
            values.removeValue(forKey: id)
        } else {
            values[id] = value
        }
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

    /// macOS 的 App Transport Security 只放行本机与局域网明文 HTTP；
    /// 公网 `http://` 会被系统直接拦截，因此保存时就拒绝，避免用户到发请求时才看到英文 ATS 报错。
    static func allowsCleartextHTTP(host: String) -> Bool {
        let host = host.lowercased()
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        if host.hasSuffix(".local") { return true }
        // 不带点的主机名按本地网络处理（ATS 的 NSAllowsLocalNetworking 行为）。
        if !host.contains("."), !host.contains(":") { return true }

        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 {
            let octets = parts.compactMap { Int($0) }
            if octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) {
                switch (octets[0], octets[1]) {
                case (127, _), (10, _), (192, 168), (172, 16...31), (169, 254):
                    return true
                default:
                    return false
                }
            }
        }

        // IPv6 ULA（fc00::/7）与 link-local（fe80::/10）。
        if host.contains(":") {
            return host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9")
                || host.hasPrefix("fea") || host.hasPrefix("feb")
        }
        return false
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
        if scheme == "http", let host = url.host, !allowsCleartextHTTP(host: host) {
            throw AITransError("公网地址请使用 https://（macOS 会拦截公网明文 HTTP；本机或局域网地址仍可用 http）。")
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

    public init(secrets: SecretStoring = FileSecretStore()) {
        self.secrets = secrets
    }

    public var activeProvider: Provider? {
        guard let activeID else { return nil }
        return providers.first { $0.id == activeID }
    }

    public func provider(id: String) -> Provider? {
        providers.first { $0.id == id }
    }

    /// 按需从本地密钥文件补齐密钥。
    ///
    /// 启动时只读 providers.json，不碰 secrets.json；真正要发请求或编辑提供商时再调用这里。
    /// 旧版明文 key 会在载入后由 `migratePlaintextKeys(to:)` 迁走。
    public func hydrate(_ provider: Provider) throws -> Provider {
        guard provider.apiKey.isEmpty, !provider.id.isEmpty else { return provider }
        var hydrated = provider
        hydrated.apiKey = try secrets.secret(for: provider.id) ?? ""
        return hydrated
    }

    /// 按需补齐当前提供商的密钥。
    public func hydrateActive() throws -> Provider? {
        guard let activeProvider else { return nil }
        return try hydrate(activeProvider)
    }

    // MARK: 读写

    /// 读取 providers.json；只解析文件，不读取密钥。
    ///
    /// 旧文件里的明文 `api_key` 会先留在内存里，由调用方在载入后调用
    /// `migratePlaintextKeys(to:)` 迁移；`save` 也会兜底迁移。
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
            let provider = Provider(
                id: id,
                name: item["name"] as? String ?? id,
                baseURL: item["base_url"] as? String ?? "",
                model: item["model"] as? String ?? "",
                apiKey: item["api_key"] as? String ?? "",
                requiresKey: item["requires_key"] as? Bool ?? true
            )
            // 旧文件里的明文 key 暂留内存，载入后由 migratePlaintextKeys 迁移。
            loaded.append(provider)
        }
        providers = loaded
        activeID = root["active"] as? String
        if activeID != nil, provider(id: activeID!) == nil {
            activeID = providers.first?.id
        }
    }

    /// 把旧版 providers.json 里的明文 key 迁移到 secrets.json，并重写 providers.json。
    ///
    /// 返回迁移的条数。应在 `load` 之后、`hydrate` 之前调用；只处理内存里带 key 的条目，
    /// 因此重复调用是安全的。
    @discardableResult
    public func migratePlaintextKeys(to url: URL) throws -> Int {
        let pending = providers.filter { !$0.apiKey.isEmpty }
        guard !pending.isEmpty else { return 0 }

        for provider in pending {
            try secrets.setSecret(provider.apiKey, for: provider.id)
        }
        for index in providers.indices where !providers[index].apiKey.isEmpty {
            providers[index].apiKey = ""
        }
        try save(to: url)
        return pending.count
    }

    /// 保存 providers.json；密钥只进本地 secrets.json。
    ///
    /// 内存里若还有明文 key（例如调用方没有先跑 `migratePlaintextKeys`），这里会兜底迁移。
    public func save(to url: URL) throws {
        for provider in providers where !provider.apiKey.isEmpty {
            try secrets.setSecret(provider.apiKey, for: provider.id)
        }
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
        let existingIndex = providers.firstIndex { $0.id == normalized.id }

        // 空 key 表示“保留已有密钥”，不写入空值；旧密钥仍留在 secrets.json 里，
        // 下次 hydrate 时再读取。这样也避免这里做一次跨两次加锁的读-改-写。
        if !normalized.apiKey.isEmpty {
            try secrets.setSecret(normalized.apiKey, for: normalized.id)
        }

        if let existingIndex {
            providers[existingIndex] = normalized
        } else {
            providers.append(normalized)
        }

        if activate || activeID == nil {
            activeID = normalized.id
        }
        return normalized
    }

    /// 清除某个提供商已保存的密钥；提供商本身保留。
    ///
    /// `upsert` 把空 key 当作“保留已有密钥”，所以「清空密钥」必须走这个显式入口。
    public func clearSecret(for id: String) throws {
        try secrets.deleteSecret(for: id)
        if let index = providers.firstIndex(where: { $0.id == id }) {
            providers[index].apiKey = ""
        }
    }

    public func delete(id: String) throws {
        guard providers.contains(where: { $0.id == id }) else { return }
        // 先删密钥：失败时保留提供商，避免留下无法再被清理的孤儿密钥。
        try secrets.deleteSecret(for: id)
        providers.removeAll { $0.id == id }
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
