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
        _ = try await client.abortToolInvocation(
            invocationId: "tool-1",
            idempotencyKey: .userAction("agent.abortToolInvocation.test")
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

    @Test("User input answer subscribes before the session-scoped write")
    func answerUserInputUsesDurableSessionWrite() async throws {
        let sessionId = "session-question"
        let transport = makeConnectedTransport(sessionId: sessionId)
        let client = AgentClient(transport: transport)
        transport.writeHandler = { functionId, payload, _, options in
            #expect(functionId.rawValue == "agent::answer_user_input")
            #expect(options.context?.sessionId == sessionId)
            let params = try #require(payload as? AgentAnswerUserInputParams)
            #expect(params.sessionId == sessionId)
            #expect(params.invocationId == "question-1")
            #expect(params.answers.first?.questionId == "format")
            #expect(params.answers.first?.selectedLabel == "Markdown")
            return AgentPromptResult(acknowledged: true)
        }

        try await client.answerUserInput(
            invocationId: "question-1",
            answers: [UserInputAnswer(
                questionId: "format",
                selectedLabel: "Markdown",
                freeText: nil
            )],
            idempotencyKey: .userAction("agent.answerUserInput.question-1")
        )

        #expect(transport.operationOrder.prefix(2) == [
            "subscribe:\(sessionId)",
            "write:agent::answer_user_input",
        ])
    }

    @Test("Coordination reads remain explicitly scoped and paged")
    func coordinationReadsUseOwnerSessionAndOpaqueAgentId() async throws {
        let transport = makeConnectedTransport()
        let client = AgentClient(transport: transport)
        var functions: [String] = []
        transport.readHandler = { functionId, payload, options in
            functions.append(functionId.rawValue)
            #expect(options.context?.sessionId == "owner-session")
            switch functionId.rawValue {
            case "agent::relations":
                let params = try #require(payload as? AgentRelationsParams)
                #expect(params.ownerSessionId == "owner-session")
                #expect(params.cursor == "relations-cursor")
                #expect(params.limit == 100)
                return AgentRelationsResultDTO(
                    totals: AgentRelationTotalsDTO(active: 0, related: 0),
                    items: [],
                    nextCursor: nil
                )
            case "agent::inspect":
                let params = try #require(payload as? AgentInspectParams)
                #expect(params.agentId == "agent-opaque")
                return try Self.inspectFixture()
            case "agent::assignments":
                let params = try #require(payload as? AgentAssignmentsParams)
                #expect(params.agentId == "agent-opaque")
                #expect(params.cursor == "assignment-cursor")
                #expect(params.limit == 1)
                return AgentAssignmentsResultDTO(items: [], nextCursor: nil)
            case "agent::messages":
                let params = try #require(payload as? AgentMessagesParams)
                #expect(params.agentId == "agent-opaque")
                #expect(params.cursor == "message-cursor")
                #expect(params.limit == 100)
                return AgentMessagesResultDTO(items: [], nextCursor: nil)
            case "agent::message_detail":
                let params = try #require(payload as? AgentMessageDetailParams)
                #expect(params.agentId == "agent-opaque")
                #expect(params.messageId == "message-opaque")
                return try Self.messageDetailFixture()
            case "agent::result_read":
                let params = try #require(payload as? AgentResultReadParams)
                #expect(params.agentId == "agent-opaque")
                #expect(params.resultId == "result-opaque")
                #expect(params.pointer == "/summary")
                #expect(params.offset == 20)
                #expect(params.limit == 20)
                return AgentResultChunkDTO(
                    kind: "agent_result",
                    reference: AgentResultReferenceDTO(
                        kind: "agent_assignment",
                        resultId: "result-opaque",
                        assignmentId: "assignment-1",
                        contentSha256: "abc123",
                        sizeBytes: 24,
                        preview: "Complete"
                    ),
                    pointer: "/summary",
                    value: AnyCodable("Complete"),
                    children: [],
                    offset: 20,
                    returned: 1,
                    total: 21,
                    nextOffset: nil,
                    truncated: false
                )
            default:
                throw EngineConnectionError.invalidResponse
            }
        }

        _ = try await client.agentRelations(
            ownerSessionId: "owner-session",
            cursor: "relations-cursor",
            limit: 500
        )
        _ = try await client.inspectAgent(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque"
        )
        _ = try await client.agentAssignments(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            cursor: "assignment-cursor",
            limit: 0
        )
        _ = try await client.agentMessages(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            cursor: "message-cursor",
            limit: 500
        )
        _ = try await client.agentMessageDetail(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            messageId: "message-opaque"
        )
        _ = try await client.agentResult(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            resultId: "result-opaque",
            pointer: "/summary",
            offset: 20,
            limit: 255
        )

        #expect(functions == [
            "agent::relations",
            "agent::inspect",
            "agent::assignments",
            "agent::messages",
            "agent::message_detail",
            "agent::result_read",
        ])
    }

    @Test("Coordination mutations carry one client mutation id and canonical owner context")
    func coordinationWritesCarryIdempotencyAndOwnerContext() async throws {
        let transport = makeConnectedTransport()
        let client = AgentClient(transport: transport)
        var functions: [String] = []
        transport.writeHandler = { functionId, payload, idempotencyKey, options in
            functions.append(functionId.rawValue)
            #expect(options.context?.sessionId == "owner-session")
            #expect(idempotencyKey.rawValue.hasPrefix("coordination-test-"))
            let mutationId: String
            switch functionId.rawValue {
            case "agent::operator_message":
                let params = try #require(payload as? AgentOperatorMessageParams)
                #expect(params.content == "Please summarize progress")
                mutationId = params.clientMutationId
            case "agent::manage":
                let params = try #require(payload as? AgentManageParams)
                #expect(params.action == "cancel")
                #expect(params.assignmentId == "assignment-1")
                #expect(params.cascade == true)
                mutationId = params.clientMutationId
            case "agent::retry":
                let params = try #require(payload as? AgentRetryParams)
                #expect(params.assignmentId == "assignment-1")
                mutationId = params.clientMutationId
            case "agent::promote":
                let params = try #require(payload as? AgentPromoteParams)
                mutationId = params.clientMutationId
            default:
                throw EngineConnectionError.invalidResponse
            }
            #expect(mutationId == idempotencyKey.rawValue)
            return try Self.mutationFixture()
        }

        _ = try await client.sendOperatorMessage(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            content: "Please summarize progress",
            idempotencyKey: "coordination-test-message"
        )
        _ = try await client.manageAgent(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            action: "cancel",
            assignmentId: "assignment-1",
            cascade: true,
            configuration: nil,
            idempotencyKey: "coordination-test-manage"
        )
        _ = try await client.retryAgentAssignment(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            assignmentId: "assignment-1",
            idempotencyKey: "coordination-test-retry"
        )
        _ = try await client.promoteAgent(
            ownerSessionId: "owner-session",
            agentId: "agent-opaque",
            idempotencyKey: "coordination-test-promote"
        )

        #expect(functions == [
            "agent::operator_message",
            "agent::manage",
            "agent::retry",
            "agent::promote",
        ])
    }

    private static func inspectFixture() throws -> AgentInspectDTO {
        try JSONDecoder().decode(AgentInspectDTO.self, from: Data(#"""
        {
          "agentId":"agent-opaque",
          "name":"Research agent",
          "relationship":"child",
          "status":"idle",
          "grants":[],
          "limits":[],
          "writeScopes":[],
          "lineage":[],
          "contacts":[],
          "allowedActions":[]
        }
        """#.utf8))
    }

    private static func mutationFixture() throws -> AgentMutationResultDTO {
        try JSONDecoder().decode(AgentMutationResultDTO.self, from: Data(#"""
        {
          "agent": {
            "agentId":"agent-opaque",
            "name":"Research agent",
            "relationship":"child",
            "status":"idle",
            "grants":[],
            "limits":[],
            "writeScopes":[],
            "lineage":[],
            "contacts":[],
            "allowedActions":[]
          },
          "affectedAgentIds":["agent-opaque"]
        }
        """#.utf8))
    }

    private static func messageDetailFixture() throws -> AgentMessageDetailDTO {
        try JSONDecoder().decode(AgentMessageDetailDTO.self, from: Data(#"""
        {
          "messageId":"message-opaque",
          "direction":"incoming",
          "kind":"question",
          "provenance":"peer",
          "deliveryState":"observed",
          "content":"What did you find?",
          "createdAt":"2026-08-11T00:00:00Z"
        }
        """#.utf8))
    }
}
