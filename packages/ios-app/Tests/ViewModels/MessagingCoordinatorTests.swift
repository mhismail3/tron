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
        try! await db.clearAll()
        let store = DraftStore(eventDatabase: db, documentsURL: FileManager.default.temporaryDirectory)
        mockContext.draftStore = store

        // Save a draft
        let draftState = InputBarState()
        draftState.text = "draft text"
        await store.saveImmediately(sessionId: "test-session", inputBarState: draftState)

        // Verify draft exists
        let checkState = InputBarState()
        let hasDraft = await store.loadDraft(sessionId: "test-session", into: checkState)
        XCTAssertTrue(hasDraft)

        // When: Sending a message
        mockContext.inputText = "Test message"
        await coordinator.sendMessage(context: mockContext)

        // Then: Draft should be cleared
        let afterState = InputBarState()
        let hasDraftAfter = await store.loadDraft(sessionId: "test-session", into: afterState)
        XCTAssertFalse(hasDraftAfter)

        store.removeAllDraftFiles()
        try? await db.clearAll()
        await db.close()
    }

    func testSendMessage_clearsDraft_evenOnServerError() async {
        // Given: Draft store and server will fail
        let db = EventDatabase()!
        try! await db.initialize()
        try! await db.clearAll()
        let store = DraftStore(eventDatabase: db, documentsURL: FileManager.default.temporaryDirectory)
        mockContext.draftStore = store

        let draftState = InputBarState()
        draftState.text = "draft"
        await store.saveImmediately(sessionId: "test-session", inputBarState: draftState)

        mockContext.inputText = "Test"
        mockContext.sendPromptShouldFail = true

        // When: Sending message (server fails)
        await coordinator.sendMessage(context: mockContext)

        // Then: Draft should still be cleared (input state was already consumed)
        let afterState = InputBarState()
        let hasDraftAfter = await store.loadDraft(sessionId: "test-session", into: afterState)
        XCTAssertFalse(hasDraftAfter)

        store.removeAllDraftFiles()
        try? await db.clearAll()
        await db.close()
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

    // MARK: - Draft Skill Management Tests
    //
    // Invariant: chip add/remove in the input bar is purely LOCAL draft state.
    // It must never trigger skills::activate / skills::deactivate engine protocols.
    //
    // Regression guard: eagerly activating a skill on chip-add (e.g. via the
    // "Draft a Plan" menu item) caused a subsequent chip-removal to emit a
    // real skills::deactivated event, which surfaced in the chat transcript as
    // a misleading "plan deactivated from context" pill even though no turn
    // ever ran with the skill. Server activation must happen only at send time.

    func testAddSkillToDraftAppendsToSelectedSkills() {
        // Given: No selected skills
        XCTAssertTrue(mockContext.selectedSkills.isEmpty)

        // When: Adding a skill to the draft
        coordinator.addSkillToDraft(createTestSkill(name: "plan"), context: mockContext)

        // Then: Skill should be in selectedSkills
        XCTAssertEqual(mockContext.selectedSkills.count, 1)
        XCTAssertEqual(mockContext.selectedSkills.first?.name, "plan")
    }

    func testAddSkillToDraftDoesNotActivateOnServer() async {
        // When: Adding a skill to the draft
        coordinator.addSkillToDraft(createTestSkill(name: "plan"), context: mockContext)

        // Then: Server-side activation must NOT be called — activation happens
        // only at send time in MessagingCoordinator.sendMessage / ChatView.onSend.
        XCTAssertEqual(mockContext.activateSkillOnServerCallCount, 0)
    }

    func testAddSkillToDraftIsIdempotent() {
        // Given: A skill already in the draft
        let skill = createTestSkill(name: "plan")
        coordinator.addSkillToDraft(skill, context: mockContext)

        // When: Adding the same skill again
        coordinator.addSkillToDraft(skill, context: mockContext)

        // Then: No duplicate entry
        XCTAssertEqual(mockContext.selectedSkills.count, 1)
        XCTAssertEqual(mockContext.activateSkillOnServerCallCount, 0)
    }

    func testRemoveSkillFromDraftRemovesMatchingSkill() {
        // Given: A skill in the draft
        let skill = createTestSkill(name: "plan")
        mockContext.selectedSkills = [skill]

        // When: Removing the skill from the draft
        coordinator.removeSkillFromDraft(skill, context: mockContext)

        // Then: Skill should be gone
        XCTAssertTrue(mockContext.selectedSkills.isEmpty)
    }

    func testRemoveSkillFromDraftDoesNotDeactivateOnServer() async {
        // Given: A skill in the draft
        let skill = createTestSkill(name: "plan")
        mockContext.selectedSkills = [skill]

        // When: Removing the skill from the draft
        coordinator.removeSkillFromDraft(skill, context: mockContext)

        // Then: Server-side deactivation must NOT be called — chip removal is a
        // draft-state edit, not a "remove from context" action. An explicit
        // remove-from-context gesture (e.g. on SkillDetailSheet) would deactivate,
        // not chip X-tap.
        XCTAssertEqual(mockContext.deactivateSkillOnServerCallCount, 0)
    }

    func testRemoveSkillFromDraftMissingSkillIsNoop() {
        // Given: Empty draft
        XCTAssertTrue(mockContext.selectedSkills.isEmpty)

        // When: Removing a skill that isn't there
        coordinator.removeSkillFromDraft(createTestSkill(name: "plan"), context: mockContext)

        // Then: No crash, no server call, state still empty
        XCTAssertTrue(mockContext.selectedSkills.isEmpty)
        XCTAssertEqual(mockContext.deactivateSkillOnServerCallCount, 0)
    }

    // MARK: - Activate-and-Send (pre-audit #2)

    // Activation of staged skills happens at send time. The three call sites
    // in `ChatView.swift` (share-payload, send-button tap, re-activate chip)
    // previously used `try? await activateSkillOnServer(...)` and ignored
    // failures entirely — the prompt was sent anyway, silently omitting the
    // skill, which is the opposite of user intent. These tests pin the new
    // coordinator-owned behavior: on activation failure, show an error and
    // DO NOT send.

    func testActivateAndSendActivatesAllSkillsInOrderBeforeSending() async {
        // Given: Valid text and two staged skills
        mockContext.inputText = "Do the thing"
        let skills = [createTestSkill(name: "plan"), createTestSkill(name: "review")]

        // When: Activating and sending
        await coordinator.activateAndSend(
            reasoningLevel: nil,
            skills: skills,
            context: mockContext
        )

        // Then: Both skills activated before the prompt was sent
        XCTAssertEqual(mockContext.activateSkillOnServerCallCount, 2)
        XCTAssertEqual(mockContext.activateSkillOnServerNames, ["plan", "review"])
        XCTAssertTrue(mockContext.sendPromptCalled)
        XCTAssertEqual(mockContext.lastSentText, "Do the thing")
        XCTAssertFalse(mockContext.showErrorCalled)
    }

    func testActivateAndSendWithNoSkillsSendsImmediately() async {
        // Given: Valid text and no skills
        mockContext.inputText = "No skills needed"

        // When: Activating and sending with empty skills array
        await coordinator.activateAndSend(
            reasoningLevel: nil,
            skills: [],
            context: mockContext
        )

        // Then: No activation calls, prompt was sent
        XCTAssertEqual(mockContext.activateSkillOnServerCallCount, 0)
        XCTAssertTrue(mockContext.sendPromptCalled)
    }

    func testActivateAndSendActivationFailureSurfacesErrorAndDoesNotSend() async {
        // Given: Valid text, one skill, server-side activation fails
        mockContext.inputText = "Plan this"
        mockContext.activateSkillShouldFail = true
        let skills = [createTestSkill(name: "plan")]

        // When: Activating and sending
        await coordinator.activateAndSend(
            reasoningLevel: nil,
            skills: skills,
            context: mockContext
        )

        // Then: Error surfaced to user; prompt NOT sent (user intent included
        // the skill — silently sending without it would defeat their choice).
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertFalse(mockContext.sendPromptCalled)
        // Staged skills are preserved so the user can retry or edit before
        // re-sending. Wiping the draft on failure would lose their selection.
        XCTAssertFalse(mockContext.inputText.isEmpty)
    }

    func testActivateAndSendFailureHaltsAtFirstError() async {
        // Given: Three skills, activation fails on the second
        mockContext.inputText = "Do the thing"
        mockContext.activateSkillShouldFailOnName = "review"
        let skills = [
            createTestSkill(name: "plan"),
            createTestSkill(name: "review"),
            createTestSkill(name: "test"),
        ]

        // When: Activating and sending
        await coordinator.activateAndSend(
            reasoningLevel: nil,
            skills: skills,
            context: mockContext
        )

        // Then: First succeeded, second failed; third never attempted
        XCTAssertEqual(mockContext.activateSkillOnServerCallCount, 2)
        XCTAssertEqual(mockContext.activateSkillOnServerNames, ["plan", "review"])
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertFalse(mockContext.sendPromptCalled)
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

    private func createTestSkill(name: String) -> Skill {
        return Skill(
            name: name,
            displayName: name,
            description: "\(name) skill",
            source: .global,
            tags: nil,
            scopeDir: nil
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
    var selectedSkills: [Skill] = []
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
    var showErrorCalled = false

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
        sendPromptCalled = true
        lastSentText = text
        lastSentAttachments = attachments
        lastSentReasoningLevel = reasoningLevel

        if sendPromptShouldFail {
            throw MessagingTestError.serverError
        }
    }

    var activateSkillOnServerCallCount = 0
    var activateSkillOnServerNames: [String] = []
    var activateSkillShouldFail = false
    var activateSkillShouldFailOnName: String?
    var deactivateSkillOnServerCallCount = 0

    func activateSkillOnServer(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws {
        activateSkillOnServerCallCount += 1
        activateSkillOnServerNames.append(skillName)
        if activateSkillShouldFail || activateSkillShouldFailOnName == skillName {
            throw MessagingTestError.serverError
        }
    }
    func deactivateSkillOnServer(_ skillName: String, idempotencyKey: EngineIdempotencyKey) async throws {
        deactivateSkillOnServerCallCount += 1
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
