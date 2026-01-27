import Testing
import Foundation
@testable import TronMobile

// MARK: - Mock Agent Client for Abort Testing

@MainActor
final class MockAgentClientForAbort: AgentClientProtocol {
    var abortCalled = false
    var shouldThrowError = false
    var errorToThrow: Error?

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws {}

    func abort() async throws {
        if shouldThrowError {
            throw errorToThrow ?? NSError(domain: "Test", code: 1, userInfo: nil)
        }
        abortCalled = true
    }

    func getState() async throws -> AgentStateResult {
        try makeAgentStateResult(isProcessing: false)
    }

    func getState(sessionId: String) async throws -> AgentStateResult {
        try makeAgentStateResult(isProcessing: false)
    }

    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {}

    private func makeAgentStateResult(isProcessing: Bool) throws -> AgentStateResult {
        let json = """
        {"isProcessing": \(isProcessing)}
        """
        return try JSONDecoder().decode(AgentStateResult.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - AbortSessionUseCase Tests

@MainActor
@Suite("AbortSessionUseCase Tests")
struct AbortSessionUseCaseTests {

    @Test("Execute calls abort on agent client")
    func testExecute_callsAbort() async throws {
        let mockClient = MockAgentClientForAbort()
        let useCase = AbortSessionUseCase(agentClient: mockClient)

        try await useCase.execute()

        #expect(mockClient.abortCalled == true)
    }

    @Test("Execute throws on abort error")
    func testExecute_throwsOnError() async throws {
        let mockClient = MockAgentClientForAbort()
        mockClient.shouldThrowError = true

        let useCase = AbortSessionUseCase(agentClient: mockClient)

        await #expect(throws: AbortSessionError.self) {
            try await useCase.execute()
        }
    }

    @Test("Execute can be called with void request")
    func testExecute_voidRequestConformance() async throws {
        let mockClient = MockAgentClientForAbort()
        let useCase = AbortSessionUseCase(agentClient: mockClient)

        // VoidRequestUseCase allows calling with () or no argument
        try await useCase.execute(())

        #expect(mockClient.abortCalled == true)
    }
}
