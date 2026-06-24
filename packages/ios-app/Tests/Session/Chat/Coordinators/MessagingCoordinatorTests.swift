import XCTest
import PhotosUI
import SwiftUI
@testable import TronMobile

/// Tests for MessagingCoordinator - handles message sending, abort, and attachments
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class MessagingCoordinatorTests: XCTestCase {

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

    // MARK: - Send Message Validation Tests

    func testSendMessageWithEmptyTextAndNoAttachmentsDoesNothing() async {
        // Given: Empty input
        mockContext.inputText = ""
        mockContext.attachments = []

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Should not send
        XCTAssertFalse(mockContext.sendPromptCalled)
        XCTAssertFalse(mockContext.isProcessing)
    }

    func testSendMessageWithWhitespaceOnlyDoesNothing() async {
        // Given: Whitespace-only input
        mockContext.inputText = "   \n\t  "
        mockContext.attachments = []

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Should not send
        XCTAssertFalse(mockContext.sendPromptCalled)
    }

    func testSendMessageWithTextSendsToServer() async {
        // Given: Valid text input
        mockContext.inputText = "Hello, world!"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Should send to server
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertEqual(mockContext.lastSentText, "Hello, world!")
    }

    func testSendMessageEnsuresLiveEventSubscriptionBeforePrompt() async {
        // Given: Valid text input
        mockContext.inputText = "Stream the response live"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: The chat view is subscribed before server output starts.
        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertEqual(mockContext.callOrder.prefix(2), ["ensureLiveEventSubscription", "sendPromptToServer"])
    }

    func testSendMessageDoesNotSendWhenLiveEventSubscriptionFails() async {
        // Given: Valid text, but the live stream cannot be established.
        mockContext.inputText = "Stream the response live"
        mockContext.ensureLiveEventSubscriptionShouldFail = true

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Do not start server work that the client cannot observe.
        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertFalse(mockContext.sendPromptCalled)
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertEqual(mockContext.inputText, "Stream the response live")
    }

    func testSendMessageDoesNotRecordRecentInputWhenLiveEventSubscriptionFails() async {
        // Given: Valid text, but the live stream cannot be established.
        let history = InputHistoryStore()
        history.clearHistory()
        mockContext.inputText = "Stream the response live"
        mockContext.ensureLiveEventSubscriptionShouldFail = true

        // When: Sending message
        await coordinator.sendMessage(context: mockContext) { sentText in
            history.addToHistory(sentText)
        }

        // Then: Failed subscription does not retain attempted input.
        XCTAssertTrue(mockContext.ensureLiveEventSubscriptionCalled)
        XCTAssertFalse(mockContext.sendPromptCalled)
        XCTAssertTrue(history.history.isEmpty)

        history.clearHistory()
    }

    func testSendMessageDoesNotRecordRecentInputWhenServerSendFails() async {
        // Given: Valid text, but the server send request fails.
        let history = InputHistoryStore()
        history.clearHistory()
        mockContext.inputText = "Prompt that fails to send"
        mockContext.sendPromptShouldFail = true

        // When: Sending message
        await coordinator.sendMessage(context: mockContext) { sentText in
            history.addToHistory(sentText)
        }

        // Then: Failed sends are not retained as recent sent inputs.
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertEqual(mockContext.lastLocalErrorDedupKey, "agent.prompt.send.failed")
        XCTAssertTrue(history.history.isEmpty)

        history.clearHistory()
    }

    func testSendMessageRecordsRecentInputAfterSuccessfulServerSend() async {
        // Given: Valid text with surrounding whitespace.
        let history = InputHistoryStore()
        history.clearHistory()
        mockContext.inputText = "  Prompt that sends successfully  "

        // When: Sending message
        await coordinator.sendMessage(context: mockContext) { sentText in
            history.addToHistory(sentText)
        }

        // Then: Only the trimmed prompt accepted by the server is retained.
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertEqual(history.history, ["Prompt that sends successfully"])

        history.clearHistory()
    }

    func testSendMessageWithAttachmentsOnlySendsToServer() async {
        // Given: No text but has attachments
        mockContext.inputText = ""
        mockContext.attachments = [createTestAttachment()]

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Should send to server
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertEqual(mockContext.lastSentAttachments?.count, 1)
    }

    // MARK: - State Management Tests

    func testSendMessageClearsInputText() async {
        // Given: Text input
        mockContext.inputText = "Test message"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Input should be cleared
        XCTAssertTrue(mockContext.inputText.isEmpty)
    }

    func testSendMessageClearsAttachments() async {
        // Given: Attachments
        mockContext.inputText = "Test"
        mockContext.attachments = [createTestAttachment()]

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Attachments should be cleared
        XCTAssertTrue(mockContext.attachments.isEmpty)
    }

    func testSendMessageSetsIsProcessingTrue() async {
        // Given: Valid input
        mockContext.inputText = "Test message"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: isProcessing should be true
        XCTAssertTrue(mockContext.isProcessing)
    }

    func testSendMessageResetsStreamingState() async {
        // Given: Valid input
        mockContext.inputText = "Test"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Streaming manager should be reset
        XCTAssertTrue(mockContext.streamingManagerResetCalled)
    }

    func testSendMessageIncrementsCurrentTurn() async {
        // Given: Valid text input, turn at 0
        mockContext.inputText = "Test"
        mockContext.currentTurn = 5

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Turn should be incremented
        XCTAssertEqual(mockContext.currentTurn, 6)
    }

    // MARK: - User Message Creation Tests

    func testSendMessageAppendsUserMessage() async {
        // Given: Text input
        mockContext.inputText = "Hello"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: User message should be appended
        XCTAssertEqual(mockContext.appendedMessages.count, 1)
        XCTAssertEqual(mockContext.appendedMessages.first?.role, .user)
    }

    // MARK: - Session Activity Update Tests

    func testSendMessageUpdatesSessionProcessingState() async {
        // Given: Valid input
        mockContext.inputText = "Test"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: session processing should be updated
        XCTAssertTrue(mockContext.setSessionProcessingCalled)
        XCTAssertTrue(mockContext.lastSessionProcessingValue ?? false)
    }

    func testSendMessageUpdatesSessionActivitySummary() async {
        // Given: Valid input
        mockContext.inputText = "Test prompt"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: session activity summary should be updated with prompt
        XCTAssertTrue(mockContext.updateSessionActivitySummaryCalled)
        XCTAssertEqual(mockContext.lastSessionActivityPrompt, "Test prompt")
    }

    // MARK: - Reasoning Tests

    func testSendMessagePassesReasoningLevelToServer() async {
        // Given: Input with reasoning level
        mockContext.inputText = "Test"

        // When: Sending message with reasoning level
        await coordinator.sendMessage(reasoningLevel: "high", context: mockContext)

        // Then: Reasoning level should be passed
        XCTAssertEqual(mockContext.lastSentReasoningLevel, "high")
    }

    // MARK: - Error Handling Tests

    func testSendMessageHandlesServerError() async {
        // Given: Server will fail
        mockContext.inputText = "Test"
        mockContext.sendPromptShouldFail = true

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Pre-accept send failures use the local notification path.
        XCTAssertTrue(mockContext.appendLocalErrorCalled)
        XCTAssertEqual(mockContext.lastLocalErrorDedupKey, "agent.prompt.send.failed")
        XCTAssertEqual(mockContext.lastLocalErrorTitle, "Could not send message")
    }

    // MARK: - Abort Agent Tests

    func testAbortAgentCallsServerAbort() async {
        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: Server abort should be called
        XCTAssertTrue(mockContext.abortAgentCalled)
    }

    func testAbortAgentSetsIsProcessingFalse() async {
        // Given: Currently processing
        mockContext.isProcessing = true

        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: isProcessing should be false
        XCTAssertFalse(mockContext.isProcessing)
    }

    func testAbortAgentFinalizesStreamingMessage() async {
        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: Streaming message should be finalized
        XCTAssertTrue(mockContext.finalizeStreamingMessageCalled)
    }

    func testAbortAgentAppendsInterruptedMessage() async {
        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: Interrupted message should be appended
        XCTAssertTrue(mockContext.appendedInterruptedMessage)
    }

    func testAbortAgentUpdatesSessionActivityState() async {
        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: session activity summary should show interrupted
        XCTAssertTrue(mockContext.setSessionProcessingCalled)
        XCTAssertFalse(mockContext.lastSessionProcessingValue ?? true)
        XCTAssertEqual(mockContext.lastSessionActivityResponse, "Interrupted")
    }

    func testAbortAgentHandlesServerError() async {
        // Given: Server abort will fail
        mockContext.abortShouldFail = true

        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: Error should be shown
        XCTAssertTrue(mockContext.showErrorCalled)
    }

    // MARK: - Attachment Management Tests

    func testAddAttachment() {
        // Given: An attachment
        let attachment = createTestAttachment()

        // When: Adding attachment
        coordinator.addAttachment(attachment, context: mockContext)

        // Then: Attachment should be added
        XCTAssertEqual(mockContext.attachments.count, 1)
    }

    func testRemoveAttachment() {
        // Given: Existing attachment
        let attachment = createTestAttachment()
        mockContext.attachments = [attachment]

        // When: Removing attachment
        coordinator.removeAttachment(attachment, context: mockContext)

        // Then: Attachment should be removed
        XCTAssertTrue(mockContext.attachments.isEmpty)
    }

    func testRemoveAttachmentByIdOnly() {
        // Given: Multiple attachments
        let attachment1 = createTestAttachment()
        let attachment2 = createTestAttachment()
        mockContext.attachments = [attachment1, attachment2]

        // When: Removing first attachment
        coordinator.removeAttachment(attachment1, context: mockContext)

        // Then: Only matching attachment removed
        XCTAssertEqual(mockContext.attachments.count, 1)
        XCTAssertEqual(mockContext.attachments.first?.id, attachment2.id)
    }

    // MARK: - Helpers

    private func createTestAttachment() -> Attachment {
        return Attachment(
            type: .image,
            data: Data([0x00, 0x01, 0x02]),
            mimeType: "image/jpeg",
            fileName: "test.jpg",
            originalSize: 100
        )
    }

}

