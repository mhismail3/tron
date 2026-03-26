import XCTest
@testable import TronMobile

/// Tests for GetConfirmationState
@MainActor
final class GetConfirmationStateTests: XCTestCase {

    func testInitialState() {
        let state = GetConfirmationState()

        XCTAssertFalse(state.showSheet)
        XCTAssertNil(state.currentData)
        XCTAssertFalse(state.calledInTurn)
        XCTAssertFalse(state.lastDecisionWasApproval)
    }

    func testResetForNewTurn() {
        let state = GetConfirmationState()
        state.calledInTurn = true

        state.resetForNewTurn()

        XCTAssertFalse(state.calledInTurn)
    }

    func testResetForNewTurnDoesNotAffectSheet() {
        let state = GetConfirmationState()
        state.showSheet = true
        state.currentData = GetConfirmationToolData(
            toolCallId: "tc-1",
            params: GetConfirmationParams(action: "Test", reason: "Test", riskLevel: .low),
            status: .pending
        )

        state.resetForNewTurn()

        // Sheet state should not be cleared by turn reset
        XCTAssertTrue(state.showSheet)
        XCTAssertNotNil(state.currentData)
    }

    func testClearAll() {
        let state = GetConfirmationState()
        state.showSheet = true
        state.currentData = GetConfirmationToolData(
            toolCallId: "tc-1",
            params: GetConfirmationParams(action: "Test", reason: "Test", riskLevel: .low),
            status: .pending
        )
        state.calledInTurn = true

        state.clearAll()

        XCTAssertFalse(state.showSheet)
        XCTAssertNil(state.currentData)
        XCTAssertFalse(state.calledInTurn)
    }
}
