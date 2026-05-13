import XCTest
@testable import TronMobile

@MainActor
final class UserInteractionStateTests: XCTestCase {

    func testShowUserInteractionSheet() {
        let state = UserInteractionState()
        XCTAssertFalse(state.showSheet)

        state.showSheet = true
        XCTAssertTrue(state.showSheet)
    }

    func testCurrentQuestionData() {
        let state = UserInteractionState()
        XCTAssertNil(state.currentData)

        let question = createTestQuestion(id: "q1", question: "Test question?")
        let params = UserInteractionParams(questions: [question], context: nil)
        let data = UserInteractionInvocationData(
            invocationId: "tc-123",
            params: params,
            answers: [:],
            status: .pending
        )

        state.currentData = data
        XCTAssertNotNil(state.currentData)
        XCTAssertEqual(state.currentData?.invocationId, "tc-123")
    }

    func testAnswersTracking() {
        let state = UserInteractionState()
        XCTAssertTrue(state.answers.isEmpty)

        let answer = UserInteractionAnswer(
            questionId: "q1",
            selectedValues: ["Option A"],
            otherValue: nil
        )
        state.answers["q1"] = answer

        XCTAssertEqual(state.answers.count, 1)
        XCTAssertEqual(state.answers["q1"]?.selectedValues.first, "Option A")
    }

    func testCalledInTurn() {
        let state = UserInteractionState()
        XCTAssertFalse(state.calledInTurn)

        state.calledInTurn = true
        XCTAssertTrue(state.calledInTurn)
    }

    func testResetForNewTurn() {
        let state = UserInteractionState()
        state.calledInTurn = true

        state.resetForNewTurn()

        XCTAssertFalse(state.calledInTurn)
    }

    func testClearAll() {
        let state = UserInteractionState()
        state.showSheet = true
        state.currentData = UserInteractionInvocationData(
            invocationId: "tc-123",
            params: UserInteractionParams(questions: [], context: nil),
            answers: [:],
            status: .pending
        )
        state.answers["q1"] = UserInteractionAnswer(
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

    private func createTestQuestion(id: String, question: String) -> UserInteraction {
        return UserInteraction(
            id: id,
            question: question,
            options: [],
            mode: .single,
            allowOther: nil,
            otherPlaceholder: nil
        )
    }
}
