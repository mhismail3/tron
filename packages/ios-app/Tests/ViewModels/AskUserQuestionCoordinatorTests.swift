import XCTest
import UIKit
@testable import TronMobile

/// Tests for AskUserQuestionCoordinator - handles AskUserQuestion tool events and user interaction
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class AskUserQuestionCoordinatorTests: XCTestCase {

    var coordinator: AskUserQuestionCoordinator!
    var mockContext: MockAskUserQuestionContext!

    override func setUp() async throws {
        mockContext = MockAskUserQuestionContext()
        coordinator = AskUserQuestionCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Sheet Management Tests

    func testOpenSheetForPendingQuestion() {
        // Given: A pending AskUserQuestion tool data
        let data = createTestToolData(status: .pending)

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Sheet should be shown with data
        XCTAssertTrue(mockContext.askUserQuestionState.showSheet)
        XCTAssertNotNil(mockContext.askUserQuestionState.currentData)
        XCTAssertEqual(mockContext.askUserQuestionState.currentData?.toolCallId, "tc-123")
    }

    func testOpenSheetForAnsweredQuestion() {
        // Given: An answered AskUserQuestion (for read-only viewing)
        let data = createTestToolData(status: .answered)

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Sheet should be shown (read-only mode)
        XCTAssertTrue(mockContext.askUserQuestionState.showSheet)
        XCTAssertNotNil(mockContext.askUserQuestionState.currentData)
    }

    func testOpenSheetIgnoresSupersededQuestion() {
        // Given: A superseded AskUserQuestion
        let data = createTestToolData(status: .superseded)

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Sheet should NOT be shown
        XCTAssertFalse(mockContext.askUserQuestionState.showSheet)
        XCTAssertNil(mockContext.askUserQuestionState.currentData)
    }

    func testOpenSheetInitializesAnswersFromData() {
        // Given: A pending question with existing partial answers
        var data = createTestToolData(status: .pending)
        let existingAnswer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["Option A"],
            otherValue: nil
        )
        data.answers["q1"] = existingAnswer

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Answers should be initialized from data
        XCTAssertEqual(mockContext.askUserQuestionState.answers["q1"]?.selectedValues, ["Option A"])
    }

    func testDismissSheetClearsShowFlag() {
        // Given: Sheet is shown
        mockContext.askUserQuestionState.showSheet = true

        // When: Dismissing sheet
        coordinator.dismissSheet(context: mockContext)

        // Then: Sheet should be hidden
        XCTAssertFalse(mockContext.askUserQuestionState.showSheet)
    }

    // MARK: - Prepare Submission Tests (Phase 1: before sheet dismiss)

    func testPrepareSubmissionUpdatesChipToAnswered() {
        // Given: A pending question with message in context
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data
        mockContext.messages = [
            ChatMessage(role: .assistant, content: .askUserQuestion(data))
        ]

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Message should be updated to answered status
        if case .askUserQuestion(let updatedData) = mockContext.messages.first?.content {
            XCTAssertEqual(updatedData.status, .answered)
            XCTAssertNotNil(updatedData.result)
        } else {
            XCTFail("Expected askUserQuestion content")
        }
    }

    func testPrepareSubmissionStoresPendingSubmission() {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Pending submission should be stored with structured data
        XCTAssertNotNil(mockContext.askUserQuestionState.pendingSubmission)
    }

    func testPrepareSubmissionDoesNotSendPrompt() {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: No message should be appended yet (deferred to execute phase)
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testPrepareSubmissionClearsSheetStateButKeepsCurrentData() {
        // Given: A pending question with state
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data
        mockContext.askUserQuestionState.showSheet = true
        mockContext.askUserQuestionState.answers["q1"] = createTestAnswer(questionId: "q1", selectedValues: ["A"])

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Sheet flag and answers cleared, but currentData kept alive
        // (sheet reads currentData during dismiss animation — clearing it causes white flash)
        XCTAssertFalse(mockContext.askUserQuestionState.showSheet)
        XCTAssertNotNil(mockContext.askUserQuestionState.currentData)
        XCTAssertTrue(mockContext.askUserQuestionState.answers.isEmpty)
    }

    func testPrepareSubmissionSetsQuestionCount() {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Question count should be set
        XCTAssertEqual(mockContext.askUserQuestionState.lastAnsweredQuestionCount, 1)
    }

    func testPrepareSubmissionRejectsNilCurrentData() {
        // Given: No current data
        mockContext.askUserQuestionState.currentData = nil

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: No pending submission stored
        XCTAssertNil(mockContext.askUserQuestionState.pendingSubmission)
    }

    func testPrepareSubmissionRejectsNonPendingStatus() {
        // Given: Question is already answered
        mockContext.askUserQuestionState.currentData = createTestToolData(status: .answered)

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Should show error, clear state, no pending submission
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertNil(mockContext.askUserQuestionState.pendingSubmission)
        XCTAssertFalse(mockContext.askUserQuestionState.showSheet)
    }

    func testPrepareSubmissionWithOtherValue() {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Preparing submission with "Other" value
        let answers = [AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: [],
            otherValue: "My custom response"
        )]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Pending submission should be stored
        XCTAssertNotNil(mockContext.askUserQuestionState.pendingSubmission)
    }

    // MARK: - Execute Pending Submission Tests (Phase 2: after sheet dismiss)

    func testExecutePendingSubmissionAppendsAnswerChip() {
        // Given: A pending submission was stored during prepare
        mockContext.askUserQuestionState.pendingSubmission = [
            AnswerSubmission(id: "q1", question: "Test?", selectedValues: ["Option A"], otherValue: nil)
        ]

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: An answered questions chip should be appended
        XCTAssertFalse(mockContext.appendedMessages.isEmpty)
    }

    func testExecutePendingSubmissionClearsPendingStateAndCurrentData() {
        // Given: A pending submission and currentData still alive from prepare phase
        mockContext.askUserQuestionState.pendingSubmission = [
            AnswerSubmission(id: "q1", question: "Test?", selectedValues: ["Option A"], otherValue: nil)
        ]
        mockContext.askUserQuestionState.currentData = createTestToolData(status: .answered)

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Both pending submission and currentData should be cleared
        XCTAssertNil(mockContext.askUserQuestionState.pendingSubmission)
        XCTAssertNil(mockContext.askUserQuestionState.currentData)
    }

    func testExecutePendingSubmissionNoOpWhenNothingPending() {
        // Given: No pending submission
        mockContext.askUserQuestionState.pendingSubmission = nil

        // When: Executing pending submission (e.g., swipe dismiss without submit)
        coordinator.executePendingSubmission(context: mockContext)

        // Then: No message appended, no crash
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testFullPrepareAndExecuteFlow() {
        // Given: A pending question with message
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data
        mockContext.messages = [
            ChatMessage(role: .assistant, content: .askUserQuestion(data))
        ]

        // When: Full two-phase flow (prepare then execute)
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Verify intermediate state: chip updated but no send yet
        if case .askUserQuestion(let updatedData) = mockContext.messages.first?.content {
            XCTAssertEqual(updatedData.status, .answered)
        }
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
        XCTAssertNotNil(mockContext.askUserQuestionState.pendingSubmission)

        // Execute (simulates onDismiss callback)
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Message should now be appended and pending cleared
        XCTAssertFalse(mockContext.appendedMessages.isEmpty)
        XCTAssertNil(mockContext.askUserQuestionState.pendingSubmission)
    }

    func testSwipeDismissWithoutSubmitDoesNotTriggerSubmission() {
        // Given: Sheet was opened but user swiped to dismiss (no prepareSubmission called)
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data
        mockContext.askUserQuestionState.showSheet = true

        // When: Execute is called (from onDismiss) without prior prepare
        coordinator.executePendingSubmission(context: mockContext)

        // Then: No message appended
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testClearAllClearsPendingSubmission() {
        // Given: A pending submission exists
        mockContext.askUserQuestionState.pendingSubmission = [
            AnswerSubmission(id: "q1", question: "Test?", selectedValues: ["A"], otherValue: nil)
        ]

        // When: clearAll is called
        mockContext.askUserQuestionState.clearAll()

        // Then: Pending submission should be cleared
        XCTAssertNil(mockContext.askUserQuestionState.pendingSubmission)
    }

    // MARK: - Mark Superseded Tests

    func testMarkPendingQuestionsAsSuperseded() {
        // Given: Multiple messages with pending questions
        let data1 = createTestToolData(status: .pending, toolCallId: "tc-1")
        let data2 = createTestToolData(status: .pending, toolCallId: "tc-2")
        let data3 = createTestToolData(status: .answered, toolCallId: "tc-3")

        mockContext.messages = [
            ChatMessage(role: .assistant, content: .askUserQuestion(data1)),
            ChatMessage(role: .assistant, content: .askUserQuestion(data2)),
            ChatMessage(role: .assistant, content: .askUserQuestion(data3))
        ]

        // When: Marking pending questions as superseded
        coordinator.markPendingQuestionsAsSuperseded(context: mockContext)

        // Then: Pending questions should be superseded, answered should remain
        for message in mockContext.messages {
            if case .askUserQuestion(let data) = message.content {
                if data.toolCallId == "tc-1" || data.toolCallId == "tc-2" {
                    XCTAssertEqual(data.status, .superseded)
                } else if data.toolCallId == "tc-3" {
                    XCTAssertEqual(data.status, .answered)
                }
            }
        }
    }

    func testMarkPendingQuestionsIgnoresNonAskUserQuestionMessages() {
        // Given: Mixed message types
        let auqData = createTestToolData(status: .pending)
        mockContext.messages = [
            ChatMessage(role: .user, content: .text("Hello")),
            ChatMessage(role: .assistant, content: .askUserQuestion(auqData)),
            ChatMessage(role: .user, content: .text("World"))
        ]

        // When: Marking pending questions as superseded
        coordinator.markPendingQuestionsAsSuperseded(context: mockContext)

        // Then: Non-AUQ messages should be unchanged
        XCTAssertEqual(mockContext.messages.count, 3)
        if case .text(let text) = mockContext.messages[0].content {
            XCTAssertEqual(text, "Hello")
        }
        if case .askUserQuestion(let data) = mockContext.messages[1].content {
            XCTAssertEqual(data.status, .superseded)
        }
    }

    // MARK: - Helpers

    private func createTestToolData(status: AskUserQuestionStatus, toolCallId: String = "tc-123") -> AskUserQuestionToolData {
        let question = AskUserQuestion(
            id: "q1",
            question: "Test question?",
            options: [
                AskUserQuestionOption(label: "Option A", value: nil, description: nil),
                AskUserQuestionOption(label: "Option B", value: nil, description: nil)
            ],
            mode: .single,
            allowOther: nil,
            otherPlaceholder: nil
        )
        let params = AskUserQuestionParams(questions: [question], context: nil)
        return AskUserQuestionToolData(
            toolCallId: toolCallId,
            params: params,
            answers: [:],
            status: status,
            result: nil
        )
    }

    private func createTestAnswer(questionId: String, selectedValues: [String]) -> AskUserQuestionAnswer {
        return AskUserQuestionAnswer(
            questionId: questionId,
            selectedValues: selectedValues,
            otherValue: nil
        )
    }
}

// MARK: - Mock Context

/// Mock implementation of AskUserQuestionContext for testing
@MainActor
final class MockAskUserQuestionContext: AskUserQuestionContext {
    // MARK: - State
    let askUserQuestionState = AskUserQuestionState()
    var messages: [ChatMessage] = []
    var appendedMessages: [ChatMessage] = []
    var currentTurn: Int = 0

    // MARK: - Tracking for Assertions
    var showErrorCalled = false
    var lastErrorMessage: String?

    let rpcClient = RPCClient(serverURL: URL(string: "ws://localhost:0")!)

    // MARK: - Protocol Methods

    func showError(_ message: String) {
        showErrorCalled = true
        lastErrorMessage = message
    }

    func appendMessage(_ message: ChatMessage) {
        appendedMessages.append(message)
    }

    // MARK: - Logging (no-op for tests)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
