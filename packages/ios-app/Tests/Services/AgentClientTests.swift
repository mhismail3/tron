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

        var activateSkillCallCount = 0
        var lastActivatedSkill: String?
        var deactivateSkillCallCount = 0
        var lastDeactivatedSkill: String?
        var activeSkillsCallCount = 0
        var workSnapshotCallCount = 0

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

        func activateSkill(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws -> SkillActivateResult {
            activateSkillCallCount += 1
            lastActivatedSkill = skillName
            let json = """
            {"success": true, "skill": {"name": "\(skillName)", "source": "global", "service": "tron"}}
            """
            return try! JSONDecoder().decode(SkillActivateResult.self, from: json.data(using: .utf8)!)
        }

        func deactivateSkill(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws -> SkillDeactivateResult {
            deactivateSkillCallCount += 1
            lastDeactivatedSkill = skillName
            let json = """
            {"success": true, "deactivatedSkill": "\(skillName)"}
            """
            return try! JSONDecoder().decode(SkillDeactivateResult.self, from: json.data(using: .utf8)!)
        }

        func activeSkills() async throws -> SkillActiveResult {
            activeSkillsCallCount += 1
            let json = """
            {"skills": []}
            """
            return try! JSONDecoder().decode(SkillActiveResult.self, from: json.data(using: .utf8)!)
        }

        func workSnapshot(sessionId: String?, workspaceId: String?, limit: Int) async throws -> WorkSnapshotDTO {
            workSnapshotCallCount += 1
            let json = """
            {
              "autonomy": {
                "mode": "independent",
                "approvalPromptMode": "disabled",
                "interactiveApprovalPrompts": false,
                "statusLabel": "Runs independently",
                "summary": "Approval-required autonomous work is audited and auto-decided unless a guardrail blocks it."
              },
              "activeWork": [],
              "workers": [],
              "recentMilestones": [],
              "guardrails": [],
              "auditRefs": [{"kind": "catalog", "catalogRevision": 9}],
              "scope": {"sessionId": null, "workspaceId": null}
            }
            """
            return try! JSONDecoder().decode(WorkSnapshotDTO.self, from: Data(json.utf8))
        }

        enum TestError: Error {
            case mockError
        }
    }

    // MARK: - Helper to create test Skill

    static func makeTestSkill(name: String = "test-skill") -> Skill {
        Skill(
            name: name,
            displayName: name,
            description: "A test skill",
            source: .global,
            tags: nil
        )
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
            case "skills::activate":
                #expect((payload as? SkillActivateParams)?.sessionId == sessionId)
                return try Self.decode(SkillActivateResult.self, #"{"success":true,"skill":{"name":"browser","source":"global","service":"tron"}}"#)
            case "skills::deactivate":
                #expect((payload as? SkillDeactivateParams)?.sessionId == sessionId)
                return try Self.decode(SkillDeactivateResult.self, #"{"success":true,"deactivatedSkill":"browser"}"#)
            case "agent::queue_prompt":
                #expect((payload as? QueuePromptParams)?.sessionId == sessionId)
                return PendingQueueItem(queueId: "queue-1", text: "queued", position: 1, timestamp: "2026-05-10T00:00:00Z")
            case "agent::dequeue_prompt":
                #expect((payload as? DequeuePromptParams)?.sessionId == sessionId)
                return DequeueResult(ok: true)
            case "agent::clear_queue":
                #expect((payload as? ClearQueueParams)?.sessionId == sessionId)
                return ClearQueueResult(cleared: 1)
            case "agent::submit_answers":
                #expect((payload as? SubmitAnswersParams)?.sessionId == sessionId)
                #expect((payload as? SubmitAnswersParams)?.pauseId == "pause-1")
                #expect((payload as? SubmitAnswersParams)?.invocationId == "inv-1")
                return SubmitAnswersResponse(acknowledged: true, queued: false, runId: nil)
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
        transport.readHandler = { functionId, payload, options in
            #expect(functionId.rawValue == "agent::work_snapshot")
            #expect(options.context?.sessionId == sessionId)
            let params = try #require(payload as? AgentWorkSnapshotParams)
            #expect(params.sessionId == sessionId)
            #expect(params.workspaceId == nil)
            #expect(params.limit == 12)
            return try Self.decode(WorkSnapshotDTO.self, """
            {
              "autonomy": {
                "mode": "independent",
                "approvalPromptMode": "disabled",
                "interactiveApprovalPrompts": false,
                "statusLabel": "Runs independently",
                "summary": "Approval-required autonomous work is audited and auto-decided unless a guardrail blocks it."
              },
              "activeWork": [],
              "workers": [
                {
                  "workerId": "subagent:review-1",
                  "label": "Review worker",
                  "status": "Running",
                  "health": "healthy",
                  "abilityCount": 1,
                  "abilities": [
                    {
                      "functionId": "agent::spawn_subagent",
                      "label": "Delegated agent work",
                      "risk": "Medium",
                      "effect": "ExternalSideEffect",
                      "health": "Healthy"
                    }
                  ],
                  "namespaceClaims": ["agent"],
                  "workerType": "agent",
                  "runId": "review-1",
                  "elapsedMs": 1200,
                  "auditRef": {"kind": "subagent", "id": "review-1", "traceId": null}
                }
              ],
              "recentMilestones": [],
              "guardrails": [],
              "auditRefs": [{"kind": "catalog", "catalogRevision": 42}],
              "scope": {"sessionId": "\(sessionId)", "workspaceId": null}
            }
            """)
        }

        try await client.sendPrompt("Hello", idempotencyKey: .userAction("agent.prompt.test"))
        _ = try await client.activateSkill("browser", idempotencyKey: .userAction("skills.activate.test"))
        _ = try await client.deactivateSkill("browser", idempotencyKey: .userAction("skills.deactivate.test"))
        _ = try await client.queuePrompt("queued", idempotencyKey: .userAction("agent.queuePrompt.test"))
        try await client.dequeuePrompt("queue-1", idempotencyKey: .userAction("agent.dequeuePrompt.test"))
        try await client.clearQueue(idempotencyKey: .userAction("agent.clearQueue.test"))
        _ = try await client.submitAnswers(
            pauseId: "pause-1",
            invocationId: "inv-1",
            questions: [],
            idempotencyKey: .userAction("agent.submitAnswers.test")
        )
        try await client.abort(idempotencyKey: .userAction("agent.abort.test"))
        _ = try await client.abortCapabilityInvocation(invocationId: "capability-1", idempotencyKey: .userAction("agent.abortCapabilityInvocation.test"))
        let snapshot = try await client.workSnapshot(sessionId: sessionId, limit: 12)
        #expect(snapshot.workers.first?.label == "Review worker")
        #expect(snapshot.auditRefs.first?.catalogRevision == 42)
        #expect(transport.ensureSessionEventSubscriptionCallCount == 5)
        #expect(transport.operationOrder.prefix(2) == [
            "subscribe:\(sessionId)",
            "write:agent::prompt"
        ])
        #expect(seenFunctions == [
            "agent::prompt",
            "skills::activate",
            "skills::deactivate",
            "agent::queue_prompt",
            "agent::dequeue_prompt",
            "agent::clear_queue",
            "agent::submit_answers",
            "agent::abort",
            "agent::abort_invocation"
        ])
        #expect(transport.lastReadFunctionId?.rawValue == "agent::work_snapshot")
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

    // MARK: - Skill Activation Tests

    @Test("Activate skill calls correctly")
    func testActivateSkill_calls() async throws {
        let mock = MockAgentClient()

        let result = try await mock.activateSkill("browser", idempotencyKey: .userAction("skills.activate.test"))

        #expect(mock.activateSkillCallCount == 1)
        #expect(mock.lastActivatedSkill == "browser")
        #expect(result.success == true)
        #expect(result.skill?.name == "browser")
    }

    @Test("Deactivate skill calls correctly")
    func testDeactivateSkill_calls() async throws {
        let mock = MockAgentClient()

        let result = try await mock.deactivateSkill("browser", idempotencyKey: .userAction("skills.deactivate.test"))

        #expect(mock.deactivateSkillCallCount == 1)
        #expect(mock.lastDeactivatedSkill == "browser")
        #expect(result.success == true)
        #expect(result.deactivatedSkill == "browser")
    }

    @Test("Active skills returns list")
    func testActiveSkills_returns() async throws {
        let mock = MockAgentClient()

        let result = try await mock.activeSkills()

        #expect(mock.activeSkillsCallCount == 1)
        #expect(result.skills.isEmpty)
    }

    @Test("Work snapshot returns server-owned worker projection")
    func testWorkSnapshot_returns() async throws {
        let mock = MockAgentClient()

        let result = try await mock.workSnapshot(sessionId: nil, workspaceId: nil, limit: 12)

        #expect(mock.workSnapshotCallCount == 1)
        #expect(result.autonomy.mode == "independent")
        #expect(result.auditRefs.first?.kind == "catalog")
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
