// Models.swift - 客户端共享的基础类型

import Foundation

/// 提供商预设，对应 `spec/providers.presets.json`。
public struct ProviderPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let baseURL: String
    public let model: String
    public let requiresKey: Bool

    public init(id: String, name: String, baseURL: String, model: String, requiresKey: Bool) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.requiresKey = requiresKey
    }
}

/// 用户保存的提供商配置。
public struct Provider: Sendable, Equatable, Identifiable, Codable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var requiresKey: Bool

    public init(
        id: String,
        name: String,
        baseURL: String,
        model: String,
        apiKey: String = "",
        requiresKey: Bool = true
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.requiresKey = requiresKey
    }

    enum CodingKeys: String, CodingKey {
        case id, name, model
        case baseURL = "base_url"
        case apiKey = "api_key"
        case requiresKey = "requires_key"
    }
}

/// 目标语言。
public enum Language: String, Codable, CaseIterable, Sendable {
    case zh, en, ja, ko

    /// 写进提示词的语言名，例如「中文」。
    public var displayName: String {
        Spec.languages[rawValue] ?? "中文"
    }
}

/// 翻译引擎。
public enum Engine: String, Codable, Sendable, CaseIterable {
    case api
    case ollama
}

/// 输出位置。
public enum OutputMode: String, Codable, Sendable, CaseIterable {
    case source
    case output
    case custom
}

/// 界面设置，持久化到 `settings.json`。
public struct AppSettings: Sendable, Equatable, Codable {
    public var version: Int = 1
    public var backend: Engine = .api
    public var apiModel: String = ""
    public var ollamaModel: String = "qwen2.5"
    public var lang: Language = .zh
    public var translate: Bool = true
    public var polish: Bool = true
    public var outputMode: OutputMode = .source
    public var suffix: String = "_translated"
    public var customDir: String = ""
    public var force: Bool = false
    public var apiWorkers: Int = 20
    public var apiRetries: Int = 2
    public var ollamaWorkers: Int = 2
    public var ollamaRetries: Int = 1
    public var autoCheckUpdates: Bool = true

    public init() {}

    /// 手写解码：老版本 settings.json 里没有 `auto_check_updates` 等新键，
    /// 合成实现会直接抛错并丢掉整份设置，这里逐项 `decodeIfPresent` 回退到默认值。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        backend = try container.decodeIfPresent(Engine.self, forKey: .backend) ?? .api
        apiModel = try container.decodeIfPresent(String.self, forKey: .apiModel) ?? ""
        ollamaModel = try container.decodeIfPresent(String.self, forKey: .ollamaModel) ?? "qwen2.5"
        lang = try container.decodeIfPresent(Language.self, forKey: .lang) ?? .zh
        translate = try container.decodeIfPresent(Bool.self, forKey: .translate) ?? true
        polish = try container.decodeIfPresent(Bool.self, forKey: .polish) ?? true
        outputMode = try container.decodeIfPresent(OutputMode.self, forKey: .outputMode) ?? .source
        suffix = try container.decodeIfPresent(String.self, forKey: .suffix) ?? "_translated"
        customDir = try container.decodeIfPresent(String.self, forKey: .customDir) ?? ""
        force = try container.decodeIfPresent(Bool.self, forKey: .force) ?? false
        apiWorkers = try container.decodeIfPresent(Int.self, forKey: .apiWorkers) ?? 20
        apiRetries = try container.decodeIfPresent(Int.self, forKey: .apiRetries) ?? 2
        ollamaWorkers = try container.decodeIfPresent(Int.self, forKey: .ollamaWorkers) ?? 2
        ollamaRetries = try container.decodeIfPresent(Int.self, forKey: .ollamaRetries) ?? 1
        autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
    }

    enum CodingKeys: String, CodingKey {
        case version, backend, lang, translate, polish, suffix, force
        case autoCheckUpdates = "auto_check_updates"
        case apiModel = "api_model"
        case ollamaModel = "ollama_model"
        case outputMode = "output_mode"
        case customDir = "custom_dir"
        case apiWorkers = "api_workers"
        case apiRetries = "api_retries"
        case ollamaWorkers = "ollama_workers"
        case ollamaRetries = "ollama_retries"
    }
}

/// 单文件处理结果。
public struct FileResult: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable {
        case success
        case skipped
        case failed
    }

    public var id: String { name }
    public var name: String
    public var relativeName: String?
    public var status: Status
    public var outputPath: String?
    public var error: String?
    public var translatedCount: Int
    public var errorCount: Int

    public init(
        name: String,
        relativeName: String? = nil,
        status: Status,
        outputPath: String? = nil,
        error: String? = nil,
        translatedCount: Int = 0,
        errorCount: Int = 0
    ) {
        self.name = name
        self.relativeName = relativeName
        self.status = status
        self.outputPath = outputPath
        self.error = error
        self.translatedCount = translatedCount
        self.errorCount = errorCount
    }
}

/// 面向用户的错误，消息可以直接展示。
public struct AITransError: Error, Sendable, LocalizedError {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}
