// OllamaClient.swift - 本地 Ollama 引擎
//
// 与 v1 的 trans.py / transopt.py 对齐：走 Ollama 原生 /api/chat 接口，
// 不使用 OpenAI 兼容层，避免多一层转换。

import Foundation

public struct OllamaClient: ChatCompleting {
    public static let defaultBaseURL = "http://localhost:11434"

    public let baseURL: String
    public let model: String
    public let timeout: TimeInterval
    public let policy: RetryPolicy

    private let session: URLSession
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        baseURL: String = OllamaClient.defaultBaseURL,
        model: String,
        timeout: TimeInterval = TimeInterval(Spec.defaultTimeoutSeconds),
        policy: RetryPolicy = RetryPolicy(),
        session: URLSession = .shared,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.policy = policy
        self.session = session
        self.sleep = sleep
    }

    public func makePayload(messages: [ChatMessage]) throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": false,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    public func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/api/chat") else {
            throw AITransError("Ollama 地址无效：\(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try makePayload(messages: messages)
        return request
    }

    public func complete(messages: [ChatMessage]) async throws -> String {
        let request = try makeRequest(messages: messages)

        for attempt in 0...policy.retries {
            if Task.isCancelled { throw CancellationError() }
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else {
                    let detail = String(decoding: data.prefix(200), as: UTF8.self)
                    switch policy.decision(forStatus: status, attempt: attempt) {
                    case .retry(let delay):
                        await sleep(delay)
                        continue
                    case .fail:
                        throw AITransError("Ollama 返回 HTTP \(status)\(detail.isEmpty ? "" : "：\(detail)")")
                    }
                }
                return try Self.content(from: data)
            } catch let error as AITransError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch policy.decision(forTransportErrorAt: attempt) {
                case .retry(let delay):
                    await sleep(delay)
                case .fail:
                    throw AITransError("无法连接 Ollama，请确认服务已启动（ollama serve）。")
                }
            }
        }
        throw AITransError("Ollama 请求失败：重试次数已用完")
    }

    public static func content(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = root["message"] as? [String: Any],
            let raw = message["content"] as? String
        else {
            throw AITransError("Ollama 返回格式异常")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AITransError("Ollama 返回了空内容")
        }
        return text
    }

    /// 已安装的模型名列表。
    public static func models(baseURL: String = OllamaClient.defaultBaseURL, session: URLSession = .shared) async throws -> [String] {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/api/tags") else {
            throw AITransError("Ollama 地址无效：\(baseURL)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AITransError("Ollama 未响应")
        }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else {
            throw AITransError("Ollama 返回格式异常")
        }
        return models.compactMap { $0["name"] as? String }
    }
}

/// 本地 Ollama 服务的启动与检查。
public enum OllamaService {
    /// 服务是否可达。
    public static func isRunning(baseURL: String = OllamaClient.defaultBaseURL, session: URLSession = .shared) async -> Bool {
        (try? await OllamaClient.models(baseURL: baseURL, session: session)) != nil
    }

    /// 找不到可执行文件时返回 nil。
    public static func findExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in searchPath.split(separator: ":") {
            let candidate = "\(directory)/ollama"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// 确保服务在跑；必要时拉起 `ollama serve`。
    public static func ensureRunning(
        baseURL: String = OllamaClient.defaultBaseURL,
        session: URLSession = .shared
    ) async throws {
        if await isRunning(baseURL: baseURL, session: session) { return }

        guard let executable = findExecutable() else {
            throw AITransError("没有找到 Ollama。请先安装并打开 Ollama，或切换到 API 提供商。")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AITransError("无法启动 Ollama：\(error.localizedDescription)")
        }

        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if await isRunning(baseURL: baseURL, session: session) { return }
        }
        throw AITransError("Ollama 启动超时，请手动运行 `ollama serve` 后重试。")
    }

    /// 检查模型是否已安装（允许 `name` 与 `name:latest` 互相匹配）。
    public static func ensureModel(
        _ name: String,
        baseURL: String = OllamaClient.defaultBaseURL,
        session: URLSession = .shared
    ) async throws {
        let installed = (try? await OllamaClient.models(baseURL: baseURL, session: session)) ?? []
        let wanted = name.split(separator: ":").first.map(String.init) ?? name
        let found = installed.contains { candidate in
            let base = candidate.split(separator: ":").first.map(String.init) ?? candidate
            return base == wanted
        }
        guard found else {
            throw AITransError("尚未安装模型 \(name)。请在终端运行 ollama pull \(name)，完成后重试。")
        }
    }
}
