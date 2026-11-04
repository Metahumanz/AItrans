// OllamaClientTests.swift - 请求构造与响应解析（不依赖网络）

import XCTest
@testable import AITransCore

final class OllamaClientTests: XCTestCase {
    func testRequestTargetsNativeChatEndpoint() throws {
        let client = OllamaClient(baseURL: "http://127.0.0.1:11434/", model: "qwen2.5")
        let request = try client.makeRequest(messages: [.system("s"), .user("u")])

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(request.httpMethod, "POST")
    }

    func testPayloadUsesNonStreamingNativeShape() throws {
        let client = OllamaClient(model: "qwen2.5")
        let data = try client.makePayload(messages: [.user("你好")])
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["model"] as? String, "qwen2.5")
        XCTAssertEqual(root["stream"] as? Bool, false)
        let messages = try XCTUnwrap(root["messages"] as? [[String: String]])
        XCTAssertEqual(messages.first?["content"], "你好")
        XCTAssertEqual(messages.first?["role"], "user")
    }

    func testParsesMessageContent() throws {
        let json = #"{"message":{"role":"assistant","content":"  译文  "},"done":true}"#
        let text = try OllamaClient.content(from: Data(json.utf8))
        XCTAssertEqual(text, "译文")
    }

    func testRejectsEmptyContent() {
        let json = #"{"message":{"role":"assistant","content":"   "},"done":true}"#
        XCTAssertThrowsError(try OllamaClient.content(from: Data(json.utf8)))
    }

    func testRejectsUnexpectedShape() {
        let json = #"{"choices":[]}"#
        XCTAssertThrowsError(try OllamaClient.content(from: Data(json.utf8)))
    }
}
