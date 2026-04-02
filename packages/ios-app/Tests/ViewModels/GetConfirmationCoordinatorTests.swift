import XCTest
@testable import TronMobile

/// Tests for GetConfirmationCoordinator
///
/// Verifies:
/// - Sheet open/dismiss for all statuses
/// - Approve submission with/without note
/// - Deny submission with/without note
/// - Supersede on new user message
/// - Prompt formatting for agent
/// - Status transitions in message array
/// - Edge cases: stale confirmations, empty notes, double submit
@MainActor
final class GetConfirmationCoordinatorTests: XCTestCase {

    var coordinator: GetConfirmationCoordinator!
    var mockContext: MockGetConfirmationContext!

    override func setUp() async throws {
        coordinator = GetConfirmationCoordinator()
        mockContext = MockGetConfirmationContext()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Sheet Management Tests

    func testOpenSheetForPendingConfirmation() {
        let data = makeToolData(status: .pending)
        coordinator.openSheet(for: data, context: mockContext)

        XCTAssertTrue(mockContext.getConfirmationState.showSheet)
        XCTAssertNotNil(mockContext.getConfirmationState.currentData)
        XCTAssertEqual(mockContext.getConfirmationState.currentData?.toolCallId, "tc-123")
    }

    func testOpenSheetForApprovedConfirmation() {
        let data = makeToolData(status: .approved)
        coordinator.openSheet(for: data, context: mockContext)

        XCTAssertTrue(mockContext.getConfirmationState.showSheet)
    }

    func testOpenSheetForDeniedConfirmation() {
        let data = makeToolData(status: .denied)
        coordinator.openSheet(for: data, context: mockContext)

        XCTAssertTrue(mockContext.getConfirmationState.showSheet)
    }

    func testOpenSheetIgnoresSuperseded() {
        let data = makeToolData(status: .superseded)
        coordinator.openSheet(for: data, context: mockContext)

        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
        XCTAssertNil(mockContext.getConfirmationState.currentData)
    }

    func testOpenSheetIgnoresGenerating() {
        let data = makeToolData(status: .generating)
        coordinator.openSheet(for: data, context: mockContext)

        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
    }

    func testDismissSheet() {
        mockContext.getConfirmationState.showSheet = true
        coordinator.dismissSheet(context: mockContext)

        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
    }

    // MARK: - Prepare Submission Tests (Phase 1: before sheet dismiss)

    func testPrepareApprovalStoresPendingPrompt() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: "Go ahead", context: mockContext)

