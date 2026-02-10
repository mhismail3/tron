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
        var lastSkills: [Skill]?
        var lastSpells: [Skill]?
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

        var sendToolResultCallCount = 0
        var sendToolResultSessionId: String?
        var sendToolResultToolCallId: String?
        var sendToolResultShouldThrow = false

        func sendPrompt(
            _ prompt: String,
            images: [ImageAttachment]?,
            attachments: [FileAttachment]?,
            reasoningLevel: String?,
            skills: [Skill]?,
            spells: [Skill]?
        ) async throws {
            sendPromptCallCount += 1
            lastPrompt = prompt
            lastImages = images
            lastAttachments = attachments
            lastReasoningLevel = reasoningLevel
            lastSkills = skills
            lastSpells = spells
            if sendPromptShouldThrow { throw TestError.mockError }
        }

        func abort() async throws {
            abortCallCount += 1
            if abortShouldThrow { throw TestError.mockError }
        }

        func getState() async throws -> AgentStateResult {
            getStateCallCount += 1
            getStateSessionId = nil
            if getStateShouldThrow { throw TestError.mockError }
            return makeAgentStateResult()
        }

        func getState(sessionId: String) async throws -> AgentStateResult {
            getStateCallCount += 1
            getStateSessionId = sessionId
            if getStateShouldThrow { throw TestError.mockError }
            return makeAgentStateResult()
        }

        private func makeAgentStateResult() -> AgentStateResult {
            // AgentStateResult is Decodable, so we create it via JSON
            let json = """
            {
                "isRunning": \(getStateIsRunning),
                "currentTurn": \(getStateCurrentTurn),
                "messageCount": \(getStateMessageCount),
                "model": "\(getStateModel)"
            }
            """
            return try! JSONDecoder().decode(AgentStateResult.self, from: json.data(using: .utf8)!)
        }

        func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {
            sendToolResultCallCount += 1
            sendToolResultSessionId = sessionId
            sendToolResultToolCallId = toolCallId
            if sendToolResultShouldThrow { throw TestError.mockError }
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

    // MARK: - Send Prompt Tests

    @Test("Send prompt with minimal parameters")
    func testSendPrompt_minimal() async throws {
        let mock = MockAgentClient()

        try await mock.sendPrompt("Hello")

        #expect(mock.sendPromptCallCount == 1)
        #expect(mock.lastPrompt == "Hello")
        #expect(mock.lastImages == nil)
        #expect(mock.lastAttachments == nil)
        #expect(mock.lastReasoningLevel == nil)
        #expect(mock.lastSkills == nil)
        #expect(mock.lastSpells == nil)
    }

    @Test("Send prompt with all parameters")
    func testSendPrompt_withAllParams() async throws {
        let mock = MockAgentClient()
        let testSkill = Self.makeTestSkill()

        try await mock.sendPrompt(
            "Hello",
            images: nil,
            attachments: nil,
            reasoningLevel: "medium",
            skills: [testSkill],
            spells: nil
        )

        #expect(mock.lastReasoningLevel == "medium")
        #expect(mock.lastSkills?.count == 1)
        #expect(mock.lastSkills?.first?.name == "test-skill")
    }

    @Test("Send prompt throws on error")
    func testSendPrompt_throwsOnError() async throws {
        let mock = MockAgentClient()
        mock.sendPromptShouldThrow = true

        await #expect(throws: MockAgentClient.TestError.self) {
            try await mock.sendPrompt("Hello")
        }
    }

    // MARK: - Abort Tests

    @Test("Abort calls correctly")
    func testAbort_calls() async throws {
        let mock = MockAgentClient()

        try await mock.abort()

        #expect(mock.abortCallCount == 1)
    }

    @Test("Abort throws on error")
    func testAbort_throwsOnError() async throws {
        let mock = MockAgentClient()
        mock.abortShouldThrow = true

        await #expect(throws: MockAgentClient.TestError.self) {
            try await mock.abort()
        }
    }

    // MARK: - Get State Tests

    @Test("Get state for current session")
    func testGetState_currentSession() async throws {
        let mock = MockAgentClient()
        mock.getStateIsRunning = true
        mock.getStateCurrentTurn = 3

        let result = try await mock.getState()

        #expect(mock.getStateCallCount == 1)
        #expect(result.isRunning == true)
        #expect(result.currentTurn == 3)
    }

    @Test("Get state for specific session")
    func testGetState_specificSession() async throws {
        let mock = MockAgentClient()

        _ = try await mock.getState(sessionId: "session-123")

        #expect(mock.getStateSessionId == "session-123")
    }

    @Test("Get state throws on error")
    func testGetState_throwsOnError() async throws {
        let mock = MockAgentClient()
        mock.getStateShouldThrow = true

        await #expect(throws: MockAgentClient.TestError.self) {
            _ = try await mock.getState()
        }
    }

    // MARK: - Send Tool Result Tests

    // MARK: - Helper to create test AskUserQuestionResult

    static func makeTestResult() -> AskUserQuestionResult {
        let json = """
        {
            "answers": [{"questionId": "q1", "selectedValues": ["answer"]}],
            "complete": true,
            "submittedAt": "2024-01-01T00:00:00Z"
        }
        """
        return try! JSONDecoder().decode(AskUserQuestionResult.self, from: json.data(using: .utf8)!)
    }

    @Test("Send tool result calls correctly")
    func testSendToolResult_calls() async throws {
        let mock = MockAgentClient()
        let result = Self.makeTestResult()

        try await mock.sendToolResult(sessionId: "session-123", toolCallId: "tool-456", result: result)

        #expect(mock.sendToolResultCallCount == 1)
        #expect(mock.sendToolResultSessionId == "session-123")
        #expect(mock.sendToolResultToolCallId == "tool-456")
    }

    @Test("Send tool result throws on error")
    func testSendToolResult_throwsOnError() async throws {
        let mock = MockAgentClient()
        mock.sendToolResultShouldThrow = true
        let result = Self.makeTestResult()

        await #expect(throws: MockAgentClient.TestError.self) {
            try await mock.sendToolResult(sessionId: "session-123", toolCallId: "tool-456", result: result)
        }
    }
}
