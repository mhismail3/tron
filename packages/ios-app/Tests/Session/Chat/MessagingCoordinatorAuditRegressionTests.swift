import XCTest
@testable import TronMobile

/// Focused regression coverage for the Slice 4 audit findings around local
/// chat affordances. Kept separate from the broad coordinator suite so the
/// budget guard can keep flagging oversized test files.
@MainActor
final class MessagingCoordinatorAuditRegressionTests: XCTestCase {
    var coordinator: MessagingCoordinator!
    var mockContext: MockMessagingContext!

    override func setUp() async throws {
        mockContext = MockMessagingContext()
        coordinator = MessagingCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    func testSendMessageClearsServerSendFailureOnLaterSuccessfulSend() async {
        mockContext.inputText = "Prompt that fails"
        mockContext.sendPromptShouldFail = true
        await coordinator.sendMessage(context: mockContext)
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("agent.prompt.send.failed"))

        mockContext.inputText = "Prompt that succeeds"
        mockContext.sendPromptShouldFail = false
        await coordinator.sendMessage(context: mockContext)

        XCTAssertFalse(mockContext.localErrorDedupKeys.contains("agent.prompt.send.failed"))
        XCTAssertTrue(mockContext.clearLocalNotificationsCalled)
    }

    func testSendMessageFailureClearsProcessingFlagsAndShowsLocalNotification() async {
        mockContext.inputText = "Prompt that fails before server acceptance"
        mockContext.sendPromptShouldFail = true

        await coordinator.sendMessage(context: mockContext)

        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, false)
        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("agent.prompt.send.failed"))
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not send message")
    }

    func testRetryMessageDoesNotSendWhenLiveEventSubscriptionFails() async {
        mockContext.ensureLiveEventSubscriptionShouldFail = true

        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertFalse(mockContext.sendPromptCalled)
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertTrue(mockContext.showErrorCalled)
    }

    func testRetryMessageSharesProcessingAndStreamingSetupWithoutConsumingComposer() async {
        mockContext.inputText = "draft stays put"

        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertTrue(mockContext.isProcessing)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, true)
        XCTAssertTrue(mockContext.streamingManagerResetCalled)
        XCTAssertEqual(mockContext.lastSessionActivityPrompt, "retry this prompt")
        XCTAssertEqual(mockContext.inputText, "draft stays put")
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testRetryMessageClearsStaleRetryErrorAfterSuccess() async {
        mockContext.sendPromptShouldFail = true
        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("turn.retry.failed"))

        mockContext.sendPromptShouldFail = false
        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertFalse(mockContext.localErrorDedupKeys.contains("turn.retry.failed"))
        XCTAssertTrue(mockContext.clearLocalNotificationsCalled)
    }

    func testRetryMessageFailureClearsProcessingFlagsAndShowsLocalNotification() async {
        mockContext.inputText = "draft stays put"
        mockContext.sendPromptShouldFail = true

        await coordinator.retryMessage(
            prompt: "retry this prompt",
            attachments: nil,
            context: mockContext
        )

        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertEqual(mockContext.lastSentText, "retry this prompt")
        XCTAssertFalse(mockContext.isProcessing)
        XCTAssertEqual(mockContext.lastSessionProcessingValue, false)
        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertTrue(mockContext.localErrorDedupKeys.contains("turn.retry.failed"))
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not retry")
        XCTAssertEqual(mockContext.inputText, "draft stays put")
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }
}
