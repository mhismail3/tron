import Foundation
import Testing
@testable import TronMobile

@Suite("Codex JSON-RPC transport")
@MainActor
struct CodexJSONRPCTransportTests {
    private func endpoint() -> CodexAppEndpoint {
        CodexAppEndpoint(url: URL(string: "ws://127.0.0.1:4500")!, requiresToken: false)
    }

    @Test("connect sends bearer auth and routes a response to the matching request")
    func connectAndRouteResponse() async throws {
        let socket = FakeCodexWebSocketTask()
        var upgradeRequest: URLRequest?
        let transport = CodexJSONRPCTransport(
            endpoint: endpoint(),
            bearerTokenProvider: { "codex-token" },
            requestTimeout: 1,
            webSocketFactory: { request in
                upgradeRequest = request
                return socket
            }
        )

        try await transport.connect()
        let requestTask = Task {
            try await transport.send(method: "thread/list", params: nil, timeout: 1)
        }
        let request = try await socket.waitForSentRequest()

        socket.enqueueJSON(#"{ "id": \#(request.id), "result": { "ok": true } }"#)
        let result = try await requestTask.value

        #expect(upgradeRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer codex-token")
        #expect(socket.resumeCount == 1)
        #expect(result["ok"]?.boolValue == true)
    }

    @Test("concurrent requests are resolved by response id")
    func concurrentRequestRouting() async throws {
        let socket = FakeCodexWebSocketTask()
        let transport = CodexJSONRPCTransport(
            endpoint: endpoint(),
            requestTimeout: 1,
            webSocketFactory: { _ in socket }
        )
        try await transport.connect()

        let firstTask = Task { try await transport.send(method: "alpha", params: nil, timeout: 1) }
        let secondTask = Task { try await transport.send(method: "beta", params: nil, timeout: 1) }
        let firstRequest = try await socket.waitForSentRequest(at: 0)
        let secondRequest = try await socket.waitForSentRequest(at: 1)

        socket.enqueueJSON(#"{ "id": \#(secondRequest.id), "result": { "value": "second" } }"#)
        socket.enqueueJSON(#"{ "id": \#(firstRequest.id), "result": { "value": "first" } }"#)

        #expect(try await firstTask.value["value"]?.stringValue == "first")
        #expect(try await secondTask.value["value"]?.stringValue == "second")
    }

    @Test("request timeout clears the pending request")
    func requestTimeout() async throws {
        let socket = FakeCodexWebSocketTask()
        let transport = CodexJSONRPCTransport(
            endpoint: endpoint(),
            requestTimeout: 0.05,
            webSocketFactory: { _ in socket }
        )
        try await transport.connect()

        do {
            _ = try await transport.send(method: "slow", params: nil, timeout: 0.05)
            Issue.record("expected timeout")
        } catch let error as CodexTransportError {
            #expect(error == .timeout)
        }
    }

    @Test("server request dispatches and respond writes the original id")
    func serverRequestDispatchAndResponse() async throws {
        let socket = FakeCodexWebSocketTask()
        let transport = CodexJSONRPCTransport(
            endpoint: endpoint(),
            requestTimeout: 1,
            webSocketFactory: { _ in socket }
        )
        var received: CodexJSONRPCServerRequest?
        transport.onServerRequest = { request in
            received = request
        }

        try await transport.connect()
        socket.enqueueJSON(#"{ "id": "approval-1", "method": "item/commandExecution/requestApproval", "params": { "threadId": "thr", "turnId": "turn", "itemId": "cmd" } }"#)
        try await waitUntil { received != nil }
        try await transport.respond(CodexJSONRPCServerResponse(id: .string("approval-1"), result: ["decision": AnyCodable("accept")]))

        #expect(received?.id == .string("approval-1"))
        let response = try await socket.waitForSentResponse()
        #expect(response["id"] as? String == "approval-1")
        #expect((response["result"] as? [String: Any])?["decision"] as? String == "accept")
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition was not met")
    }
}

private struct SentCodexRequest {
    let id: Int
    let method: String
}

private final class FakeCodexWebSocketTask: CodexWebSocketTasking, @unchecked Sendable {
    private let lock = NSLock()
    private var sentMessages: [URLSessionWebSocketTask.Message] = []
    private var incomingMessages: [URLSessionWebSocketTask.Message] = []
    private var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?

    var maximumMessageSize: Int = 0
    private(set) var resumeCount = 0

    func resume() {
        lock.lock()
        resumeCount += 1
        lock.unlock()
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        appendSent(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            if let message = receiveOrSuspend(continuation) {
                continuation.resume(returning: message)
            }
        }
    }

    func sendPing() async throws {}

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.lock()
        let continuation = receiveContinuation
        receiveContinuation = nil
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    func enqueueJSON(_ json: String) {
        lock.lock()
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            lock.unlock()
            continuation.resume(returning: .string(json))
        } else {
            incomingMessages.append(.string(json))
            lock.unlock()
        }
    }

    func waitForSentRequest(at index: Int = 0) async throws -> SentCodexRequest {
        let object = try await waitForSentJSON(at: index)
        return SentCodexRequest(
            id: try #require(object["id"] as? Int),
            method: try #require(object["method"] as? String)
        )
    }

    func waitForSentResponse(at index: Int = 0) async throws -> [String: Any] {
        try await waitForSentJSON(at: index)
    }

    private func waitForSentJSON(at index: Int) async throws -> [String: Any] {
        for _ in 0..<50 {
            if let text = sentText(at: index),
               let data = text.data(using: .utf8),
               let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(nil as [String: Any]?)
    }

    private func appendSent(_ message: URLSessionWebSocketTask.Message) {
        lock.lock()
        sentMessages.append(message)
        lock.unlock()
    }

    private func receiveOrSuspend(_ continuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>) -> URLSessionWebSocketTask.Message? {
        lock.lock()
        defer { lock.unlock() }
        if !incomingMessages.isEmpty {
            return incomingMessages.removeFirst()
        }
        receiveContinuation = continuation
        return nil
    }

    private func sentText(at index: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard sentMessages.indices.contains(index) else { return nil }
        switch sentMessages[index] {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }
}
