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

    // MARK: - Answer Submission Tests

    func testSubmitAnswersValidatesPendingStatus() async {
        // Given: No current data
        mockContext.askUserQuestionState.currentData = nil

        // When: Submitting answers
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        await coordinator.submitAnswers(answers, context: mockContext)

        // Then: Should not send prompt (no current data)
        XCTAssertNil(mockContext.lastSentPrompt)
    }

    func testSubmitAnswersRejectsNonPendingQuestion() async {
        // Given: Question is already answered
        mockContext.askUserQuestionState.currentData = createTestToolData(status: .answered)

        // When: Submitting answers
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        await coordinator.submitAnswers(answers, context: mockContext)

        // Then: Should show error and not send
        XCTAssertTrue(mockContext.showErrorCalled)
        XCTAssertNil(mockContext.lastSentPrompt)
    }

    func testSubmitAnswersUpdatesMessageToAnswered() async {
        // Given: A pending question with message in context
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data
        mockContext.messages = [
            ChatMessage(role: .assistant, content: .askUserQuestion(data))
        ]

        // When: Submitting answers
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        await coordinator.submitAnswers(answers, context: mockContext)

        // Then: Message should be updated to answered status
        if case .askUserQuestion(let updatedData) = mockContext.messages.first?.content {
            XCTAssertEqual(updatedData.status, .answered)
            XCTAssertNotNil(updatedData.result)
        } else {
            XCTFail("Expected askUserQuestion content")
        }
    }

    func testSubmitAnswersSendsFormattedPrompt() async {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Submitting answers
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["Option A"])]
        await coordinator.submitAnswers(answers, context: mockContext)

        // Then: Formatted prompt should be sent
        XCTAssertNotNil(mockContext.lastSentPrompt)
        XCTAssertTrue(mockContext.lastSentPrompt?.contains("[Answers to your questions]") ?? false)
        XCTAssertTrue(mockContext.lastSentPrompt?.contains("Option A") ?? false)
    }

    func testSubmitAnswersClearsState() async {
        // Given: A pending question with state
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data
        mockContext.askUserQuestionState.showSheet = true
        mockContext.askUserQuestionState.answers["q1"] = createTestAnswer(questionId: "q1", selectedValues: ["A"])

        // When: Submitting answers
        let answers = [createTestAnswer(questionId: "q1", selectedValues: ["A"])]
        await coordinator.submitAnswers(answers, context: mockContext)

        // Then: State should be cleared
        XCTAssertFalse(mockContext.askUserQuestionState.showSheet)
        XCTAssertNil(mockContext.askUserQuestionState.currentData)
        XCTAssertTrue(mockContext.askUserQuestionState.answers.isEmpty)
    }

    func testSubmitAnswersWithOtherValue() async {
        // Given: A pending question
        let data = createTestToolData(status: .pending)
        mockContext.askUserQuestionState.currentData = data

        // When: Submitting answer with "Other" value
        let answers = [AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: [],
            otherValue: "My custom response"
        )]
        await coordinator.submitAnswers(answers, context: mockContext)

        // Then: Prompt should include the other value
        XCTAssertNotNil(mockContext.lastSentPrompt)
        XCTAssertTrue(mockContext.lastSentPrompt?.contains("[Other]") ?? false)
        XCTAssertTrue(mockContext.lastSentPrompt?.contains("My custom response") ?? false)
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
    func logDebug(_ message: String) {}
    func logInfo(_ message: String) {}
    func logWarning(_ message: String) {}
    func logError(_ message: String) {}
}
