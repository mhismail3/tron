import Testing
import Foundation
@testable import TronMobile

/// Tests for ThinkingDetailState — content resolution and auto-scroll state machine
/// for the thinking detail sheet's dual-mode (streaming vs static) display.
@Suite("ThinkingDetailState Tests")
@MainActor
struct ThinkingDetailStateTests {

    // MARK: - Content Resolution: Streaming Active

    @Test("When streaming, displayContent returns thinkingState.currentText")
    func testDisplayContentDuringStreaming() {
        let thinking = ThinkingState()
        thinking.handleThinkingDelta("Analyzing the problem...")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "snapshot")

        #expect(state.displayContent == "Analyzing the problem...")
    }

    @Test("displayContent updates as thinkingState.currentText grows")
    func testDisplayContentGrowsWithDeltas() {
        let thinking = ThinkingState()
        thinking.handleThinkingDelta("First ")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "snapshot")

        #expect(state.displayContent == "First ")

        thinking.handleThinkingDelta("second ")
        #expect(state.displayContent == "First second ")

        thinking.handleThinkingDelta("third")
        #expect(state.displayContent == "First second third")
    }

    @Test("isActivelyStreaming reflects thinkingState.isStreaming")
    func testIsActivelyStreaming() {
        let thinking = ThinkingState()
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(!state.isActivelyStreaming)

        thinking.handleThinkingDelta("delta")
        #expect(state.isActivelyStreaming)
    }

    // MARK: - Content Resolution: Streaming Ended (Same Turn)

    @Test("When not streaming but currentText non-empty, displayContent returns currentText")
    func testDisplayContentAfterStreamingEndsSameTurn() {
        let thinking = ThinkingState()
        thinking.startTurn(1, model: "claude-opus-4-6")
        thinking.handleThinkingDelta("Complete thought about architecture")
        let _ = thinking.endTurn()

        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "old snapshot")

        // endTurn() preserves currentText, so displayContent should use it
        #expect(state.displayContent == "Complete thought about architecture")
        #expect(!state.isActivelyStreaming)
    }

    // MARK: - Content Resolution: Historical / Cleared State

    @Test("When not streaming and currentText empty, displayContent returns staticContent")
    func testDisplayContentFallsBackToStaticContent() {
        let thinking = ThinkingState()
        // Simulate: new turn started, clearing previous thinking
        thinking.startTurn(2, model: "claude-opus-4-6")

        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "historical thinking content")

        #expect(state.displayContent == "historical thinking content")
    }

    // MARK: - Content Transition Edge Cases

    @Test("Streaming ends while observing: displayContent preserves final text")
    func testStreamingEndsWhileObserving() {
        let thinking = ThinkingState()
        thinking.startTurn(1, model: "claude-opus-4-6")
        thinking.handleThinkingDelta("Growing ")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "snapshot")

        #expect(state.isActivelyStreaming)
        #expect(state.displayContent == "Growing ")

        thinking.handleThinkingDelta("text here")
        #expect(state.displayContent == "Growing text here")

        // Turn ends — streaming stops but text preserved
        let _ = thinking.endTurn()

        #expect(!state.isActivelyStreaming)
        #expect(state.displayContent == "Growing text here")
    }

    @Test("New turn starts while observing: falls back to staticContent")
    func testNewTurnStartsFallsBackToStatic() {
        let thinking = ThinkingState()
        thinking.startTurn(1, model: "claude-opus-4-6")
        thinking.handleThinkingDelta("Turn 1 thinking")
        let _ = thinking.endTurn()

        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "Turn 1 snapshot")
        #expect(state.displayContent == "Turn 1 thinking")

        // New turn starts — clears currentText
        thinking.startTurn(2, model: "claude-opus-4-6")

        #expect(state.displayContent == "Turn 1 snapshot")
    }

    @Test("clearCurrentStreaming falls back to staticContent")
    func testClearCurrentStreamingFallback() {
        let thinking = ThinkingState()
        thinking.handleThinkingDelta("Interrupted thinking")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "pre-error snapshot")

        #expect(state.displayContent == "Interrupted thinking")

        // Error clears streaming state
        thinking.clearCurrentStreaming()

        #expect(state.displayContent == "pre-error snapshot")
        #expect(!state.isActivelyStreaming)
    }

    @Test("Empty staticContent with empty currentText returns empty string")
    func testBothSourcesEmpty() {
        let thinking = ThinkingState()
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(state.displayContent == "")
    }

    @Test("Catch-up seeding: seedCatchUpThinking populates displayContent")
    func testCatchUpSeeding() {
        let thinking = ThinkingState()
        thinking.seedCatchUpThinking("Reconnected thinking content", isStreaming: true)
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "old")

        #expect(state.displayContent == "Reconnected thinking content")
        #expect(state.isActivelyStreaming)
    }

    @Test("Catch-up seeding with isStreaming false uses currentText")
    func testCatchUpSeedingNotStreaming() {
        let thinking = ThinkingState()
        thinking.seedCatchUpThinking("Completed catch-up", isStreaming: false)
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "old")

        #expect(state.displayContent == "Completed catch-up")
        #expect(!state.isActivelyStreaming)
    }

    // MARK: - Auto-Scroll State Machine

    @Test("Initial state: autoScrollEnabled is true")
    func testInitialAutoScrollEnabled() {
        let thinking = ThinkingState()
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(state.autoScrollEnabled)
    }

    @Test("userDidScroll disables auto-scroll")
    func testUserDidScrollDisables() {
        let thinking = ThinkingState()
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        state.userDidScroll()

        #expect(!state.autoScrollEnabled)
    }

    @Test("userReturnedToBottom re-enables auto-scroll")
    func testUserReturnedToBottomEnables() {
        let thinking = ThinkingState()
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        state.userDidScroll()
        #expect(!state.autoScrollEnabled)

        state.userReturnedToBottom()
        #expect(state.autoScrollEnabled)
    }

    @Test("userDidScroll then userReturnedToBottom: auto-scroll restored")
    func testScrollAwayAndBack() {
        let thinking = ThinkingState()
        thinking.handleThinkingDelta("streaming content")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(state.shouldAutoScroll)

        state.userDidScroll()
        #expect(!state.shouldAutoScroll)

        state.userReturnedToBottom()
        #expect(state.shouldAutoScroll)
    }

    @Test("Multiple userDidScroll calls are idempotent")
    func testMultipleUserDidScrollIdempotent() {
        let thinking = ThinkingState()
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        state.userDidScroll()
        state.userDidScroll()
        state.userDidScroll()

        #expect(!state.autoScrollEnabled)

        // Single return re-enables
        state.userReturnedToBottom()
        #expect(state.autoScrollEnabled)
    }

    @Test("shouldAutoScroll returns true when enabled and streaming")
    func testShouldAutoScrollWhenStreaming() {
        let thinking = ThinkingState()
        thinking.handleThinkingDelta("active streaming")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(state.shouldAutoScroll)
    }

    @Test("shouldAutoScroll returns false when enabled but not streaming")
    func testShouldAutoScrollFalseWhenNotStreaming() {
        let thinking = ThinkingState()
        // Not streaming — no deltas sent
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "static")

        #expect(!state.shouldAutoScroll)
    }

    @Test("shouldAutoScroll returns false when disabled even if streaming")
    func testShouldAutoScrollFalseWhenDisabled() {
        let thinking = ThinkingState()
        thinking.handleThinkingDelta("streaming")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        state.userDidScroll()

        #expect(!state.shouldAutoScroll)
    }

    @Test("Streaming ends: shouldAutoScroll becomes false")
    func testShouldAutoScrollFalseAfterStreamingEnds() {
        let thinking = ThinkingState()
        thinking.startTurn(1, model: "test")
        thinking.handleThinkingDelta("thinking")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(state.shouldAutoScroll)

        let _ = thinking.endTurn()

        #expect(!state.shouldAutoScroll)
    }

    // MARK: - Streaming Indicator

    @Test("showStreamingIndicator is true when actively streaming")
    func testShowStreamingIndicatorTrue() {
        let thinking = ThinkingState()
        thinking.handleThinkingDelta("delta")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(state.showStreamingIndicator)
    }

    @Test("showStreamingIndicator is false when not streaming")
    func testShowStreamingIndicatorFalse() {
        let thinking = ThinkingState()
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "content")

        #expect(!state.showStreamingIndicator)
    }

    @Test("showStreamingIndicator transitions from true to false on endTurn")
    func testShowStreamingIndicatorTransition() {
        let thinking = ThinkingState()
        thinking.startTurn(1, model: "test")
        thinking.handleThinkingDelta("content")
        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "")

        #expect(state.showStreamingIndicator)

        let _ = thinking.endTurn()

        #expect(!state.showStreamingIndicator)
    }

    // MARK: - Full Lifecycle Scenario

    @Test("Full lifecycle: stream → scroll away → scroll back → end → new turn")
    func testFullLifecycle() {
        let thinking = ThinkingState()
        thinking.startTurn(1, model: "claude-opus-4-6")
        thinking.handleThinkingDelta("Step 1: ")

        let state = ThinkingDetailState(thinkingState: thinking, staticContent: "snapshot of turn 1")

        // Phase 1: Streaming, auto-scroll active
        #expect(state.displayContent == "Step 1: ")
        #expect(state.isActivelyStreaming)
        #expect(state.shouldAutoScroll)
        #expect(state.showStreamingIndicator)

        // Phase 2: More deltas arrive
        thinking.handleThinkingDelta("Analyze. Step 2: ")
        #expect(state.displayContent == "Step 1: Analyze. Step 2: ")

        // Phase 3: User scrolls up to read earlier content
        state.userDidScroll()
        #expect(!state.shouldAutoScroll)
        #expect(state.displayContent == "Step 1: Analyze. Step 2: ") // content still updates
        thinking.handleThinkingDelta("Verify.")
        #expect(state.displayContent == "Step 1: Analyze. Step 2: Verify.")

        // Phase 4: User scrolls back to bottom
        state.userReturnedToBottom()
        #expect(state.shouldAutoScroll)

        // Phase 5: Streaming ends
        let _ = thinking.endTurn()
        #expect(!state.isActivelyStreaming)
        #expect(!state.shouldAutoScroll) // no more content coming
        #expect(!state.showStreamingIndicator)
        #expect(state.displayContent == "Step 1: Analyze. Step 2: Verify.")

        // Phase 6: New turn starts (e.g., user sends another message)
        thinking.startTurn(2, model: "claude-opus-4-6")
        #expect(state.displayContent == "snapshot of turn 1") // falls back to static
    }
}
