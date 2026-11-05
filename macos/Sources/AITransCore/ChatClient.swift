// ChatClient.swift - OpenAI 兼容接口调用
//
// 与 legacy 的 request_chat_completion 对齐：
// - DeepSeek 域名默认关闭思考模式；
// - 传输错误、429、5xx 按指数退避重试；
// - 空内容视为错误。

import Foundation

public struct ChatMessage: Codable, Sendable, Equatable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public static func system(_ content: String) -> ChatMessage { .init(role: "system", content: content) }
    public static func user(_ content: String) -> ChatMessage { .init(role: "user", content: content) }
}

/// 供 `Translator` 依赖的抽象，测试时替换为假实现。
public protocol ChatCompleting: Sendable {
    func complete(messages: [ChatMessage]) async throws -> String
}

public struct ChatHTTPError: Error, Sendable, Equatable {
    public let status: Int
    public let message: String

    public init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

public struct ChatClient: ChatCompleting {
    public let baseURL: String
    public let apiKey: String
    public let model: String
    public let timeout: TimeInterval
    public let policy: RetryPolicy

    private let session: URLSession
    private let sleep: @Sendable (TimeInterval) async -> Void

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        timeout: TimeInterval = TimeInterval(Spec.defaultTimeoutSeconds),
        policy: RetryPolicy = RetryPolicy(),
        session: URLSession = .shared,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.policy = policy
        self.session = session
        self.sleep = sleep
    }

    /// 是否发送 `thinking: disabled`。
    public static func shouldDisableThinking(baseURL: String) -> Bool {
        let override = ProcessInfo.processInfo.environment[Spec.thinkingOverrideEnvVar]?
            .trimmingCharacters(in: .whitespaces)
            .lowercased() ?? ""
        if ["off", "0", "false", "disabled"].contains(override) { return false }
        if ["on", "1", "true", "enabled"].contains(override) { return true }
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host.contains(Spec.thinkingHostKeyword)
    }

    /// 构造请求体（拆出来便于单测，不依赖网络）。
    public func makePayload(messages: [ChatMessage]) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        if Self.shouldDisableThinking(baseURL: baseURL) {
            body["thinking"] = ["type": "disabled"]
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    public func makeRequest(messages: [ChatMessage]) throws -> URLRequest {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: "\(trimmed)/chat/completions") else {
            throw AITransError("接口地址无效：\(baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
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
                    let detail = Self.errorMessage(from: data, status: status)
                    switch policy.decision(forStatus: status, attempt: attempt) {
                    case .retry(let delay):
                        await sleep(delay)
                        continue
                    case .fail:
                        throw ChatHTTPError(status: status, message: detail)
                    }
                }
                return try Self.content(from: data)
            } catch let error as ChatHTTPError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                switch policy.decision(forTransportErrorAt: attempt) {
                case .retry(let delay):
                    await sleep(delay)
                case .fail:
                    throw AITransError(Self.transportMessage(error))
                }
            }
        }
        throw AITransError("请求失败：重试次数已用完")
    }

    // MARK: - 响应解析（纯函数，便于测试）

    public static func content(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any],
            let raw = message["content"] as? String
        else {
            throw AITransError("API 返回格式异常")
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw AITransError("API 返回了空内容")
        }
        return text
    }

    public static func errorMessage(from data: Data, status: Int) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return "HTTP \(status): \(message)"
        }
        let body = String(decoding: data.prefix(200), as: UTF8.self)
        return body.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(body)"
    }

    /// 是否是 macOS ATS 拦截明文 HTTP 的错误。
    public static func isAppTransportSecurityError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain
            && ns.code == NSURLErrorAppTransportSecurityRequiresSecureConnection
    }

    static func transportMessage(_ error: Error) -> String {
        let ns = error as NSError
        if isAppTransportSecurityError(error) {
            return "网络错误：macOS 不允许明文 HTTP，请把接口地址改为 https://（本机或局域网地址除外）"
        }
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "网络错误：请求超时"
            case NSURLErrorNotConnectedToInternet: return "网络错误：没有网络连接"
            case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
                return "网络错误：无法连接服务器"
            default: return "网络错误：\(ns.localizedDescription)"
            }
        }
        return "网络错误：\(error.localizedDescription)"
    }
}
