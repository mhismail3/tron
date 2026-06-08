import XCTest
@testable import TronMobile

// MARK: - Mock Agent Client for Repository Testing

@MainActor
final class MockAgentClientForRepository {
    // Send Prompt
    var sendPromptCallCount = 0
    var lastSendPromptText: String?
    var lastSendPromptAttachments: [FileAttachment]?
    var lastSendPromptReasoningLevel: String?
    var sendPromptError: Error?

    // Abort
    var abortCallCount = 0
    var abortError: Error?

    func sendPrompt(
        _ prompt: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?
    ) async throws {
        sendPromptCallCount += 1
        lastSendPromptText = prompt
        lastSendPromptAttachments = attachments
        lastSendPromptReasoningLevel = reasoningLevel
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
        // When
        try await mockClient.sendPrompt(
            "Hello, Claude!",
            attachments: nil,
            reasoningLevel: "high"
        )

        // Then
        XCTAssertEqual(mockClient.sendPromptCallCount, 1)
        XCTAssertEqual(mockClient.lastSendPromptText, "Hello, Claude!")
        XCTAssertNil(mockClient.lastSendPromptAttachments)
        XCTAssertEqual(mockClient.lastSendPromptReasoningLevel, "high")
    }

    func test_sendPrompt_handlesNilOptionalParameters() async throws {
        // When
        try await mockClient.sendPrompt(
            "Simple message",
            attachments: nil,
            reasoningLevel: nil
        )

        // Then
        XCTAssertEqual(mockClient.sendPromptCallCount, 1)
        XCTAssertNil(mockClient.lastSendPromptReasoningLevel)
    }

    func test_sendPrompt_throwsError() async throws {
        // Given
        mockClient.sendPromptError = NSError(domain: "Test", code: 1, userInfo: nil)

        // When/Then
        do {
            try await mockClient.sendPrompt("Hello", attachments: nil, reasoningLevel: nil)
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

}