// MARK: - Mock Context

/// Mock implementation of MessagingContext for testing
@MainActor
final class MockMessagingContext: MessagingContext {
    // MARK: - State
    var inputText: String = ""
    var attachments: [Attachment] = []
    var selectedImages: [PhotosPickerItem] = []
    var agentPhase: AgentPhase = .idle
    var draftStore: DraftStore?
    var currentTurn: Int = 0
    var sessionId: String = "test-session"
    // MARK: - Tracking for Assertions
    var sendPromptCalled = false
    var lastSentText: String?
    var lastSentAttachments: [FileAttachment]?
    var lastSentReasoningLevel: String?
    var appendedMessages: [ChatMessage] = []
    var appendedInterruptedMessage = false
    var streamingManagerResetCalled = false
    var setSessionProcessingCalled = false
    var lastSessionProcessingValue: Bool?
    var updateSessionActivitySummaryCalled = false
    var lastSessionActivityPrompt: String?
    var lastSessionActivityResponse: String?
    var appendLocalErrorCalled = false
    var lastLocalErrorDedupKey: String?
    var lastLocalErrorTitle: String?
    var localErrorDedupKeys: Set<String> = []
    var abortAgentCalled = false
    var finalizeStreamingMessageCalled = false
    var cancelActiveDeviceRequestsCalled = false
    var showErrorCalled = false
    var ensureLiveEventSubscriptionCalled = false
    var ensureLiveEventSubscriptionShouldFail = false
    var clearLocalNotificationsCalled = false
    var callOrder: [String] = []

