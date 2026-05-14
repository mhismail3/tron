import XCTest
import UIKit
@testable import TronMobile

/// Tests for UserInteractionCoordinator - handles UserInteraction capability invocation events and user interaction
/// Uses TDD: Tests written first, then implementation follows
@MainActor
final class UserInteractionCoordinatorTests: XCTestCase {

    var coordinator: UserInteractionCoordinator!
    var mockContext: MockUserInteractionContext!

    override func setUp() async throws {
        mockContext = MockUserInteractionContext()
        coordinator = UserInteractionCoordinator()
    }

    override func tearDown() async throws {
        coordinator = nil
        mockContext = nil
    }

    // MARK: - Sheet Management Tests

    func testOpenSheetForPendingQuestion() {
        // Given: A pending UserInteraction capability data
        let data = createTestInteractionData(status: .pending)

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Sheet should be shown with data
        XCTAssertTrue(mockContext.userInteractionState.showSheet)
        XCTAssertNotNil(mockContext.userInteractionState.currentData)
        XCTAssertEqual(mockContext.userInteractionState.currentData?.invocationId, "tc-123")
    }

    func testOpenSheetForAnsweredQuestion() {
        // Given: An answered UserInteraction (for read-only viewing)
        let data = createTestInteractionData(status: .answered)

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Sheet should be shown (read-only mode)
        XCTAssertTrue(mockContext.userInteractionState.showSheet)
        XCTAssertNotNil(mockContext.userInteractionState.currentData)
    }

    func testOpenSheetIgnoresSupersededQuestion() {
        // Given: A superseded UserInteraction
        let data = createTestInteractionData(status: .superseded)

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Sheet should NOT be shown
        XCTAssertFalse(mockContext.userInteractionState.showSheet)
        XCTAssertNil(mockContext.userInteractionState.currentData)
    }

    func testOpenSheetInitializesAnswersFromData() {
        // Given: A pending question with existing partial answers
        var data = createTestInteractionData(status: .pending)
        let existingAnswer = UserInteractionAnswer(
            questionId: "q1",
            selectedValues: ["Option A"],
            otherValue: nil
        )
        data.answers["q1"] = existingAnswer

        // When: Opening sheet
        coordinator.openSheet(for: data, context: mockContext)

        // Then: Answers should be initialized from data
        XCTAssertEqual(mockContext.userInteractionState.answers["q1"]?.selectedValues, ["Option A"])
    }

    func testDismissSheetClearsShowFlag() {
        // Given: Sheet is shown
        mockContext.userInteractionState.showSheet = true

        // When: Dismissing sheet
        coordinator.dismissSheet(context: mockContext)

        // Then: Sheet should be hidden
        XCTAssertFalse(mockContext.userInteractionState.showSheet)
    }

    // MARK: - Prepare Submission Tests (Phase 1: before sheet dismiss)

    func testPrepareSubmissionUpdatesChipToAnswered() {
        // Given: A pending question with message in context
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data
        mockContext.messages = [
            ChatMessage(role: .assistant, content: .userInteraction(data))
        ]

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Message should be updated to answered status
        if case .userInteraction(let updatedData) = mockContext.messages.first?.content {
            XCTAssertEqual(updatedData.status, .answered)
            XCTAssertNotNil(updatedData.result)
        } else {
            XCTFail("Expected userInteraction content")
        }
    }

    func testPrepareSubmissionStoresPendingSubmission() {
        // Given: A pending question
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Pending submission should be stored with structured data
        XCTAssertNotNil(mockContext.userInteractionState.pendingSubmission)
    }

