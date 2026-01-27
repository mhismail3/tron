import Testing
import Foundation
@testable import TronMobile

// MARK: - Mock Agent Client for Testing

@MainActor
final class MockAgentClientForUseCase: AgentClientProtocol {
    var sendPromptCalled = false
    var lastPrompt: String?
    var lastImages: [ImageAttachment]?
    var lastAttachments: [FileAttachment]?
    var lastReasoningLevel: String?
    var lastSkills: [Skill]?
    var lastSpells: [Skill]?
    var shouldThrowError = false
    var errorToThrow: Error?

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws {
        if shouldThrowError {
            throw errorToThrow ?? NSError(domain: "Test", code: 1, userInfo: nil)
        }
        sendPromptCalled = true
        lastPrompt = prompt
        lastImages = images
        lastAttachments = attachments
        lastReasoningLevel = reasoningLevel
        lastSkills = skills
        lastSpells = spells
    }

    func abort() async throws {}
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

// MARK: - SendMessageUseCase Tests

@MainActor
@Suite("SendMessageUseCase Tests")
struct SendMessageUseCaseTests {

    @Test("Execute sends message with minimal parameters")
    func testExecute_minimalParameters() async throws {
        let mockClient = MockAgentClientForUseCase()
        let useCase = SendMessageUseCase(agentClient: mockClient)

        let request = SendMessageUseCase.Request(
            message: "Hello, Claude!"
        )

        try await useCase.execute(request)

        #expect(mockClient.sendPromptCalled == true)
        #expect(mockClient.lastPrompt == "Hello, Claude!")
        #expect(mockClient.lastImages == nil)
        #expect(mockClient.lastAttachments == nil)
        #expect(mockClient.lastReasoningLevel == nil)
    }

    @Test("Execute sends message with all parameters")
    func testExecute_allParameters() async throws {
        let mockClient = MockAgentClientForUseCase()
        let useCase = SendMessageUseCase(agentClient: mockClient)

        let request = SendMessageUseCase.Request(
            message: "Analyze this image",
            images: [],
            attachments: [],
            reasoningLevel: "high",
            skills: [],
            spells: []
        )

        try await useCase.execute(request)

        #expect(mockClient.sendPromptCalled == true)
        #expect(mockClient.lastPrompt == "Analyze this image")
        #expect(mockClient.lastReasoningLevel == "high")
    }

    @Test("Execute throws on agent error")
    func testExecute_throwsOnError() async throws {
        let mockClient = MockAgentClientForUseCase()
        mockClient.shouldThrowError = true
        mockClient.errorToThrow = SendMessageError.agentNotResponding

        let useCase = SendMessageUseCase(agentClient: mockClient)

        let request = SendMessageUseCase.Request(message: "Hello")

        await #expect(throws: SendMessageError.self) {
            try await useCase.execute(request)
        }
    }

    @Test("Execute validates non-empty message")
    func testExecute_validatesNonEmptyMessage() async throws {
        let mockClient = MockAgentClientForUseCase()
        let useCase = SendMessageUseCase(agentClient: mockClient)

        let request = SendMessageUseCase.Request(message: "")

        await #expect(throws: SendMessageError.self) {
            try await useCase.execute(request)
        }

        #expect(mockClient.sendPromptCalled == false)
    }

    @Test("Execute validates whitespace-only message")
    func testExecute_validatesWhitespaceOnlyMessage() async throws {
        let mockClient = MockAgentClientForUseCase()
        let useCase = SendMessageUseCase(agentClient: mockClient)

        let request = SendMessageUseCase.Request(message: "   \n\t  ")

        await #expect(throws: SendMessageError.self) {
            try await useCase.execute(request)
        }

        #expect(mockClient.sendPromptCalled == false)
    }

    @Test("Execute trims message whitespace")
    func testExecute_trimsMessageWhitespace() async throws {
        let mockClient = MockAgentClientForUseCase()
        let useCase = SendMessageUseCase(agentClient: mockClient)

        let request = SendMessageUseCase.Request(message: "  Hello  ")

        try await useCase.execute(request)

        #expect(mockClient.lastPrompt == "Hello")
    }
}
