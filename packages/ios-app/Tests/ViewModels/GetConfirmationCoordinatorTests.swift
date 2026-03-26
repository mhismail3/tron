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

    // MARK: - Decision Submission Tests

    func testSubmitApproveWithNote() async {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        await coordinator.submitDecision(.approved, note: "Go ahead", context: mockContext)

        XCTAssertTrue(mockContext.getConfirmationState.lastDecisionWasApproval)
        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
        XCTAssertNil(mockContext.getConfirmationState.currentData)
        XCTAssertTrue(mockContext.sentPrompt?.contains("Decision: Approved") ?? false)
        XCTAssertTrue(mockContext.sentPrompt?.contains("Note: Go ahead") ?? false)
    }

    func testSubmitDenyWithNote() async {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        await coordinator.submitDecision(.denied, note: "Too risky", context: mockContext)

        XCTAssertFalse(mockContext.getConfirmationState.lastDecisionWasApproval)
        XCTAssertTrue(mockContext.sentPrompt?.contains("Decision: Denied") ?? false)
        XCTAssertTrue(mockContext.sentPrompt?.contains("Note: Too risky") ?? false)
    }

    func testSubmitApproveWithoutNote() async {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        await coordinator.submitDecision(.approved, note: nil, context: mockContext)

        XCTAssertTrue(mockContext.sentPrompt?.contains("Decision: Approved") ?? false)
        XCTAssertFalse(mockContext.sentPrompt?.contains("Note:") ?? true)
    }

    func testSubmitWithEmptyNoteOmitsNoteLine() async {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        await coordinator.submitDecision(.approved, note: "", context: mockContext)

        XCTAssertFalse(mockContext.sentPrompt?.contains("Note:") ?? true)
    }

    func testSubmitUpdatesChipStatusToApproved() async {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        await coordinator.submitDecision(.approved, note: nil, context: mockContext)

        if case .getConfirmation(let updatedData) = mockContext.messages[0].content {
            XCTAssertEqual(updatedData.status, .approved)
            XCTAssertEqual(updatedData.decision, .approved)
            XCTAssertNotNil(updatedData.result)
        } else {
            XCTFail("Expected .getConfirmation content")
        }
    }

    func testSubmitUpdatesChipStatusToDenied() async {
        let data = makeToolData(status: .pending)
        mockContext.getConfirmationState.currentData = data
        addConfirmationMessage(data: data)

        await coordinator.submitDecision(.denied, note: "Nope", context: mockContext)

        if case .getConfirmation(let updatedData) = mockContext.messages[0].content {
            XCTAssertEqual(updatedData.status, .denied)
            XCTAssertEqual(updatedData.decision, .denied)
            XCTAssertEqual(updatedData.note, "Nope")
        } else {
            XCTFail("Expected .getConfirmation content")
        }
    }

    func testSubmitFailsForNoCurrentData() async {
        // currentData is nil
        await coordinator.submitDecision(.approved, note: nil, context: mockContext)
        XCTAssertNil(mockContext.sentPrompt)
    }

    func testSubmitFailsForSupersededConfirmation() async {
        var data = makeToolData(status: .pending)
        data.status = .superseded
        mockContext.getConfirmationState.currentData = data

        await coordinator.submitDecision(.approved, note: nil, context: mockContext)

        XCTAssertNil(mockContext.sentPrompt)
        XCTAssertFalse(mockContext.getConfirmationState.showSheet)
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
