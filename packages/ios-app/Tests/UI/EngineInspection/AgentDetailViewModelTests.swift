import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("Agent Detail View Model Tests")
struct AgentDetailViewModelTests {
    @Test("Assignment head refresh cannot rewind retained history or its cursor")
    func assignmentRefreshPreservesPagedHistoryAcrossRace() async {
        let repository = AgentDetailRepositoryProbe()
        let model = AgentDetailViewModel(
            ownerSessionId: "owner-session",
            agentId: "agent-1",
            repository: repository
        )

        await model.refresh()
        #expect(model.assignments.map(\.assignmentId) == ["assignment-1"])
        #expect(model.assignmentsNextCursor == "assignments-older")

        repository.assignmentHead = assignmentPage(#"""
        {
          "items":[
            {"assignmentId":"assignment-2","status":"queued","task":"New work"},
            {"assignmentId":"assignment-1","status":"running","task":"Updated work"}
          ],
          "nextCursor":"assignments-older"
        }
        """#)
        repository.suspendNextAssignmentHead = true
        let refresh = Task { @MainActor in await model.refresh() }
        while !repository.hasPendingAssignmentHead {
            await Task.yield()
        }

        await model.loadOlderAssignments()
        #expect(model.assignments.map(\.assignmentId) == ["assignment-1", "assignment-0"])
        #expect(model.assignmentsNextCursor == nil)

        repository.resumeAssignmentHead()
        await refresh.value

        #expect(model.assignments.map(\.assignmentId) == [
            "assignment-2", "assignment-1", "assignment-0",
        ])
        #expect(model.assignments.first(where: {
            $0.assignmentId == "assignment-1"
        })?.status == "running")
        #expect(model.assignmentsNextCursor == nil)
    }

    @Test("Message head refresh cannot discard a page loaded under a covering sheet")
    func messageRefreshPreservesPagedHistoryAcrossRace() async {
        let repository = AgentDetailRepositoryProbe()
        let model = AgentDetailViewModel(
            ownerSessionId: "owner-session",
            agentId: "agent-1",
            repository: repository
        )

        await model.refresh()
        #expect(model.messages.map(\.messageId) == ["message-1"])
        #expect(model.messagesNextCursor == "messages-older")

        repository.messageHead = messagePage(#"""
        {
          "items":[
            {
              "messageId":"message-2","direction":"outgoing","kind":"answer",
              "provenance":"operator","deliveryState":"pending","preview":"New answer",
              "createdAt":"2026-08-11T12:02:00Z"
            },
            {
              "messageId":"message-1","direction":"incoming","kind":"question",
              "provenance":"peer","deliveryState":"delivered","preview":"Updated question",
              "createdAt":"2026-08-11T12:01:00Z"
            }
          ],
          "nextCursor":"messages-older"
        }
        """#)
        repository.suspendNextMessageHead = true
        let refresh = Task { @MainActor in await model.refresh() }
        while !repository.hasPendingMessageHead {
            await Task.yield()
        }

        await model.loadOlderMessages()
        #expect(model.messages.map(\.messageId) == ["message-1", "message-0"])
        #expect(model.messagesNextCursor == nil)

        repository.resumeMessageHead()
        await refresh.value

        #expect(model.messages.map(\.messageId) == [
            "message-2", "message-1", "message-0",
        ])
        #expect(model.messages.first(where: {
            $0.messageId == "message-1"
        })?.deliveryState == "delivered")
        #expect(model.messagesNextCursor == nil)
    }

    @Test("Mutation rejection returns exact feedback to the covering sheet")
    func mutationFailureIsReturnedToChildPresentation() async {
        let repository = AgentDetailRepositoryProbe()
        repository.mutationFailure = AgentDetailProbeError.denied
        let model = AgentDetailViewModel(
            ownerSessionId: "owner-session",
            agentId: "agent-1",
            repository: repository
        )

        let outcome = await model.sendOperatorMessage("Continue with the review")

        #expect(!outcome.succeeded)
        #expect(outcome.errorMessage == "The server denied this agent change.")
        #expect(model.mutationError == outcome.errorMessage)
        #expect(!model.isMutating)
    }
}

@MainActor
private final class AgentDetailRepositoryProbe: AgentRepository {
    var supportsCoordinationManagement = true
    var assignmentHead = assignmentPage(#"""
    {
      "items":[
        {"assignmentId":"assignment-1","status":"queued","task":"Initial work"}
      ],
      "nextCursor":"assignments-older"
    }
    """#)
    var assignmentHistory = assignmentPage(#"""
    {
      "items":[
        {"assignmentId":"assignment-0","status":"completed","task":"Older work"}
      ],
      "nextCursor":null
    }
    """#)
    var messageHead = messagePage(#"""
    {
      "items":[
        {
          "messageId":"message-1","direction":"incoming","kind":"question",
          "provenance":"peer","deliveryState":"pending","preview":"Initial question",
          "createdAt":"2026-08-11T12:01:00Z"
        }
      ],
      "nextCursor":"messages-older"
    }
    """#)
    var messageHistory = messagePage(#"""
    {
      "items":[
        {
          "messageId":"message-0","direction":"outgoing","kind":"information",
          "provenance":"agent","deliveryState":"delivered","preview":"Older evidence",
          "createdAt":"2026-08-11T12:00:00Z"
        }
      ],
      "nextCursor":null
    }
    """#)
    var suspendNextAssignmentHead = false
    var suspendNextMessageHead = false
    var mutationFailure: Error?

    private var pendingAssignmentHead: CheckedContinuation<AgentAssignmentsResultDTO, Never>?
    private var pendingMessageHead: CheckedContinuation<AgentMessagesResultDTO, Never>?

    var hasPendingAssignmentHead: Bool { pendingAssignmentHead != nil }
    var hasPendingMessageHead: Bool { pendingMessageHead != nil }

    func resumeAssignmentHead() {
        let continuation = pendingAssignmentHead
        pendingAssignmentHead = nil
        continuation?.resume(returning: assignmentHead)
    }

    func resumeMessageHead() {
        let continuation = pendingMessageHead
        pendingMessageHead = nil
        continuation?.resume(returning: messageHead)
    }

    func inspectAgent(ownerSessionId: String, agentId: String) async throws -> AgentInspectDTO {
        inspectFixture()
    }

    func agentAssignments(
        ownerSessionId: String,
        agentId: String,
        cursor: String?,
        limit: Int
    ) async throws -> AgentAssignmentsResultDTO {
        if cursor != nil { return assignmentHistory }
        if suspendNextAssignmentHead {
            suspendNextAssignmentHead = false
            return await withCheckedContinuation { pendingAssignmentHead = $0 }
        }
        return assignmentHead
    }

    func agentMessages(
        ownerSessionId: String,
        agentId: String,
        cursor: String?,
        limit: Int
    ) async throws -> AgentMessagesResultDTO {
        if cursor != nil { return messageHistory }
        if suspendNextMessageHead {
            suspendNextMessageHead = false
            return await withCheckedContinuation { pendingMessageHead = $0 }
        }
        return messageHead
    }

    func sendOperatorMessage(
        ownerSessionId: String,
        agentId: String,
        content: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try mutationResult()
    }

    func manageAgent(
        ownerSessionId: String,
        agentId: String,
        action: String,
        assignmentId: String?,
        cascade: Bool?,
        configuration: AnyCodable?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try mutationResult()
    }

    func retryAgentAssignment(
        ownerSessionId: String,
        agentId: String,
        assignmentId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try mutationResult()
    }

    func promoteAgent(
        ownerSessionId: String,
        agentId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> AgentMutationResultDTO {
        try mutationResult()
    }

    private func mutationResult() throws -> AgentMutationResultDTO {
        if let mutationFailure { throw mutationFailure }
        return decode(#"""
        {
          "agent":{
            "agentId":"agent-1","name":"Agent One","relationship":"child",
            "status":"idle","grants":[],"limits":[],"writeScopes":[],
            "lineage":[],"contacts":[],"allowedActions":[]
          },
          "affectedAgentIds":["agent-1"]
        }
        """#)
    }

    func agentRelations(
        ownerSessionId: String,
        cursor: String?,
        limit: Int
    ) async throws -> AgentRelationsResultDTO {
        throw AgentDetailProbeError.unexpected
    }

    func agentMessageDetail(
        ownerSessionId: String,
        agentId: String,
        messageId: String
    ) async throws -> AgentMessageDetailDTO {
        throw AgentDetailProbeError.unexpected
    }

    func agentResult(
        ownerSessionId: String,
        agentId: String,
        resultId: String,
        pointer: String,
        offset: UInt64,
        limit: UInt8
    ) async throws -> AgentResultChunkDTO {
        throw AgentDetailProbeError.unexpected
    }

    func sendPrompt(
        _ prompt: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        throw AgentDetailProbeError.unexpected
    }

    func abort(idempotencyKey: EngineIdempotencyKey) async throws -> Bool {
        throw AgentDetailProbeError.unexpected
    }

    func abortToolInvocation(
        invocationId: String,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> Bool {
        throw AgentDetailProbeError.unexpected
    }

    func answerUserInput(
        invocationId: String,
        answers: [UserInputAnswer],
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        throw AgentDetailProbeError.unexpected
    }
}

private enum AgentDetailProbeError: LocalizedError {
    case denied
    case unexpected

    var errorDescription: String? {
        switch self {
        case .denied:
            "The server denied this agent change."
        case .unexpected:
            "Unexpected test repository call."
        }
    }
}

private func inspectFixture() -> AgentInspectDTO {
    decode(#"""
    {
      "agentId":"agent-1","name":"Agent One","relationship":"child",
      "status":"active","grants":[],"limits":[],"writeScopes":[],
      "lineage":[],"contacts":[],"allowedActions":[]
    }
    """#)
}

private func assignmentPage(_ json: String) -> AgentAssignmentsResultDTO {
    decode(json)
}

private func messagePage(_ json: String) -> AgentMessagesResultDTO {
    decode(json)
}

private func decode<Value: Decodable>(_ json: String) -> Value {
    do {
        return try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    } catch {
        preconditionFailure("Invalid agent-detail test fixture: \(error)")
    }
}
