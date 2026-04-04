import XCTest
@testable import TronMobile

@MainActor
final class ThinkingStateTests: XCTestCase {

    // MARK: - Initial State

    func testInitialStateIsEmpty() {
        let state = ThinkingState()
        XCTAssertEqual(state.currentText, "")
        XCTAssertFalse(state.isStreaming)
        XCTAssertTrue(state.blocks.isEmpty)
        XCTAssertFalse(state.showSheet)
        XCTAssertNil(state.selectedBlockId)
        XCTAssertEqual(state.loadedFullContent, "")
        XCTAssertFalse(state.isLoadingContent)
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

    // MARK: - endTurn (Pure -- No DB)

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

    func testEndTurnAppendsBlockToHistory() {
        let state = ThinkingState()
        state.startTurn(1, model: "claude-opus-4-6")
        state.handleThinkingDelta("Some thinking")

        let _ = state.endTurn()

        XCTAssertEqual(state.blocks.count, 1)
        XCTAssertEqual(state.blocks[0].turnNumber, 1)
        XCTAssertEqual(state.blocks[0].model, "claude-opus-4-6")
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

        // currentText persists until cleared by next turn or clearCurrentStreaming
        XCTAssertEqual(state.currentText, "thinking text")
    }

    func testMultipleTurnsAccumulateBlocks() {
        let state = ThinkingState()

        state.startTurn(1, model: "model-a")
        state.handleThinkingDelta("Turn 1 thinking")
        let _ = state.endTurn()

        state.startTurn(2, model: "model-b")
        state.handleThinkingDelta("Turn 2 thinking")
        let _ = state.endTurn()

        XCTAssertEqual(state.blocks.count, 2)
        XCTAssertEqual(state.blocks[0].turnNumber, 1)
        XCTAssertEqual(state.blocks[1].turnNumber, 2)
    }

    func testEndTurnBlockHasCorrectPreviewAndCharCount() {
        let state = ThinkingState()
        state.startTurn(1, model: "test")
        state.handleThinkingDelta("Short content")

        let payload = state.endTurn()

        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.characterCount, "Short content".count)
        XCTAssertEqual(state.blocks[0].characterCount, "Short content".count)
    }

    // MARK: - Caption

    func testCaptionTextTruncatesToThreeLines() {
        let state = ThinkingState()
        state.handleThinkingDelta("Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
        let caption = state.captionText
        XCTAssertFalse(caption.contains("Line 4"))
    }

    func testCaptionTextEmptyWhenNoContent() {
        let state = ThinkingState()
        XCTAssertEqual(state.captionText, "")
    }

    func testShouldShowCaptionWhenHasContent() {
        let state = ThinkingState()
        XCTAssertFalse(state.shouldShowCaption)

        state.handleThinkingDelta("text")
        XCTAssertTrue(state.shouldShowCaption)
    }

    func testHasContentWhenStreamingOrBlocks() {
        let state = ThinkingState()
        XCTAssertFalse(state.hasContent)

        state.handleThinkingDelta("text")
        XCTAssertTrue(state.hasContent)
    }

    // MARK: - Cleanup

    func testClearAllResetsEverything() {
        let state = ThinkingState()
        state.handleThinkingDelta("text")
        state.showSheet = true

        state.clearAll()

        XCTAssertEqual(state.currentText, "")
        XCTAssertFalse(state.isStreaming)
        XCTAssertTrue(state.blocks.isEmpty)
        XCTAssertFalse(state.showSheet)
        XCTAssertNil(state.selectedBlockId)
        XCTAssertEqual(state.loadedFullContent, "")
    }

    func testClearCurrentStreamingResetsTextAndStreaming() {
        let state = ThinkingState()
        state.handleThinkingDelta("text")

        state.clearCurrentStreaming()

        XCTAssertEqual(state.currentText, "")
        XCTAssertFalse(state.isStreaming)
    }

    func testClearSessionClearsBlocksButNotStreaming() {
        let state = ThinkingState()
        state.startTurn(1, model: "m")
        state.handleThinkingDelta("text")
        let _ = state.endTurn()

        state.clearSession()

        XCTAssertTrue(state.blocks.isEmpty)
        XCTAssertNil(state.selectedBlockId)
        XCTAssertEqual(state.loadedFullContent, "")
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

    // MARK: - No Database Dependencies

    func testInitDoesNotRequireDatabase() {
        let state = ThinkingState()
        XCTAssertNotNil(state)
        state.handleThinkingDelta("text")
        let payload = state.endTurn()
        XCTAssertNotNil(payload)
    }

    func testEndTurnReturnsSynchronously() {
        // endTurn is no longer async -- it returns a payload synchronously
        let state = ThinkingState()
        state.startTurn(1, model: "test")
        state.handleThinkingDelta("content")
        let payload = state.endTurn()
        XCTAssertNotNil(payload)
        // If this compiles and runs without await, the test passes
    }
}
