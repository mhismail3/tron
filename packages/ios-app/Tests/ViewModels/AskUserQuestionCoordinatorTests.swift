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

    func testPrepareSubmissionStoresPendingPrompt() {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Pending prompt should be stored with formatted content
        XCTAssertNotNil(mockContext.askUserQuestionState.pendingAnswerPrompt)
        XCTAssertTrue(mockContext.askUserQuestionState.pendingAnswerPrompt?.contains("[Answers to your questions]") ?? false)
        XCTAssertTrue(mockContext.askUserQuestionState.pendingAnswerPrompt?.contains("Option A") ?? false)
    }

    func testPrepareSubmissionDoesNotSendPrompt() {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: No prompt should be sent yet (deferred to execute phase)
        XCTAssertNil(mockContext.lastSentPrompt)
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

        // Then: No pending prompt stored
        XCTAssertNil(mockContext.askUserQuestionState.pendingAnswerPrompt)
    }

    func testPrepareSubmissionRejectsNonPendingStatus() {
        // Given: Question is already answered
        mockContext.askUserQuestionState.currentData = createTestToolData(status: .answered)

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Should show error, clear state, no pending prompt
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertNil(mockContext.askUserQuestionState.pendingAnswerPrompt)
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

        // Then: Pending prompt should include the other value
        XCTAssertNotNil(mockContext.askUserQuestionState.pendingAnswerPrompt)
        XCTAssertTrue(mockContext.askUserQuestionState.pendingAnswerPrompt?.contains("[Other]") ?? false)
        XCTAssertTrue(mockContext.askUserQuestionState.pendingAnswerPrompt?.contains("My custom response") ?? false)
    }

    // MARK: - Execute Pending Submission Tests (Phase 2: after sheet dismiss)

    func testExecutePendingSubmissionSendsPrompt() {
        // Given: A pending prompt was stored during prepare
        mockContext.askUserQuestionState.pendingAnswerPrompt = "[Answers to your questions]\n\n**Test?**\nAnswer: Option A\n"

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Prompt should be sent
        XCTAssertNotNil(mockContext.lastSentPrompt)
        XCTAssertTrue(mockContext.lastSentPrompt?.contains("Option A") ?? false)
    }

    func testExecutePendingSubmissionClearsPendingStateAndCurrentData() {
        // Given: A pending prompt and currentData still alive from prepare phase
        mockContext.askUserQuestionState.pendingAnswerPrompt = "some prompt"
        mockContext.askUserQuestionState.currentData = createTestToolData(status: .answered)

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Both pending prompt and currentData should be cleared
        XCTAssertNil(mockContext.askUserQuestionState.pendingAnswerPrompt)
        XCTAssertNil(mockContext.askUserQuestionState.currentData)
    }

    func testExecutePendingSubmissionNoOpWhenNothingPending() {
        // Given: No pending prompt
        mockContext.askUserQuestionState.pendingAnswerPrompt = nil

        // When: Executing pending submission (e.g., swipe dismiss without submit)
        coordinator.executePendingSubmission(context: mockContext)

        // Then: No prompt sent, no crash
        XCTAssertNil(mockContext.lastSentPrompt)
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
        XCTAssertNil(mockContext.lastSentPrompt)
        XCTAssertNotNil(mockContext.askUserQuestionState.pendingAnswerPrompt)

        // Execute (simulates onDismiss callback)
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Prompt should now be sent and pending cleared
        XCTAssertNotNil(mockContext.lastSentPrompt)
        XCTAssertTrue(mockContext.lastSentPrompt?.contains("Option A") ?? false)
        XCTAssertNil(mockContext.askUserQuestionState.pendingAnswerPrompt)
    }

    func testSwipeDismissWithoutSubmitDoesNotTriggerSubmission() {
        // Given: Sheet was opened but user swiped to dismiss (no prepareSubmission called)
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data
        mockContext.askUserQuestionState.showSheet = true

        // When: Execute is called (from onDismiss) without prior prepare
        coordinator.executePendingSubmission(context: mockContext)

        // Then: No prompt sent
        XCTAssertNil(mockContext.lastSentPrompt)
    }

    func testClearAllClearsPendingPrompt() {
        // Given: A pending prompt exists
        mockContext.askUserQuestionState.pendingAnswerPrompt = "pending prompt"

        // When: clearAll is called
        mockContext.askUserQuestionState.clearAll()

        // Then: Pending prompt should be cleared
        XCTAssertNil(mockContext.askUserQuestionState.pendingAnswerPrompt)
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

    // MARK: - Format Answers Tests

    func testFormatAnswersAsPromptSingleAnswer() {
        // Given: A question and answer
        let data = createTestToolData(status: .pending)
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]

        // When: Formatting
        let prompt = coordinator.formatAnswersAsPrompt(data: data, answers: answers)

        // Then: Should contain header and answer
        XCTAssertTrue(prompt.contains("[Answers to your questions]"))
        XCTAssertTrue(prompt.contains("Test question?"))
        XCTAssertTrue(prompt.contains("Option A"))
    }

    func testFormatAnswersAsPromptMultipleSelections() {
        // Given: Answer with multiple selections
        let data = createTestToolData(status: .pending)
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A", "Option B"])]

        // When: Formatting
        let prompt = coordinator.formatAnswersAsPrompt(data: data, answers: answers)

        // Then: Should contain all selected values
        XCTAssertTrue(prompt.contains("Option A, Option B") || prompt.contains("Option B, Option A"))
    }

    func testFormatAnswersAsPromptWithOtherValue() {
        // Given: Answer with other value
        let data = createTestToolData(status: .pending)
        let answers = [AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: [],
            otherValue: "Custom answer"
        )]

        // When: Formatting
        let prompt = coordinator.formatAnswersAsPrompt(data: data, answers: answers)

        // Then: Should include other value with marker
        XCTAssertTrue(prompt.contains("[Other]"))
        XCTAssertTrue(prompt.contains("Custom answer"))
    }

    func testFormatAnswersAsPromptNoSelection() {
        // Given: Answer with no selection
        let data = createTestToolData(status: .pending)
        let answers = [AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: [],
            otherValue: nil
        )]

        // When: Formatting
        let prompt = coordinator.formatAnswersAsPrompt(data: data, answers: answers)

        // Then: Should indicate no selection
        XCTAssertTrue(prompt.contains("(no selection)"))
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

    // MARK: - Tracking for Assertions
    var showErrorCalled = false
    var lastErrorMessage: String?
    var lastSentPrompt: String?

    // MARK: - Protocol Methods

    func showError(_ message: String) {
        showErrorCalled = true
        lastErrorMessage = message
    }

    func sendAnswerPrompt(_ text: String) {
        lastSentPrompt = text
    }

    // MARK: - Logging (no-op for tests)
    func logVerbose(_ message: String) {}
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
