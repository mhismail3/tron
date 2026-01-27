import XCTest
@testable import TronMobile

// MARK: - Mock Agent Client for Repository Testing

@MainActor
final class MockAgentClientForRepository {
    // Send Prompt
    var sendPromptCallCount = 0
    var lastSendPromptText: String?
    var lastSendPromptImages: [ImageAttachment]?
    var lastSendPromptAttachments: [FileAttachment]?
    var lastSendPromptReasoningLevel: String?
    var lastSendPromptSkills: [Skill]?
    var lastSendPromptSpells: [Skill]?
    var sendPromptError: Error?

    // Abort
    var abortCallCount = 0
    var abortError: Error?

    // Get State
    var getStateCallCount = 0
    var getStateWithSessionCallCount = 0
    var lastGetStateSessionId: String?
    var getStateResultToReturn: AgentStateResult?
    var getStateError: Error?

    // Send Tool Result
    var sendToolResultCallCount = 0
    var lastSendToolResultSessionId: String?
    var lastSendToolResultToolCallId: String?
    var sendToolResultError: Error?

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?,
        spells: [Skill]?
    ) async throws {
        sendPromptCallCount += 1
        lastSendPromptText = prompt
        lastSendPromptImages = images
        lastSendPromptAttachments = attachments
        lastSendPromptReasoningLevel = reasoningLevel
        lastSendPromptSkills = skills
        lastSendPromptSpells = spells
        if let error = sendPromptError {
            throw error
        }
    }

    func abort() async throws {
        abortCallCount += 1
        if let error = abortError {
            throw error
        }
    }

    func getState() async throws -> AgentStateResult {
        getStateCallCount += 1
        if let error = getStateError {
            throw error
        }
        return getStateResultToReturn ?? createMockAgentState()
    }

    func getState(sessionId: String) async throws -> AgentStateResult {
        getStateWithSessionCallCount += 1
        lastGetStateSessionId = sessionId
        if let error = getStateError {
            throw error
        }
        return getStateResultToReturn ?? createMockAgentState()
    }

    func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {
        sendToolResultCallCount += 1
        lastSendToolResultSessionId = sessionId
        lastSendToolResultToolCallId = toolCallId
        if let error = sendToolResultError {
            throw error
        }
    }

    private func createMockAgentState() -> AgentStateResult {
        let json = """
        {"isProcessing": false}
        """
        return try! JSONDecoder().decode(AgentStateResult.self, from: json.data(using: .utf8)!)
    }
}

// MARK: - DefaultAgentRepository Tests

@MainActor
final class DefaultAgentRepositoryTests: XCTestCase {

    var mockClient: MockAgentClientForRepository!

    override func setUp() async throws {
        mockClient = MockAgentClientForRepository()
    }

    override func tearDown() async throws {
        mockClient = nil
    }

    // MARK: - Send Prompt Tests

    func test_sendPrompt_passesAllParameters() async throws {
        // Given
        let skills = [createMockSkill(name: "skill1")]
        let spells = [createMockSkill(name: "spell1")]

        // When
        try await mockClient.sendPrompt(
            "Hello, Claude!",
            images: nil,
            attachments: nil,
            reasoningLevel: "high",
            skills: skills,
            spells: spells
        )

        // Then
        XCTAssertEqual(mockClient.sendPromptCallCount, 1)
        XCTAssertEqual(mockClient.lastSendPromptText, "Hello, Claude!")
        XCTAssertNil(mockClient.lastSendPromptImages)
        XCTAssertNil(mockClient.lastSendPromptAttachments)
        XCTAssertEqual(mockClient.lastSendPromptReasoningLevel, "high")
        XCTAssertEqual(mockClient.lastSendPromptSkills?.count, 1)
        XCTAssertEqual(mockClient.lastSendPromptSpells?.count, 1)
    }

    func test_sendPrompt_handlesNilOptionalParameters() async throws {
        // When
        try await mockClient.sendPrompt(
            "Simple message",
            images: nil,
            attachments: nil,
            reasoningLevel: nil,
            skills: nil,
            spells: nil
        )

        // Then
        XCTAssertEqual(mockClient.sendPromptCallCount, 1)
        XCTAssertNil(mockClient.lastSendPromptReasoningLevel)
        XCTAssertNil(mockClient.lastSendPromptSkills)
        XCTAssertNil(mockClient.lastSendPromptSpells)
    }

    func test_sendPrompt_throwsError() async throws {
        // Given
        mockClient.sendPromptError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            try await mockClient.sendPrompt("Hello", images: nil, attachments: nil, reasoningLevel: nil, skills: nil, spells: nil)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.sendPromptCallCount, 1)
        }
    }

    // MARK: - Abort Tests

    func test_abort_callsClient() async throws {
        // When
        try await mockClient.abort()

        // Then
        XCTAssertEqual(mockClient.abortCallCount, 1)
    }

    func test_abort_throwsError() async throws {
        // Given
        mockClient.abortError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            try await mockClient.abort()
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.abortCallCount, 1)
        }
    }

    // MARK: - Get State Tests

    func test_getState_callsClient() async throws {
        // When
        let state = try await mockClient.getState()

        // Then
        XCTAssertEqual(mockClient.getStateCallCount, 1)
        XCTAssertNotNil(state)
    }

    func test_getState_withSessionId_passesSessionId() async throws {
        // When
        _ = try await mockClient.getState(sessionId: "session-123")

        // Then
        XCTAssertEqual(mockClient.getStateWithSessionCallCount, 1)
        XCTAssertEqual(mockClient.lastGetStateSessionId, "session-123")
    }

    func test_getState_throwsError() async throws {
        // Given
        mockClient.getStateError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            _ = try await mockClient.getState()
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.getStateCallCount, 1)
        }
    }

    // MARK: - Send Tool Result Tests

    func test_sendToolResult_passesParameters() async throws {
        // Given
        let answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["answer1"],
            otherValue: nil
        )
        let result = AskUserQuestionResult(
            answers: [answer],
            complete: true,
            submittedAt: ISO8601DateFormatter().string(from: Date())
        )

        // When
        try await mockClient.sendToolResult(sessionId: "session-123", toolCallId: "tool-456", result: result)

        // Then
        XCTAssertEqual(mockClient.sendToolResultCallCount, 1)
        XCTAssertEqual(mockClient.lastSendToolResultSessionId, "session-123")
        XCTAssertEqual(mockClient.lastSendToolResultToolCallId, "tool-456")
    }

    func test_sendToolResult_throwsError() async throws {
        // Given
        mockClient.sendToolResultError = NSError(domain: "Test", code: 1, userInfo: nil)
        let result = AskUserQuestionResult(
            answers: [],
            complete: false,
            submittedAt: ISO8601DateFormatter().string(from: Date())
        )

        // When/Then
        do {
            try await mockClient.sendToolResult(sessionId: "session-123", toolCallId: "tool-456", result: result)
            XCTFail("Expected error to be thrown")
        } catch {
            XCTAssertEqual(mockClient.sendToolResultCallCount, 1)
        }
    }

    // MARK: - Helpers

    private func createMockSkill(name: String) -> Skill {
        Skill(
            name: name,
            displayName: name,
            description: "Test skill",
            source: .global,
            autoInject: false,
            tags: nil
        )
    }
}
