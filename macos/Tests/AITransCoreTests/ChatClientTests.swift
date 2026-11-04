// ChatClientTests.swift - 用 URLProtocol 桩验证重试与错误分类

import XCTest
@testable import AITransCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var requestCount = 0

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: AITransError("未设置桩"))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class ChatClientTests: XCTestCase {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient(retries: Int) -> ChatClient {
        ChatClient(
            baseURL: "https://example.invalid",
            apiKey: "sk-test",
            model: "test-model",
            policy: RetryPolicy(retries: retries),
            session: makeSession(),
            sleep: { _ in }
        )
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.requestCount = 0
        StubURLProtocol.handler = nil
    }

    func testRetriesOn429ThenSucceeds() async throws {
        StubURLProtocol.handler = { _ in
            if StubURLProtocol.requestCount == 1 {
                return (429, Data(#"{"error":{"message":"rate limited"}}"#.utf8))
            }
            return (200, Data(#"{"choices":[{"message":{"content":"你好"}}]}"#.utf8))
        }

        let text = try await makeClient(retries: 2).complete(messages: [.user("hi")])
        XCTAssertEqual(text, "你好")
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testDoesNotRetryOn400() async {
        StubURLProtocol.handler = { _ in
            (400, Data(#"{"error":{"message":"bad request"}}"#.utf8))
        }

        do {
            _ = try await makeClient(retries: 3).complete(messages: [.user("hi")])
            XCTFail("应当抛错")
        } catch let error as ChatHTTPError {
            XCTAssertEqual(error.status, 400)
            XCTAssertTrue(error.message.contains("bad request"))
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testGivesUpAfterRetryBudget() async {
        StubURLProtocol.handler = { _ in
            (503, Data("{}".utf8))
        }

        do {
            _ = try await makeClient(retries: 1).complete(messages: [.user("hi")])
            XCTFail("应当抛错")
        } catch let error as ChatHTTPError {
            XCTAssertEqual(error.status, 503)
        } catch {
            XCTFail("错误类型不对：\(error)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testThinkingDisabledForDeepSeekHost() throws {
        let client = ChatClient(baseURL: "https://api.deepseek.com", apiKey: "k", model: "m")
        let payload = try client.makePayload(messages: [.user("hi")])
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertNotNil(root["thinking"], "DeepSeek 域名应关闭思考模式")

        let other = ChatClient(baseURL: "https://api.openai.com/v1", apiKey: "k", model: "m")
        let otherPayload = try other.makePayload(messages: [.user("hi")])
        let otherRoot = try XCTUnwrap(try JSONSerialization.jsonObject(with: otherPayload) as? [String: Any])
        XCTAssertNil(otherRoot["thinking"], "其他服务不应收到 thinking 字段")
    }

    func testErrorMessageExtraction() {
        let body = Data(#"{"error":{"message":"invalid key"}}"#.utf8)
        XCTAssertEqual(ChatClient.errorMessage(from: body, status: 401), "HTTP 401: invalid key")
    }
}
