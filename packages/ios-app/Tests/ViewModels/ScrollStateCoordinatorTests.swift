import Testing
import Foundation
import SwiftUI
@testable import TronMobile

/// Tests for ScrollStateCoordinator — phase-based scroll detection
@Suite("ScrollStateCoordinator Tests")
@MainActor
struct ScrollStateCoordinatorTests {

    // MARK: - Initial State

    @Test("Initial state: at bottom, not scrolled away, should auto-scroll")
    func testInitialState() {
        let coordinator = ScrollStateCoordinator()

        #expect(coordinator.isAtBottom)
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
        #expect(!coordinator.shouldShowNewContentPill)
    }

    // MARK: - Geometry Updates (no user interaction)

    @Test("Geometry not near bottom without user interaction does not set userScrolledAway")
    func testGeometryNotNearBottomWithoutInteraction() {
        let coordinator = ScrollStateCoordinator()

        coordinator.geometryChanged(isNearBottom: false)

        #expect(!coordinator.isAtBottom)
        // No user interaction → userScrolledAway stays false
        // (This is the key fix: content growth doesn't trigger the pill)
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Geometry near bottom clears userScrolledAway")
    func testGeometryNearBottomClearsFlag() {
        let coordinator = ScrollStateCoordinator()

        // Simulate user having scrolled away previously
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.userScrolledAway)

        // Now geometry reports near bottom (e.g. user scrolled back)
        coordinator.geometryChanged(isNearBottom: true)

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    // MARK: - User Scroll Detection (phase + geometry)

    @Test("User drag away from bottom sets userScrolledAway")
    func testUserDragSetsScrolledAway() {
        let coordinator = ScrollStateCoordinator()

        // User starts dragging
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        // Geometry reports not near bottom while user is interacting
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
        #expect(coordinator.shouldShowNewContentPill)
    }

    @Test("User drag near bottom does not set userScrolledAway")
    func testUserDragNearBottomDoesNotSet() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: true)

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Deceleration phase counts as user interacting")
    func testDecelerationIsUserInteracting() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.scrollPhaseChanged(from: .interacting, to: .decelerating)
        // Still user-interacting during deceleration
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
    }

    @Test("User deceleration ending at bottom clears userScrolledAway")
    func testDecelerationEndingAtBottomClears() {
        let coordinator = ScrollStateCoordinator()

        // User scrolls away
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.userScrolledAway)

        // Momentum carries back to bottom
        coordinator.scrollPhaseChanged(from: .interacting, to: .decelerating)
        coordinator.geometryChanged(isNearBottom: true)
        // userScrolledAway already cleared by geometryChanged(isNearBottom: true)
        #expect(!coordinator.userScrolledAway)

        // Deceleration ends
        coordinator.scrollPhaseChanged(from: .decelerating, to: .idle)
        #expect(!coordinator.userScrolledAway)
    }

    @Test("User deceleration ending away from bottom keeps userScrolledAway")
    func testDecelerationEndingAwayKeeps() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .decelerating)
        coordinator.scrollPhaseChanged(from: .decelerating, to: .idle)

        #expect(coordinator.userScrolledAway)
    }

    // MARK: - Programmatic Scroll (animating phase)

    @Test("Animating phase is not user interaction")
    func testAnimatingPhaseNotUserInteraction() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.geometryChanged(isNearBottom: false)

        // Programmatic scroll → should NOT set userScrolledAway
        #expect(!coordinator.userScrolledAway)
    }

    // MARK: - User Actions

    @Test("userSentMessage clears userScrolledAway")
    func testUserSentMessage() {
        let coordinator = ScrollStateCoordinator()

        // User scrolled away
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.userScrolledAway)

        coordinator.userSentMessage()

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("userTappedScrollToBottom clears userScrolledAway")
    func testUserTappedScrollToBottom() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.userScrolledAway)

        coordinator.userTappedScrollToBottom()

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    // MARK: - Navigation

    @Test("scrollToTarget sets userScrolledAway")
    func testScrollToTarget() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollToTarget(messageId: UUID(), using: nil)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    // MARK: - History Loading

    @Test("willPrependHistory saves anchor ID")
    func testWillPrependHistory() {
        let coordinator = ScrollStateCoordinator()
        let anchorId = UUID()

        coordinator.willPrependHistory(firstVisibleId: anchorId)

        // Should not affect scroll state
        #expect(!coordinator.userScrolledAway)
    }

    @Test("willPrependHistory with nil handles gracefully")
    func testWillPrependHistoryNil() {
        let coordinator = ScrollStateCoordinator()

        coordinator.willPrependHistory(firstVisibleId: nil)
        coordinator.didPrependHistory(using: nil)

        #expect(!coordinator.userScrolledAway)
    }

    @Test("didPrependHistory clears anchor after use")
    func testDidPrependHistoryClearsAnchor() {
        let coordinator = ScrollStateCoordinator()
        let anchorId = UUID()

        coordinator.willPrependHistory(firstVisibleId: anchorId)
        coordinator.didPrependHistory(using: nil)

        // Subsequent calls should be no-op
        coordinator.didPrependHistory(using: nil)
        #expect(!coordinator.userScrolledAway)
    }

    // MARK: - Pill Visibility (requires isProcessing from caller)

    @Test("shouldShowNewContentPill is true when user scrolled away")
    func testPillVisibleWhenScrolledAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.shouldShowNewContentPill)
    }

    @Test("shouldShowNewContentPill is false when at bottom")
    func testPillNotVisibleWhenAtBottom() {
        let coordinator = ScrollStateCoordinator()

        #expect(!coordinator.shouldShowNewContentPill)
    }

    // MARK: - Bug Fix Scenarios

    @Test("Post-processing content growth does not show pill")
    func testPostProcessingContentGrowth() {
        let coordinator = ScrollStateCoordinator()

        // User never touched the scroll view — content grows from post-processing
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.geometryChanged(isNearBottom: false)

        // No user interaction → no pill
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.shouldShowNewContentPill)
    }

    @Test("Load earlier messages does not trigger pill")
    func testLoadEarlierMessages() {
        let coordinator = ScrollStateCoordinator()

        // User is scrolled up to load history (user interaction sets this)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.userScrolledAway)

        // Prepend history
        coordinator.willPrependHistory(firstVisibleId: UUID())

        // shouldShowNewContentPill is true but isProcessing is false
        // so ChatView won't show the pill (isProcessing && shouldShowNewContentPill)
        #expect(coordinator.shouldShowNewContentPill)
        // The key: caller gates on isProcessing, which is false during history load
    }

    @Test("Content growth during streaming with no user touch does not show pill")
    func testStreamingContentGrowthNoTouch() {
        let coordinator = ScrollStateCoordinator()

        // Streaming causes content growth, geometry momentarily not near bottom
        coordinator.geometryChanged(isNearBottom: false)

        // No user interaction → userScrolledAway stays false
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("User scrolls up during streaming then taps pill")
    func testUserScrollsUpDuringStreamingThenTapsPill() {
        let coordinator = ScrollStateCoordinator()

        // User drags up during streaming
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        #expect(coordinator.userScrolledAway)
        #expect(coordinator.shouldShowNewContentPill)
        #expect(!coordinator.shouldAutoScroll)

        // User taps pill
        coordinator.userTappedScrollToBottom()

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.shouldShowNewContentPill)
        #expect(coordinator.shouldAutoScroll)
    }
}
