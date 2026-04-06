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

        var sendToolResultCallCount = 0
        var sendToolResultSessionId: String?
        var sendToolResultToolCallId: String?
        var sendToolResultShouldThrow = false

        var activateSkillCallCount = 0
        var lastActivatedSkill: String?
        var deactivateSkillCallCount = 0
        var lastDeactivatedSkill: String?
        var castSpellCallCount = 0
        var lastCastSpell: String?
        var activeSkillsCallCount = 0

        func sendPrompt(
            _ prompt: String,
            images: [ImageAttachment]?,
            attachments: [FileAttachment]?,
            reasoningLevel: String?
        ) async throws {
            sendPromptCallCount += 1
            lastPrompt = prompt
            lastImages = images
            lastAttachments = attachments
            lastReasoningLevel = reasoningLevel
            if sendPromptShouldThrow { throw TestError.mockError }
        }

        func abort() async throws {
            abortCallCount += 1
            if abortShouldThrow { throw TestError.mockError }
        }

        func sendToolResult(sessionId: String, toolCallId: String, result: AskUserQuestionResult) async throws {
            sendToolResultCallCount += 1
            sendToolResultSessionId = sessionId
            sendToolResultToolCallId = toolCallId
            if sendToolResultShouldThrow { throw TestError.mockError }
        }

        func activateSkill(_ skillName: String) async throws -> SkillActivateResult {
            activateSkillCallCount += 1
            lastActivatedSkill = skillName
            let json = """
            {"success": true, "skill": {"name": "\(skillName)", "source": "global", "tokens": 100}}
            """
            return try! JSONDecoder().decode(SkillActivateResult.self, from: json.data(using: .utf8)!)
        }

        func deactivateSkill(_ skillName: String) async throws -> SkillDeactivateResult {
            deactivateSkillCallCount += 1
            lastDeactivatedSkill = skillName
            let json = """
            {"success": true, "wasActive": true, "deactivatedSkill": "\(skillName)"}
            """
            return try! JSONDecoder().decode(SkillDeactivateResult.self, from: json.data(using: .utf8)!)
        }

        func castSpell(_ spellName: String) async throws -> SpellCastResult {
            castSpellCallCount += 1
            lastCastSpell = spellName
            let json = """
            {"success": true, "spell": {"name": "\(spellName)", "source": "global"}}
            """
            return try! JSONDecoder().decode(SpellCastResult.self, from: json.data(using: .utf8)!)
        }

        func activeSkills() async throws -> SkillActiveResult {
            activeSkillsCallCount += 1
            let json = """
            {"skills": [], "pendingSpells": []}
            """
            return try! JSONDecoder().decode(SkillActiveResult.self, from: json.data(using: .utf8)!)
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
    }

    @Test("Send prompt with reasoning level")
    func testSendPrompt_withReasoningLevel() async throws {
        let mock = MockAgentClient()

        try await mock.sendPrompt(
            "Hello",
            images: nil,
            attachments: nil,
            reasoningLevel: "medium"
        )

        #expect(mock.lastReasoningLevel == "medium")
    }

    @Test("Send prompt throws on error")
    func testSendPrompt_throwsOnError() async throws {
        let mock = MockAgentClient()
        mock.sendPromptShouldThrow = true

        await #expect(throws: MockAgentClient.TestError.self) {
            try await mock.sendPrompt("Hello")
        }
    }

    // MARK: - Skill Activation Tests

    @Test("Activate skill calls correctly")
    func testActivateSkill_calls() async throws {
        let mock = MockAgentClient()

        let result = try await mock.activateSkill("browser")

        #expect(mock.activateSkillCallCount == 1)
        #expect(mock.lastActivatedSkill == "browser")
        #expect(result.success == true)
        #expect(result.skill?.name == "browser")
    }

    @Test("Deactivate skill calls correctly")
    func testDeactivateSkill_calls() async throws {
        let mock = MockAgentClient()

        let result = try await mock.deactivateSkill("browser")

        #expect(mock.deactivateSkillCallCount == 1)
        #expect(mock.lastDeactivatedSkill == "browser")
        #expect(result.success == true)
        #expect(result.wasActive == true)
    }

    @Test("Cast spell calls correctly")
    func testCastSpell_calls() async throws {
        let mock = MockAgentClient()

        let result = try await mock.castSpell("commit")

        #expect(mock.castSpellCallCount == 1)
        #expect(mock.lastCastSpell == "commit")
        #expect(result.success == true)
        #expect(result.spell?.name == "commit")
    }

    @Test("Active skills returns list")
    func testActiveSkills_returns() async throws {
        let mock = MockAgentClient()

        let result = try await mock.activeSkills()

        #expect(mock.activeSkillsCallCount == 1)
        #expect(result.skills.isEmpty)
        #expect(result.pendingSpells.isEmpty)
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