    func testPrepareSubmissionDoesNotSendPrompt() {
        // Given: A pending question
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: No message should be appended yet (deferred to execute phase)
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testPrepareSubmissionClearsSheetStateButKeepsCurrentData() {
        // Given: A pending question with state
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data
        mockContext.userInteractionState.showSheet = true
        mockContext.userInteractionState.answers["q1"] = createTestAnswer(questionId: "q1", selectedValues: ["A"])

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Sheet flag and answers cleared, but currentData kept alive
        // (sheet reads currentData during dismiss animation — clearing it causes white flash)
        XCTAssertFalse(mockContext.userInteractionState.showSheet)
        XCTAssertNotNil(mockContext.userInteractionState.currentData)
        XCTAssertTrue(mockContext.userInteractionState.answers.isEmpty)
    }

    func testPrepareSubmissionSetsQuestionCount() {
        // Given: A pending question
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Question count should be set
        XCTAssertEqual(mockContext.userInteractionState.lastAnsweredQuestionCount, 1)
    }

    func testPrepareSubmissionRejectsNilCurrentData() {
        // Given: No current data
        mockContext.userInteractionState.currentData = nil

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: No pending submission stored
        XCTAssertNil(mockContext.userInteractionState.pendingSubmission)
    }

    func testPrepareSubmissionRejectsNonPendingStatus() {
        // Given: Question is already answered
        mockContext.userInteractionState.currentData = createTestInteractionData(status: .answered)

        // When: Preparing submission
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Should show error, clear state, no pending submission
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertNil(mockContext.userInteractionState.pendingSubmission)
        XCTAssertFalse(mockContext.userInteractionState.showSheet)
    }

    func testPrepareSubmissionWithOtherValue() {
        // Given: A pending question
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data

        // When: Preparing submission with "Other" value
        let answers = [UserInteractionAnswer(
            questionId: "q1",
            selectedValues: [],
            otherValue: "My custom response"
        )]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Then: Pending submission should be stored
        XCTAssertNotNil(mockContext.userInteractionState.pendingSubmission)
    }

    // MARK: - Execute Pending Submission Tests (Phase 2: after sheet dismiss)

    func testExecutePendingSubmissionAppendsAnswerChip() {
        // Given: A pending submission was stored during prepare
        mockContext.userInteractionState.pendingSubmission = [
            AnswerSubmission(id: "q1", question: "Test?", selectedValues: ["Option A"], otherValue: nil)
        ]
        mockContext.userInteractionState.pendingPauseId = "pause-1"
        mockContext.userInteractionState.pendingInvocationId = "tc-123"

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: An answered questions chip should be appended
        XCTAssertFalse(mockContext.appendedMessages.isEmpty)
    }

    func testExecutePendingSubmissionClearsPendingStateAndCurrentData() {
        // Given: A pending submission and currentData still alive from prepare phase
        mockContext.userInteractionState.pendingSubmission = [
            AnswerSubmission(id: "q1", question: "Test?", selectedValues: ["Option A"], otherValue: nil)
        ]
        mockContext.userInteractionState.pendingPauseId = "pause-1"
        mockContext.userInteractionState.pendingInvocationId = "tc-123"
        mockContext.userInteractionState.currentData = createTestInteractionData(status: .answered)

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Both pending submission and currentData should be cleared
        XCTAssertNil(mockContext.userInteractionState.pendingSubmission)
        XCTAssertNil(mockContext.userInteractionState.currentData)
    }

    func testExecutePendingSubmissionNoOpWhenNothingPending() {
        // Given: No pending submission
        mockContext.userInteractionState.pendingSubmission = nil

        // When: Executing pending submission (e.g., swipe dismiss without submit)
        coordinator.executePendingSubmission(context: mockContext)

        // Then: No message appended, no crash
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testExecutePendingSubmissionClearsCorruptPendingStateWithoutAppending() {
        // Given: A pending submission exists without the server pause identity needed to resume it exactly once.
        mockContext.userInteractionState.pendingSubmission = [
            AnswerSubmission(id: "q1", question: "Test?", selectedValues: ["Option A"], otherValue: nil)
        ]
        mockContext.userInteractionState.pendingPauseId = nil
        mockContext.userInteractionState.pendingInvocationId = "tc-123"
        mockContext.userInteractionState.currentData = createTestInteractionData(status: .answered)

        // When: Executing pending submission
        coordinator.executePendingSubmission(context: mockContext)

        // Then: The corrupt state is cleared, the user is told to reconnect, and no answer chip is appended.
        XCTAssertNil(mockContext.userInteractionState.pendingSubmission)
        XCTAssertNil(mockContext.userInteractionState.pendingPauseId)
        XCTAssertNil(mockContext.userInteractionState.pendingInvocationId)
        XCTAssertNil(mockContext.userInteractionState.currentData)
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testFullPrepareAndExecuteFlow() {
        // Given: A pending question with message
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data
        mockContext.messages = [
            ChatMessage(role: .assistant, content: .userInteraction(data))
        ]

        // When: Full two-phase flow (prepare then execute)
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        coordinator.prepareSubmission(answers, context: mockContext)

        // Verify intermediate state: chip updated but no send yet
        if case .userInteraction(let updatedData) = mockContext.messages.first?.content {
            XCTAssertEqual(updatedData.status, .answered)
        }
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
        XCTAssertNotNil(mockContext.userInteractionState.pendingSubmission)

        // Execute (simulates onDismiss callback)
        coordinator.executePendingSubmission(context: mockContext)

        // Then: Message should now be appended and pending cleared
        XCTAssertFalse(mockContext.appendedMessages.isEmpty)
        XCTAssertNil(mockContext.userInteractionState.pendingSubmission)
        XCTAssertNil(mockContext.userInteractionState.pendingPauseId)
        XCTAssertNil(mockContext.userInteractionState.pendingInvocationId)
    }

    func testSwipeDismissWithoutSubmitDoesNotTriggerSubmission() {
        // Given: Sheet was opened but user swiped to dismiss (no prepareSubmission called)
        let data = createTestInteractionData(status: .pending)
        mockContext.userInteractionState.currentData = data
        mockContext.userInteractionState.showSheet = true

        // When: Execute is called (from onDismiss) without prior prepare
        coordinator.executePendingSubmission(context: mockContext)

        // Then: No message appended
        XCTAssertTrue(mockContext.appendedMessages.isEmpty)
    }

    func testClearAllClearsPendingSubmission() {
        // Given: A pending submission exists
        mockContext.userInteractionState.pendingSubmission = [
            AnswerSubmission(id: "q1", question: "Test?", selectedValues: ["A"], otherValue: nil)
        ]
        mockContext.userInteractionState.pendingPauseId = "pause-1"
        mockContext.userInteractionState.pendingInvocationId = "tc-123"

        // When: clearAll is called
        mockContext.userInteractionState.clearAll()

        // Then: Pending submission should be cleared
        XCTAssertNil(mockContext.userInteractionState.pendingSubmission)
        XCTAssertNil(mockContext.userInteractionState.pendingPauseId)
        XCTAssertNil(mockContext.userInteractionState.pendingInvocationId)
    }

    // MARK: - Mark Superseded Tests

    func testMarkPendingQuestionsAsSuperseded() {
        // Given: Multiple messages with pending questions
        let data1 = createTestInteractionData(status: .pending, invocationId: "tc-1")
        let data2 = createTestInteractionData(status: .pending, invocationId: "tc-2")
        let data3 = createTestInteractionData(status: .answered, invocationId: "tc-3")

        mockContext.messages = [
            ChatMessage(role: .assistant, content: .userInteraction(data1)),
            ChatMessage(role: .assistant, content: .userInteraction(data2)),
            ChatMessage(role: .assistant, content: .userInteraction(data3))
        ]

        // When: Marking pending questions as superseded
        coordinator.markPendingQuestionsAsSuperseded(context: mockContext)

        // Then: Pending questions should be superseded, answered should remain
        for message in mockContext.messages {
            if case .userInteraction(let data) = message.content {
                if data.invocationId == "tc-1" || data.invocationId == "tc-2" {
                    XCTAssertEqual(data.status, .superseded)
                } else if data.invocationId == "tc-3" {
                    XCTAssertEqual(data.status, .answered)
                }
            }
        }
    }

    func testMarkPendingQuestionsIgnoresNonUserInteractionMessages() {
        // Given: Mixed message types
        let auqData = createTestInteractionData(status: .pending)
        mockContext.messages = [
            ChatMessage(role: .user, content: .text("Hello")),
            ChatMessage(role: .assistant, content: .userInteraction(auqData)),
            ChatMessage(role: .user, content: .text("World"))
        ]

        // When: Marking pending questions as superseded
        coordinator.markPendingQuestionsAsSuperseded(context: mockContext)

        // Then: Non-interaction messages should be unchanged
        XCTAssertEqual(mockContext.messages.count, 3)
        if case .text(let text) = mockContext.messages[0].content {
            XCTAssertEqual(text, "Hello")
        }
        if case .userInteraction(let data) = mockContext.messages[1].content {
            XCTAssertEqual(data.status, .superseded)
        }
    }

    // MARK: - Helpers

    private func createTestInteractionData(status: UserInteractionStatus, invocationId: String = "tc-123") -> UserInteractionInvocationData {
        let question = UserInteraction(
            id: "q1",
            question: "Test question?",
            options: [
                UserInteractionOption(label: "Option A", value: nil, description: nil),
                UserInteractionOption(label: "Option B", value: nil, description: nil)
            ],
            mode: .single,
            allowOther: nil,
            otherPlaceholder: nil
        )
        let params = UserInteractionParams(questions: [question], context: nil)
        return UserInteractionInvocationData(
            invocationId: invocationId,
            pauseId: "pause-\(invocationId)",
            params: params,
            answers: [:],
            status: status,
            result: nil
        )
    }

    private func createTestAnswer(questionId: String, selectedValues: [String]) -> UserInteractionAnswer {
        return UserInteractionAnswer(
            questionId: questionId,
            selectedValues: selectedValues,
            otherValue: nil
        )
    }
}

// MARK: - Mock Context

/// Mock implementation of UserInteractionContext for testing
@MainActor
final class MockUserInteractionContext: UserInteractionContext {
    // MARK: - State
    let userInteractionState = UserInteractionState()
    var messages: [ChatMessage] = []
    var appendedMessages: [ChatMessage] = []
    var currentTurn: Int = 0

    // MARK: - Tracking for Assertions
    var showErrorCalled = false
    var lastErrorMessage: String?

    let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:0")!)

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
