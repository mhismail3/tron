import XCTest
@testable import TronMobile

/// Tests for GetConfirmationCoordinator
///
/// Verifies:
/// - Sheet open/dismiss for all statuses
/// - Approve submission with/without note
/// - Deny submission with/without note
/// - Supersede on new user message
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

    func testPrepareApprovalStoresPendingSubmission() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: "Go ahead", context: mockContext)

        XCTAssertTrue(mockContext.getConfirmationState.lastDecisionWasApproval)
        XCTAssertNotNil(mockContext.getConfirmationState.pendingSubmission)
        XCTAssertEqual(mockContext.getConfirmationState.pendingSubmission?.decision, "Approved")
        XCTAssertEqual(mockContext.getConfirmationState.pendingSubmission?.note, "Go ahead")
    }

    func testPrepareDenialStoresPendingSubmission() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.denied, note: "Too risky", context: mockContext)

        XCTAssertFalse(mockContext.getConfirmationState.lastDecisionWasApproval)
        XCTAssertNotNil(mockContext.getConfirmationState.pendingSubmission)
        XCTAssertEqual(mockContext.getConfirmationState.pendingSubmission?.decision, "Denied")
        XCTAssertEqual(mockContext.getConfirmationState.pendingSubmission?.note, "Too risky")
    }

    func testPrepareDoesNotSendPrompt() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: nil, context: mockContext)

        // No message should be appended during prepare phase
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
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

    func testPrepareWithEmptyNoteStoresEmptyNote() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        coordinator.prepareSubmission(.approved, note: "", context: mockContext)

        XCTAssertNotNil(mockContext.getConfirmationState.pendingSubmission)
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

        XCTAssertNil(mockContext.getConfirmationState.pendingSubmission)
    }

    func testPrepareRejectsNonPendingStatus() {
        var data = makeToolData(status: .pending)
        data.status = .superseded
        mockContext.getConfirmationState.currentData = data

        coordinator.prepareSubmission(.approved, note: nil, context: mockContext)

        XCTAssertNil(mockContext.getConfirmationState.pendingSubmission)
        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
    }

    // MARK: - Execute Pending Submission Tests (Phase 2: after sheet dismiss)

    func testExecutePendingAppendsConfirmChip() {
        // Given: A pending submission was stored during prepare
        mockContext.getConfirmationState.pendingSubmission = (action: "Install ffmpeg", decision: "Approved", note: nil)
        mockContext.getConfirmationState.lastDecisionWasApproval = true

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: A confirmed action chip should be appended
        XCTAssertFalse(mockContext.appendedMessages.isEmpty)
    }

    func testExecutePendingClearsPendingStateAndCurrentData() {
        mockContext.getConfirmationState.pendingSubmission = (action: "Install ffmpeg", decision: "Approved", note: nil)
        mockContext.getConfirmationState.currentData = makeToolData(status: .approved)

        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertNil(mockContext.getConfirmationState.pendingSubmission)
        XCTAssertNil(mockContext.getConfirmationState.currentData)
    }

    func testExecutePendingNoOpWhenNothingPending() {
        mockContext.getConfirmationState.pendingSubmission = nil

        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
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
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
        XCTAssertNotNil(mockContext.getConfirmationState.pendingSubmission)

        // Phase 2: Execute (simulates onDismiss)
        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertFalse(mockContext.appendedMessages.isEmpty)
        XCTAssertNil(mockContext.getConfirmationState.pendingSubmission)
    }

    func testSwipeDismissWithoutSubmitDoesNotTrigger() {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        mockContext.getConfirmationState.showSheet = true

        // Execute called from onDismiss without prior prepare
        coordinator.executePendingSubmission(context: mockContext)

        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testClearAllClearsPendingSubmission() {
        mockContext.getConfirmationState.pendingSubmission = (action: "Install ffmpeg", decision: "Approved", note: nil)

        mockContext.getConfirmationState.clearAll()

        XCTAssertNil(mockContext.getConfirmationState.pendingSubmission)
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
    var appendedMessages: [ChatMessage] = []
    var currentTurn: Int = 0
    var errorShown: String?
    var loggedMessages: [String] = []

    let rpcClient = RPCClient()

    func appendMessage(_ message: ChatMessage) {
        appendedMessages.append(message)
    }

    // LoggingContext conformance
    func logInfo(_ message: String) { loggedMessages.append("INFO: \(message)") }
    func logWarning(_ message: String) { loggedMessages.append("WARN: \(message)") }
    func logError(_ message: String) { loggedMessages.append("ERROR: \(message)") }
    func logDebug(_ message: String) { loggedMessages.append("DEBUG: \(message)") }
    func logVerbose(_ message: String) { loggedMessages.append("VERBOSE: \(message)") }
    func showError(_ message: String) { errorShown = message }
}
