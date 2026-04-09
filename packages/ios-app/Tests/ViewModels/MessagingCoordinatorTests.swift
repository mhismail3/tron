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

    func testSendMessageMarksSupersededForRegularMessage() async {
        // Given: Regular message text
        mockContext.inputText = "Just a regular message"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Should mark questions as superseded
        XCTAssertTrue(mockContext.markPendingQuestionsAsSupersededCalled)
    }

    // MARK: - Dashboard Update Tests

    func testSendMessageUpdatesSessionProcessingState() async {
        // Given: Valid input
        mockContext.inputText = "Test"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Dashboard should be updated
        XCTAssertTrue(mockContext.setSessionProcessingCalled)
        XCTAssertTrue(mockContext.lastSessionProcessingValue ?? false)
    }

    func testSendMessageUpdatesDashboardInfo() async {
        // Given: Valid input
        mockContext.inputText = "Test prompt"

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Dashboard info should be updated with prompt
        XCTAssertTrue(mockContext.updateSessionDashboardInfoCalled)
        XCTAssertEqual(mockContext.lastDashboardPrompt, "Test prompt")
    }

    // MARK: - Skills and Reasoning Tests

    func testSendMessageDisplaysSkillsAsChips() async {
        // Given: Input with skills (already activated server-side)
        mockContext.inputText = "Test"
        let skills = [Skill(name: "test-skill", displayName: "Test Skill", description: "Test", source: .global, tags: nil)]

        // When: Sending message with skills for display
        await coordinator.sendMessage(skills: skills, context: mockContext)

        // Then: Skills should appear as chips on the user message
        let userMessage = mockContext.appendedMessages.first
        XCTAssertEqual(userMessage?.skills?.count, 1)
        XCTAssertEqual(userMessage?.skills?.first?.name, "test-skill")
    }

    func testSendMessagePassesReasoningLevelToServer() async {
        // Given: Input with reasoning level
        mockContext.inputText = "Test"

        // When: Sending message with reasoning level
        await coordinator.sendMessage(reasoningLevel: "high", context: mockContext)

        // Then: Reasoning level should be passed
        XCTAssertEqual(mockContext.lastSentReasoningLevel, "high")
    }

    // MARK: - Draft Clearing Tests

    func testSendMessage_clearsDraftAfterSend() async {
        // Given: A draft store with a saved draft
        let db = EventDatabase()!
        try! await db.initialize()
        try! db.clearAll()
        let store = DraftStore(eventDatabase: db)
        mockContext.draftStore = store

        // Save a draft
        let draftState = InputBarState()
        draftState.text = "draft text"
        store.saveImmediately(sessionId: "test-session", inputBarState: draftState)

        // Verify draft exists
        let checkState = InputBarState()
        XCTAssertTrue(store.loadDraft(sessionId: "test-session", into: checkState))

        // When: Sending a message
        mockContext.inputText = "Test message"
        await coordinator.sendMessage(context: mockContext)

        // Then: Draft should be cleared
        let afterState = InputBarState()
        XCTAssertFalse(store.loadDraft(sessionId: "test-session", into: afterState))

        store.removeAllDraftFiles()
        try? db.clearAll()
        db.close()
    }

    func testSendMessage_clearsDraft_evenOnServerError() async {
        // Given: Draft store and server will fail
        let db = EventDatabase()!
        try! await db.initialize()
        try! db.clearAll()
        let store = DraftStore(eventDatabase: db)
        mockContext.draftStore = store

        let draftState = InputBarState()
        draftState.text = "draft"
        store.saveImmediately(sessionId: "test-session", inputBarState: draftState)

        mockContext.inputText = "Test"
        mockContext.sendPromptShouldFail = true

        // When: Sending message (server fails)
        await coordinator.sendMessage(context: mockContext)

        // Then: Draft should still be cleared (input state was already consumed)
        let afterState = InputBarState()
        XCTAssertFalse(store.loadDraft(sessionId: "test-session", into: afterState))

        store.removeAllDraftFiles()
        try? db.clearAll()
        db.close()
    }

    // MARK: - Error Handling Tests

    func testSendMessageHandlesServerError() async {
        // Given: Server will fail
        mockContext.inputText = "Test"
        mockContext.sendPromptShouldFail = true

        // When: Sending message
        await coordinator.sendMessage(context: mockContext)

        // Then: Error should be handled
        XCTAssertTrue(mockContext.handleAgentErrorCalled)
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

    func testAbortAgentClearsIsPostProcessing() async {
        // Given: Currently in post-processing
        mockContext.isPostProcessing = true

        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: isPostProcessing should be cleared
        XCTAssertFalse(mockContext.isPostProcessing)
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

    func testAbortAgentUpdatesDashboardState() async {
        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: Dashboard should show interrupted
        XCTAssertTrue(mockContext.setSessionProcessingCalled)
        XCTAssertFalse(mockContext.lastSessionProcessingValue ?? true)
        XCTAssertEqual(mockContext.lastDashboardResponse, "Interrupted")
    }

    func testAbortAgentMarksAwaitingSuggestions() async {
        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: Should mark awaiting suggestions so the hook result is accepted
        XCTAssertTrue(mockContext.markAwaitingSuggestionsCalled)
    }

    func testAbortAgentHandlesServerError() async {
        // Given: Server abort will fail
        mockContext.abortShouldFail = true

        // When: Aborting agent
        await coordinator.abortAgent(context: mockContext)

        // Then: Error should be shown
        XCTAssertTrue(mockContext.showErrorAlertCalled)
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
    var markPendingQuestionsAsSupersededCalled = false
    var markPendingConfirmationsAsSupersededCalled = false
    var streamingManagerResetCalled = false
    var setSessionProcessingCalled = false
    var lastSessionProcessingValue: Bool?
    var updateSessionDashboardInfoCalled = false
    var lastDashboardPrompt: String?
    var lastDashboardResponse: String?
    var handleAgentErrorCalled = false
    var abortAgentCalled = false
    var finalizeStreamingMessageCalled = false
    var cancelActiveDeviceRequestsCalled = false
    var showErrorAlertCalled = false

    // MARK: - Test Configuration
    var sendPromptShouldFail = false
    var abortShouldFail = false

    // MARK: - Protocol Methods

    func sendPromptToServer(
        text: String,
        attachments: [FileAttachment]?,
        reasoningLevel: String?
    ) async throws {
        sendPromptCalled = true
        lastSentText = text
        lastSentAttachments = attachments
        lastSentReasoningLevel = reasoningLevel

        if sendPromptShouldFail {
            throw MessagingTestError.serverError
        }
    }

    func activateSkillOnServer(_ skillName: String) async throws {}
    func deactivateSkillOnServer(_ skillName: String) async throws {}
    func castSpellOnServer(_ spellName: String) async throws {}

    func abortAgentOnServer() async throws {
        abortAgentCalled = true
        if abortShouldFail {
            throw MessagingTestError.serverError
        }
    }

    func appendMessage(_ message: ChatMessage) {
        appendedMessages.append(message)
    }

    func appendInterruptedMessage() {
        appendedInterruptedMessage = true
    }

    func markPendingQuestionsAsSuperseded() {
        markPendingQuestionsAsSupersededCalled = true
    }

    func markPendingConfirmationsAsSuperseded() {
        markPendingConfirmationsAsSupersededCalled = true
    }

    func dismissPendingSubagentResults() {
        // No-op for tests
    }

    func finalizeThinkingMessage() {
        // No-op for tests
    }

    func clearThinkingCaption() {
        // No-op for tests
    }

    var markAwaitingSuggestionsCalled = false
    func markAwaitingSuggestions() {
        markAwaitingSuggestionsCalled = true
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

    func updateSessionDashboardInfo(lastUserPrompt: String?, lastAssistantResponse: String?) {
        updateSessionDashboardInfoCalled = true
        lastDashboardPrompt = lastUserPrompt
        lastDashboardResponse = lastAssistantResponse
    }

    func handleAgentError(_ message: String) {
        handleAgentErrorCalled = true
    }

    func showErrorAlert(_ message: String) {
        showErrorAlertCalled = true
    }

    func showError(_ message: String) {
        showErrorAlertCalled = true
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