        XCTAssertTrue(mockContext.getConfirmationState.lastDecisionWasApproval)
        XCTAssertNotNil(mockContext.getConfirmationState.pendingConfirmationPrompt)
        XCTAssertTrue(mockContext.getConfirmationState.pendingConfirmationPrompt?.contains("Decision: Approved") ?? false)
        XCTAssertTrue(mockContext.getConfirmationState.pendingConfirmationPrompt?.contains("Note: Go ahead") ?? false)
    }

    func testPrepareDenialStoresPendingPrompt() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.denied, note: "Too risky", context: mockContext)

        XCTAssertFalse(mockContext.getConfirmationState.lastDecisionWasApproval)
        XCTAssertNotNil(mockContext.getConfirmationState.pendingConfirmationPrompt)
        XCTAssertTrue(mockContext.getConfirmationState.pendingConfirmationPrompt?.contains("Decision: Denied") ?? false)
        XCTAssertTrue(mockContext.getConfirmationState.pendingConfirmationPrompt?.contains("Note: Too risky") ?? false)
    }

    func testPrepareDoesNotSendPrompt() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: nil, context: mockContext)

        // No prompt should be sent during prepare phase
        XCTAssertNil(mockContext.sentPrompt)
    }

    func testPrepareUpdatesChipStatusToApproved() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: nil, context: mockContext)

        if case .getConfirmation(let updatedData) = mockContext.messages[0].content {
            XCTAssertEqual(updatedData.status, .approved)
            XCTAssertEqual(updatedData.decision, .approved)
            XCTAssertNotNil(updatedData.result)
        } else {
            XCTFail("Expected .getConfirmation content")
        }
    }

    func testPrepareUpdatesChipStatusToDenied() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.denied, note: "Nope", context: mockContext)

        if case .getConfirmation(let updatedData) = mockContext.messages[0].content {
            XCTAssertEqual(updatedData.status, .denied)
            XCTAssertEqual(updatedData.decision, .denied)
            XCTAssertEqual(updatedData.note, "Nope")
        } else {
            XCTFail("Expected .getConfirmation content")
        }
    }

    func testPrepareWithEmptyNoteOmitsNoteLine() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: "", context: mockContext)

        XCTAssertFalse(mockContext.getConfirmationState.pendingConfirmationPrompt?.contains("Note:") ?? true)
    }

    func testPrepareClearsSheetFlagButKeepsCurrentData() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        mockContext.getConfirmationState.showSheet = true
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: nil, context: mockContext)

        // Sheet flag cleared, but currentData kept alive for dismiss animation
        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
        XCTAssertNotNil(mockContext.getConfirmationState.currentData)
    }

    func testPrepareRejectsNilCurrentData() {
        // currentData is nil
        coordinator.prepareSubmission(.approved, note: nil, context: mockContext)

        XCTAssertNil(mockContext.getConfirmationState.pendingConfirmationPrompt)
    }

    func testPrepareRejectsNonPendingStatus() {
        var data = makeToolData(status: .pending)
        data.status = .superseded
        mockContext.getConfirmationState.currentData = data

        coordinator.prepareSubmission(.approved, note: nil, context: mockContext)

        XCTAssertNil(mockContext.getConfirmationState.pendingConfirmationPrompt)
        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
    }

    // MARK: - Execute Pending Submission Tests (Phase 2: after sheet dismiss)

    func testExecutePendingSendsPendingPrompt() {
        // Given: A pending prompt was stored during prepare
        mockContext.getConfirmationState.pendingConfirmationPrompt = "[Confirmation]\nDecision: Approved"

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Prompt should be sent
        XCTAssertNotNil(mockContext.sentPrompt)
        XCTAssertTrue(mockContext.sentPrompt?.contains("Decision: Approved") ?? false)
    }

    func testExecutePendingClearsPendingStateAndCurrentData() {
        mockContext.getConfirmationState.pendingConfirmationPrompt = "some prompt"
        mockContext.getConfirmationState.currentData = makeToolData(status: .approved)

        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertNil(mockContext.getConfirmationState.pendingConfirmationPrompt)
        XCTAssertNil(mockContext.getConfirmationState.currentData)
    }

    func testExecutePendingNoOpWhenNothingPending() {
        mockContext.getConfirmationState.pendingConfirmationPrompt = nil

        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertNil(mockContext.sentPrompt)
    }

    func testFullPrepareAndExecuteFlow() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        // Phase 1: Prepare
        coordinator.prepareSubmission(.approved, note: "LGTM", context: mockContext)

        // Verify intermediate: chip updated, no send yet
        if case .getConfirmation(let updatedData) = mockContext.messages[0].content {
            XCTAssertEqual(updatedData.status, .approved)
        }
        XCTAssertNil(mockContext.sentPrompt)
        XCTAssertNotNil(mockContext.getConfirmationState.pendingConfirmationPrompt)

        // Phase 2: Execute (simulates onDismiss)
        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertNotNil(mockContext.sentPrompt)
        XCTAssertTrue(mockContext.sentPrompt?.contains("Decision: Approved") ?? false)
        XCTAssertNil(mockContext.getConfirmationState.pendingConfirmationPrompt)
    }

    func testSwipeDismissWithoutSubmitDoesNotTrigger() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        mockContext.getConfirmationState.showSheet = true

        // Execute called from onDismiss without prior prepare
        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertNil(mockContext.sentPrompt)
    }

    func testClearAllClearsPendingPrompt() {
        mockContext.getConfirmationState.pendingConfirmationPrompt = "pending"

        mockContext.getConfirmationState.clearAll()

        XCTAssertNil(mockContext.getConfirmationState.pendingConfirmationPrompt)
    }

    // MARK: - Supersede Tests

    func testMarkPendingAsSuperseded() {
        let data1 = makeToolData(toolCallId: "tc-1", status: .pending)
        let data2 = makeToolData(toolCallId: "tc-2", status: .approved)
        let data3 = makeToolData(toolCallId: "tc-3", status: .pending)

        mockContext.messages = [
            ChatMessage(role: .assistant, content: .getConfirmation(data1)),
            ChatMessage(role: .assistant, content: .getConfirmation(data2)),
            ChatMessage(role: .assistant, content: .getConfirmation(data3)),
        ]

        coordinator.markPendingConfirmationsAsSuperseded(context: mockContext)

        // Only pending ones should be superseded
        if case .getConfirmation(let d1) = mockContext.messages[0].content {
            XCTAssertEqual(d1.status, .superseded)
        } else { XCTFail() }

        if case .getConfirmation(let d2) = mockContext.messages[1].content {
            XCTAssertEqual(d2.status, .approved) // unchanged
        } else { XCTFail() }

        if case .getConfirmation(let d3) = mockContext.messages[2].content {
            XCTAssertEqual(d3.status, .superseded)
        } else { XCTFail() }
    }

    func testMarkSupersedeLeavesOtherMessagesAlone() {
        let textMessage = ChatMessage(role: .user, content: .text("hello"))
        mockContext.messages = [textMessage]

        coordinator.markPendingConfirmationsAsSuperseded(context: mockContext)

        if case .text(let text) = mockContext.messages[0].content {
            XCTAssertEqual(text, "hello")
        } else { XCTFail() }
    }

    // MARK: - Prompt Formatting Tests

    func testFormatApprovedPromptWithNote() {
        let data = makeToolData(status: .pending)
        let prompt = coordinator.formatDecisionAsPrompt(data: data, decision: .approved, note: "Go ahead")

        XCTAssertTrue(prompt.hasPrefix(AgentProtocol.confirmationAnswerPrefix))
        XCTAssertTrue(prompt.contains("Action: Install ffmpeg"))
        XCTAssertTrue(prompt.contains("Decision: Approved"))
        XCTAssertTrue(prompt.contains("Note: Go ahead"))
    }

    func testFormatDeniedPromptWithoutNote() {
        let data = makeToolData(status: .pending)
        let prompt = coordinator.formatDecisionAsPrompt(data: data, decision: .denied, note: nil)

        XCTAssertTrue(prompt.hasPrefix(AgentProtocol.confirmationAnswerPrefix))
        XCTAssertTrue(prompt.contains("Decision: Denied"))
        XCTAssertFalse(prompt.contains("Note:"))
    }

    func testFormatPromptRoundTripsWithDetector() {
        let data = makeToolData(status: .pending)
        let prompt = coordinator.formatDecisionAsPrompt(data: data, decision: .approved, note: "LGTM")

        // The detector should be able to parse this
        let parsed = GetConfirmationDetector.parseConfirmationResponse(from: prompt)
        XCTAssertEqual(parsed.decision, .approved)
        XCTAssertEqual(parsed.note, "LGTM")
    }

    func testFormatPromptRoundTripsForDenied() {
        let data = makeToolData(status: .pending)
        let prompt = coordinator.formatDecisionAsPrompt(data: data, decision: .denied, note: nil)

        let parsed = GetConfirmationDetector.parseConfirmationResponse(from: prompt)
        XCTAssertEqual(parsed.decision, .denied)
        XCTAssertNil(parsed.note)
    }

    // MARK: - Helpers

    private func makeToolData(
        toolCallId: String = "tc-123",
        status: GetConfirmationStatus = .pending
    ) -> GetConfirmationToolData {
        GetConfirmationToolData(
            toolCallId: toolCallId,
            params: GetConfirmationParams(
                action: "Install ffmpeg",
                reason: "Needed for video processing",
                riskLevel: .low
            ),
            status: status
        )
    }

    private func addConfirmationMessage(data: GetConfirmationToolData) {
        mockContext.messages.append(
            ChatMessage(role: .assistant, content: .getConfirmation(data))
        )
    }
}

// MARK: - Mock Context

@MainActor
final class MockGetConfirmationContext: GetConfirmationContext {
    let getConfirmationState = GetConfirmationState()
    var messages: [ChatMessage] = []
    var sentPrompt: String?
    var errorShown: String?
    var loggedMessages: [String] = []

    func sendConfirmationPrompt(_ text: String) {
        sentPrompt = text
    }

    // LoggingContext conformance
    func logInfo(_ message: String) { loggedMessages.append("INFO: \(message)") }
    func logWarning(_ message: String) { loggedMessages.append("WARN: \(message)") }
    func logError(_ message: String) { loggedMessages.append("ERROR: \(message)") }
    func logDebug(_ message: String) { loggedMessages.append("DEBUG: \(message)") }
    func logVerbose(_ message: String) { loggedMessages.append("VERBOSE: \(message)") }
    func showError(_ message: String) { errorShown = message }
}