    // MARK: - Test Configuration
    var sendPromptShouldFail = false
    var abortShouldFail = false

    // MARK: - Protocol Methods

    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws {
        callOrder.append("sendPromptToServer")
        sendPromptCalled = true
        lastSentText = text
        lastSentAttachments = attachments
        lastSentReasoningLevel = reasoningLevel

        if sendPromptShouldFail {
            throw MessagingTestError.serverError
        }
    }

    func ensureLiveEventSubscription() async throws {
        callOrder.append("ensureLiveEventSubscription")
        ensureLiveEventSubscriptionCalled = true
        if ensureLiveEventSubscriptionShouldFail {
            throw MessagingTestError.serverError
        }
    }

    func abortAgentOnServer(idempotencyKey: EngineIdempotencyKey) async throws {
        abortAgentCalled = true
        if abortShouldFail {
            throw MessagingTestError.serverError
        }
    }

    func appendMessage(_ message: ChatMessage) {
        appendedMessages.append(message)
    }

    func clearLocalNotifications() {
        clearLocalNotificationsCalled = true
        localErrorDedupKeys.removeAll()
    }

    func appendInterruptedMessage() {
        appendedInterruptedMessage = true
    }

    func finalizeThinkingMessage() {
        // No-op for tests
    }

    func clearThinkingCaption() {
        // No-op for tests
    }

    func flushPendingTextUpdates() {
        // No-op for tests
    }

    func resetStreamingManager() {
        streamingManagerResetCalled = true
    }

    func finalizeStreamingMessage() {
        finalizeStreamingMessageCalled = true
    }

    func cancelActiveDeviceRequests() {
        cancelActiveDeviceRequestsCalled = true
    }

    func setSessionProcessing(_ isProcessing: Bool) {
        setSessionProcessingCalled = true
        lastSessionProcessingValue = isProcessing
    }

    func updateSessionActivitySummary(lastUserPrompt: String?, lastAssistantResponse: String?) {
        updateSessionActivitySummaryCalled = true
        lastSessionActivityPrompt = lastUserPrompt
        lastSessionActivityResponse = lastAssistantResponse
    }

    func handleAgentError(_ message: String) {
        // No-op for tests that assert pre-accept failures use appendLocalError.
    }

    func appendLocalError(dedupKey: String, title: String, message: String, suggestion: String?) {
        appendLocalErrorCalled = true
        lastLocalErrorDedupKey = dedupKey
        lastLocalErrorTitle = title
        localErrorDedupKeys.insert(dedupKey)
    }

    func showError(_ message: String) {
        showErrorCalled = true
    }

    // MARK: - Logging (no-op for tests)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}

// MARK: - Test Error

enum MessagingTestError: Error {
    case serverError
}
