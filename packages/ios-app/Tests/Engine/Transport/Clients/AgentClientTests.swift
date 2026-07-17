import Testing
import Foundation
@testable import TronMobile

/// Tests the concrete agent transport adapter at its real `EngineTransport` seam.
@MainActor
@Suite("AgentClient Tests")
struct AgentClientTests {
    private func makeConnectedTransport(sessionId: String = "session-123") -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.connectionState = .connected
        transport.currentSessionId = sessionId
        return transport
    }

    @Test("Real agent writes carry context and unified attachments")
    func realAgentSessionWritesCarryContextAndAttachments() async throws {
        let sessionId = "session-123"
        let transport = makeConnectedTransport(sessionId: sessionId)
        let client = AgentClient(transport: transport)
        let attachment = FileAttachment(
            data: Data("attachment fixture".utf8),
            mimeType: "application/pdf",
            fileName: "fixture.pdf"
        )
        var seenFunctions: [String] = []

        transport.writeHandler = { functionId, payload, _, options in
            let rawFunctionId = functionId.rawValue
            seenFunctions.append(rawFunctionId)
            #expect(options.context?.sessionId == sessionId)

            switch rawFunctionId {
            case "agent::prompt":
                let params = try #require(payload as? AgentPromptParams)
                #expect(params.sessionId == sessionId)
                #expect(params.prompt == "Hello")
                #expect(params.reasoningLevel == "medium")
                let forwarded = try #require(params.attachments?.first)
                #expect(forwarded.mimeType == "application/pdf")
                #expect(forwarded.fileName == "fixture.pdf")
                return AgentPromptResult(acknowledged: true)
            case "agent::abort":
                #expect((payload as? AgentAbortParams)?.sessionId == sessionId)
                return AgentAbortResult(aborted: true)
            case "agent::abort_invocation":
                #expect((payload as? AgentAbortInvocationParams)?.sessionId == sessionId)
                return AgentAbortInvocationResult(aborted: true)
            default:
                throw EngineConnectionError.invalidResponse
            }
        }

        try await client.sendPrompt(
            "Hello",
            attachments: [attachment],
            reasoningLevel: "medium",
            idempotencyKey: .userAction("agent.prompt.test")
        )
        let aborted = try await client.abort(idempotencyKey: .userAction("agent.abort.test"))
        _ = try await client.abortCapabilityInvocation(
            invocationId: "capability-1",
            idempotencyKey: .userAction("agent.abortCapabilityInvocation.test")
        )

        #expect(transport.ensureSessionEventSubscriptionCallCount >= 1)
        #expect(aborted)
        #expect(transport.operationOrder.prefix(2) == [
            "subscribe:\(sessionId)",
            "write:agent::prompt",
        ])
        #expect(seenFunctions == [
            "agent::prompt",
            "agent::abort",
            "agent::abort_invocation",
        ])
    }

    @Test("Abort preserves a negative server match result")
    func abortPreservesNegativeServerResult() async throws {
        let transport = makeConnectedTransport()
        let client = AgentClient(transport: transport)
        transport.writeHandler = { functionId, _, _, _ in
            #expect(functionId.rawValue == "agent::abort")
            return AgentAbortResult(aborted: false)
        }

        let aborted = try await client.abort(
            idempotencyKey: .userAction("agent.abort.negative-test")
        )

        #expect(!aborted)
    }

    @Test("Abort without a selected live session reports no match")
    func abortWithoutLiveSessionReportsNoMatch() async throws {
        let transport = MockEngineTransport()
        let client = AgentClient(transport: transport)

        let aborted = try await client.abort(
            idempotencyKey: .userAction("agent.abort.no-session-test")
        )

        #expect(!aborted)
        #expect(transport.lastWriteFunctionId == nil)
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

    @Test("Prompt requires an affirmative server acknowledgement")
    func promptRejectsNegativeAcknowledgement() async {
        let transport = makeConnectedTransport()
        let client = AgentClient(transport: transport)
        transport.writeHandler = { functionId, _, _, _ in
            #expect(functionId.rawValue == "agent::prompt")
            return AgentPromptResult(acknowledged: false)
        }

        do {
            try await client.sendPrompt(
                "Hello",
                idempotencyKey: .userAction("agent.prompt.negative-ack-test")
            )
            Issue.record("a negative acknowledgement must not commit prompt submission")
        } catch let error as EngineConnectionError {
            #expect(error == .invalidResponse)
        } catch {
            Issue.record("unexpected prompt error: \(error)")
        }
    }
}
