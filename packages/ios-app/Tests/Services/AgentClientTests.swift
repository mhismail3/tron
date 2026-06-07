import Testing
import Foundation
@testable import TronMobile

/// Tests for AgentClient protocol and implementation
@MainActor
@Suite("AgentClient Tests")
struct AgentClientTests {

    // MARK: - Mock Agent Client

    final class MockAgentClient: AgentClientProtocol {
        var sendPromptCallCount = 0
        var lastPrompt: String?
        var lastImages: [ImageAttachment]?
        var lastAttachments: [FileAttachment]?
        var lastReasoningLevel: String?
        var sendPromptShouldThrow = false

        var abortCallCount = 0
        var abortShouldThrow = false

        var getStateCallCount = 0
        var getStateSessionId: String?
        var getStateIsRunning = false
        var getStateCurrentTurn = 0
        var getStateMessageCount = 0
        var getStateModel = "claude-opus-4-20250514"
        var getStateShouldThrow = false

        func sendPrompt(
            _ prompt: String,
            images: [ImageAttachment]?,
            attachments: [FileAttachment]?,
            reasoningLevel: String?,
            idempotencyKey: EngineIdempotencyKey
        ) async throws {
            sendPromptCallCount += 1
            lastPrompt = prompt
            lastImages = images
            lastAttachments = attachments
            lastReasoningLevel = reasoningLevel
            if sendPromptShouldThrow { throw TestError.mockError }
        }

        func abort(idempotencyKey: EngineIdempotencyKey) async throws {
            abortCallCount += 1
            if abortShouldThrow { throw TestError.mockError }
        }

        enum TestError: Error {
            case mockError
        }
    }

    private func makeConnectedTransport(sessionId: String = "session-123") -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.connectionState = .connected
        transport.currentSessionId = sessionId
        return transport
    }

    nonisolated private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Send Prompt Tests

    @Test("Send prompt with minimal parameters")
    func testSendPrompt_minimal() async throws {
        let mock = MockAgentClient()

        try await mock.sendPrompt("Hello", idempotencyKey: .userAction("agent.prompt.test"))

        #expect(mock.sendPromptCallCount == 1)
        #expect(mock.lastPrompt == "Hello")
        #expect(mock.lastImages == nil)
        #expect(mock.lastAttachments == nil)
        #expect(mock.lastReasoningLevel == nil)
    }

    @Test("Send prompt with reasoning level")
    func testSendPrompt_withReasoningLevel() async throws {
        let mock = MockAgentClient()

        try await mock.sendPrompt(
            "Hello",
            images: nil,
            attachments: nil,
            reasoningLevel: "medium",
            idempotencyKey: .userAction("agent.prompt.test")
        )

        #expect(mock.lastReasoningLevel == "medium")
    }

    @Test("Send prompt throws on error")
    func testSendPrompt_throwsOnError() async throws {
        let mock = MockAgentClient()
        mock.sendPromptShouldThrow = true

        await #expect(throws: MockAgentClient.TestError.self) {
            try await mock.sendPrompt("Hello", idempotencyKey: .userAction("agent.prompt.test"))
        }
    }

    @Test("Real agent session writes carry session invocation context")
    func realAgentSessionWritesCarryContext() async throws {
        let sessionId = "session-123"
        let transport = makeConnectedTransport(sessionId: sessionId)
        let client = AgentClient(transport: transport)
        var seenFunctions: [String] = []

        transport.writeHandler = { functionId, payload, _, options in
            let rawFunctionId = functionId.rawValue
            seenFunctions.append(rawFunctionId)
            #expect(options.context?.sessionId == sessionId)

            switch rawFunctionId {
            case "agent::prompt":
                #expect((payload as? AgentPromptParams)?.sessionId == sessionId)
                return AgentPromptResult(acknowledged: true)
            case "agent::queue_prompt":
                #expect((payload as? QueuePromptParams)?.sessionId == sessionId)
                return PendingQueueItem(queueId: "queue-1", text: "queued", position: 1, timestamp: "2026-05-10T00:00:00Z")
            case "agent::dequeue_prompt":
                #expect((payload as? DequeuePromptParams)?.sessionId == sessionId)
                return DequeueResult(ok: true)
            case "agent::clear_queue":
                #expect((payload as? ClearQueueParams)?.sessionId == sessionId)
                return ClearQueueResult(cleared: 1)
            case "agent::abort":
                #expect((payload as? AgentAbortParams)?.sessionId == sessionId)
                return EmptyParams()
            case "agent::abort_invocation":
                #expect((payload as? AgentAbortInvocationParams)?.sessionId == sessionId)
                return AgentAbortInvocationResult(aborted: true)
            default:
                throw EngineConnectionError.invalidResponse
            }
        }
        try await client.sendPrompt("Hello", idempotencyKey: .userAction("agent.prompt.test"))
        _ = try await client.queuePrompt("queued", idempotencyKey: .userAction("agent.queuePrompt.test"))
        try await client.dequeuePrompt("queue-1", idempotencyKey: .userAction("agent.dequeuePrompt.test"))
        try await client.clearQueue(idempotencyKey: .userAction("agent.clearQueue.test"))
        try await client.abort(idempotencyKey: .userAction("agent.abort.test"))
        _ = try await client.abortCapabilityInvocation(invocationId: "capability-1", idempotencyKey: .userAction("agent.abortCapabilityInvocation.test"))
        #expect(transport.ensureSessionEventSubscriptionCallCount >= 1)
        #expect(transport.operationOrder.prefix(2) == [
            "subscribe:\(sessionId)",
            "write:agent::prompt"
        ])
        #expect(seenFunctions == [
            "agent::prompt",
            "agent::queue_prompt",
            "agent::dequeue_prompt",
            "agent::clear_queue",
            "agent::abort",
            "agent::abort_invocation"
        ])
    }

    @Test("Prompt does not invoke agent when live session stream cannot subscribe")
    func promptRequiresLiveSessionSubscription() async {
        let transport = makeConnectedTransport()
        transport.ensureSessionEventSubscriptionShouldThrow = true
        let client = AgentClient(transport: transport)
        transport.writeHandler = { _, _, _, _ in
            Issue.record("agent::prompt should not be invoked without a live session stream")
            return AgentPromptResult(acknowledged: true)
        }

        await #expect(throws: EngineConnectionError.self) {
            try await client.sendPrompt("Hello", idempotencyKey: .userAction("agent.prompt.test"))
        }
        #expect(transport.lastWriteFunctionId == nil)
    }

    // MARK: - Abort Tests

    @Test("Abort calls correctly")
    func testAbort_calls() async throws {
        let mock = MockAgentClient()

        try await mock.abort(idempotencyKey: .userAction("agent.abort.test"))

        #expect(mock.abortCallCount == 1)
    }

    @Test("Abort throws on error")
    func testAbort_throwsOnError() async throws {
        let mock = MockAgentClient()
        mock.abortShouldThrow = true

        await #expect(throws: MockAgentClient.TestError.self) {
            try await mock.abort(idempotencyKey: .userAction("agent.abort.test"))
        }
    }

}
