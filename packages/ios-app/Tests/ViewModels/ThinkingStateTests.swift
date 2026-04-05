import XCTest
@testable import TronMobile

@MainActor
final class ThinkingStateTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsEmpty() {
        let state = ThinkingState()
        XCTAssertEqual(state.currentText, "")
        XCTAssertFalse(state.isStreaming)
    }

    // MARK: - Streaming

    func testHandleThinkingDeltaAccumulatesText() {
        let state = ThinkingState()
        state.handleThinkingDelta("Hello ")
        state.handleThinkingDelta("world")
        XCTAssertEqual(state.currentText, "Hello world")
        XCTAssertTrue(state.isStreaming)
    }

    func testStartTurnClearsStreamingState() {
        let state = ThinkingState()
        state.handleThinkingDelta("previous thinking")
        state.startTurn(2, model: "claude-opus-4-6")
        XCTAssertEqual(state.currentText, "")
        XCTAssertFalse(state.isStreaming)
    }

    // MARK: - endTurn

    func testEndTurnWithContentReturnsPayload() {
        let state = ThinkingState()
        state.startTurn(1, model: "claude-opus-4-6")
        state.handleThinkingDelta("Deep thinking about architecture")

        let payload = state.endTurn()

        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.turnNumber, 1)
        XCTAssertEqual(payload?.content, "Deep thinking about architecture")
        XCTAssertEqual(payload?.model, "claude-opus-4-6")
    }

    func testEndTurnWithEmptyContentReturnsNil() {
        let state = ThinkingState()
        state.startTurn(1, model: "claude-opus-4-6")

        let payload = state.endTurn()

        XCTAssertNil(payload)
        XCTAssertFalse(state.isStreaming)
    }

    func testEndTurnSetsStreamingFalse() {
        let state = ThinkingState()
        state.handleThinkingDelta("thinking")

        let _ = state.endTurn()

        XCTAssertFalse(state.isStreaming)
    }

    func testEndTurnPreservesCurrentTextForCaption() {
        let state = ThinkingState()
        state.handleThinkingDelta("thinking text")

        let _ = state.endTurn()

        XCTAssertEqual(state.currentText, "thinking text")
    }

    func testEndTurnReturnsSynchronously() {
        let state = ThinkingState()
        state.startTurn(1, model: "test")
        state.handleThinkingDelta("content")
        let payload = state.endTurn()
        XCTAssertNotNil(payload)
    }

    func testMultipleEndTurnsReturnIndependentPayloads() {
        let state = ThinkingState()

        state.startTurn(1, model: "model-a")
        state.handleThinkingDelta("Turn 1")
        let p1 = state.endTurn()

        state.startTurn(2, model: "model-b")
        state.handleThinkingDelta("Turn 2")
        let p2 = state.endTurn()

        XCTAssertEqual(p1?.turnNumber, 1)
        XCTAssertEqual(p1?.model, "model-a")
        XCTAssertEqual(p2?.turnNumber, 2)
        XCTAssertEqual(p2?.model, "model-b")
    }

    // MARK: - Cleanup

    func testClearCurrentStreamingResetsTextAndStreaming() {
        let state = ThinkingState()
        state.handleThinkingDelta("text")

        state.clearCurrentStreaming()

        XCTAssertEqual(state.currentText, "")
        XCTAssertFalse(state.isStreaming)
    }

    // MARK: - seedCatchUpThinking

    func testSeedCatchUpSetsStateCorrectly() {
        let state = ThinkingState()
        state.seedCatchUpThinking("catch up text", isStreaming: true)
        XCTAssertEqual(state.currentText, "catch up text")
        XCTAssertTrue(state.isStreaming)
    }

    func testSeedCatchUpWithStreamingFalse() {
        let state = ThinkingState()
        state.seedCatchUpThinking("done text", isStreaming: false)
        XCTAssertEqual(state.currentText, "done text")
        XCTAssertFalse(state.isStreaming)
    }

    // MARK: - No Dependencies

    func testInitDoesNotRequireDependencies() {
        let state = ThinkingState()
        XCTAssertNotNil(state)
        state.handleThinkingDelta("text")
        let payload = state.endTurn()
        XCTAssertNotNil(payload)
    }
}
