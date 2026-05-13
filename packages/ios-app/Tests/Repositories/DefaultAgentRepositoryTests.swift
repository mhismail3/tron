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
    var sendPromptError: Error?

    // Abort
    var abortCallCount = 0
    var abortError: Error?

    func sendPrompt(
        _ prompt: String,
        images: [ImageAttachment]?,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        skills: [Skill]?
    ) async throws {
        sendPromptCallCount += 1
        lastSendPromptText = prompt
        lastSendPromptImages = images
        lastSendPromptAttachments = attachments
        lastSendPromptReasoningLevel = reasoningLevel
        lastSendPromptSkills = skills
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

        // When
        try await mockClient.sendPrompt(
            "Hello, Claude!",
            images: nil,
            attachments: nil,
            reasoningLevel: "high",
            skills: skills
        )

        // Then
        XCTAssertEqual(mockClient.sendPromptCallCount, 1)
        XCTAssertEqual(mockClient.lastSendPromptText, "Hello, Claude!")
        XCTAssertNil(mockClient.lastSendPromptImages)
        XCTAssertNil(mockClient.lastSendPromptAttachments)
        XCTAssertEqual(mockClient.lastSendPromptReasoningLevel, "high")
        XCTAssertEqual(mockClient.lastSendPromptSkills?.count, 1)
    }

    func test_sendPrompt_handlesNilOptionalParameters() async throws {
        // When
        try await mockClient.sendPrompt(
            "Simple message",
            images: nil,
            attachments: nil,
            reasoningLevel: nil,
            skills: nil
        )

        // Then
        XCTAssertEqual(mockClient.sendPromptCallCount, 1)
        XCTAssertNil(mockClient.lastSendPromptReasoningLevel)
        XCTAssertNil(mockClient.lastSendPromptSkills)
    }

    func test_sendPrompt_throwsError() async throws {
        // Given
        mockClient.sendPromptError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            try await mockClient.sendPrompt("Hello", images: nil, attachments: nil, reasoningLevel: nil, skills: nil)
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

    // MARK: - Helpers

    private func createMockSkill(name: String) -> Skill {
        Skill(
            name: name,
            displayName: name,
            description: "Test skill",
            source: .global,
            tags: nil
        )
    }
}
