import XCTest
@testable import TronMobile

@MainActor
final class AskUserQuestionStateTests: XCTestCase {

    func testShowAskUserQuestionSheet() {
        let state = AskUserQuestionState()
        XCTAssertFalse(state.showSheet)

        state.showSheet = true
        XCTAssertTrue(state.showSheet)
    }

    func testCurrentQuestionData() {
        let state = AskUserQuestionState()
        XCTAssertNil(state.currentData)

        let question = createTestQuestion(id: "q1", question: "Test question?")
        let params = AskUserQuestionParams(questions: [question], context: nil)
        let data = AskUserQuestionToolData(
            toolCallId: "tc-123",
            params: params,
            answers: [:],
            status: .pending
        )

        state.currentData = data
        XCTAssertNotNil(state.currentData)
        XCTAssertEqual(state.currentData?.toolCallId, "tc-123")
    }

    func testAnswersTracking() {
        let state = AskUserQuestionState()
        XCTAssertTrue(state.answers.isEmpty)

        let answer = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["Option A"],
            otherValue: nil
        )
        state.answers["q1"] = answer

        XCTAssertEqual(state.answers.count, 1)
        XCTAssertEqual(state.answers["q1"]?.selectedValues.first, "Option A")
    }

    func testCalledInTurn() {
        let state = AskUserQuestionState()
        XCTAssertFalse(state.calledInTurn)

        state.calledInTurn = true
        XCTAssertTrue(state.calledInTurn)
    }

    func testResetForNewTurn() {
        let state = AskUserQuestionState()
        state.calledInTurn = true

        state.resetForNewTurn()

        XCTAssertFalse(state.calledInTurn)
    }

    func testClearAll() {
        let state = AskUserQuestionState()
        state.showSheet = true
        state.currentData = AskUserQuestionToolData(
            toolCallId: "tc-123",
            params: AskUserQuestionParams(questions: [], context: nil),
            answers: [:],
            status: .pending
        )
        state.answers["q1"] = AskUserQuestionAnswer(
            questionId: "q1",
            selectedValues: ["A"],
            otherValue: nil
        )
        state.calledInTurn = true

        state.clearAll()

        XCTAssertFalse(state.showSheet)
        XCTAssertNil(state.currentData)
        XCTAssertTrue(state.answers.isEmpty)
        XCTAssertFalse(state.calledInTurn)
    }

    // MARK: - Helper Methods

    private func createTestQuestion(id: String, question: String) -> AskUserQuestion {
        return AskUserQuestion(
            id: id,
            question: question,
            options: [],
            mode: .single,
            allowOther: nil,
            otherPlaceholder: nil
        )
    }
}
