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
        #expect(!coordinator.hasUnseenContent)
        #expect(coordinator.shouldAutoScroll)
        #expect(!coordinator.shouldShowNewContentPill)
    }

    // MARK: - Geometry Updates (no user interaction)

    @Test("Geometry not near bottom without user interaction does not set userScrolledAway")
    func testGeometryNotNearBottomWithoutInteraction() {
        let coordinator = ScrollStateCoordinator()

        coordinator.geometryChanged(isNearBottom: false)

        #expect(!coordinator.isAtBottom)
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

        // End interaction — shouldAutoScroll resumes
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.shouldAutoScroll)
    }

    // MARK: - User Scroll Detection (phase + geometry)

    @Test("User drag away from bottom sets userScrolledAway")
    func testUserDragSetsScrolledAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
        // Pill requires hasUnseenContent too
        #expect(!coordinator.shouldShowNewContentPill)
    }

    @Test("User drag away from bottom with unseen content shows pill")
    func testUserDragWithUnseenContentShowsPill() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.contentDidArrive()

        #expect(coordinator.userScrolledAway)
        #expect(coordinator.shouldShowNewContentPill)
    }

    @Test("User drag near bottom does not set userScrolledAway")
    func testUserDragNearBottomDoesNotSet() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: true)

        #expect(!coordinator.userScrolledAway)
        // shouldAutoScroll is false during interaction (isUserInteracting)
        #expect(!coordinator.shouldAutoScroll)

        // Once interaction ends at bottom, auto-scroll resumes
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Deceleration phase counts as user interacting")
    func testDecelerationIsUserInteracting() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.scrollPhaseChanged(from: .interacting, to: .decelerating)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
    }

    @Test("User deceleration ending at bottom clears userScrolledAway")
    func testDecelerationEndingAtBottomClears() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.userScrolledAway)

        // Momentum carries back to bottom
        coordinator.scrollPhaseChanged(from: .interacting, to: .decelerating)
        coordinator.geometryChanged(isNearBottom: true)
        #expect(!coordinator.userScrolledAway)

        coordinator.scrollPhaseChanged(from: .decelerating, to: .idle)
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
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

        #expect(!coordinator.userScrolledAway)
    }

    // MARK: - Auto-scroll pause during interaction

    @Test("shouldAutoScroll pauses during user interaction")
    func testAutoScrollPausesDuringInteraction() {
        let coordinator = ScrollStateCoordinator()

        // Initially auto-scroll is on
        #expect(coordinator.shouldAutoScroll)

        // User touches scroll view — auto-scroll pauses immediately
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        #expect(!coordinator.shouldAutoScroll)

        // Still paused during deceleration
        coordinator.scrollPhaseChanged(from: .interacting, to: .decelerating)
        #expect(!coordinator.shouldAutoScroll)

        // Resumes when interaction ends (still at bottom)
        coordinator.scrollPhaseChanged(from: .decelerating, to: .idle)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("shouldAutoScroll resumes after interaction ends at bottom")
    func testAutoScrollResumesAfterInteractionAtBottom() {
        let coordinator = ScrollStateCoordinator()

        // User drags away
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(!coordinator.shouldAutoScroll)

        // User drags back to bottom
        coordinator.geometryChanged(isNearBottom: true)
        // Still paused (user still touching)
        #expect(!coordinator.shouldAutoScroll)

        // User lifts finger
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Streaming updates cannot fight user scroll gesture")
    func testStreamingCannotFightUserGesture() {
        let coordinator = ScrollStateCoordinator()

        // User starts interacting — auto-scroll pauses BEFORE any geometry changes
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        #expect(!coordinator.shouldAutoScroll)

        // Even though geometry says near bottom, auto-scroll stays paused
        coordinator.geometryChanged(isNearBottom: true)
        #expect(!coordinator.shouldAutoScroll)

        // Geometry says not near bottom — user is scrolling away
        coordinator.geometryChanged(isNearBottom: false)
        #expect(!coordinator.shouldAutoScroll)
        #expect(coordinator.userScrolledAway)

        // User lifts finger away from bottom
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(!coordinator.shouldAutoScroll)
        #expect(coordinator.userScrolledAway)
    }

    // MARK: - User Actions

    @Test("userSentMessage clears userScrolledAway")
    func testUserSentMessage() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.contentDidArrive()
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnseenContent)

        coordinator.userSentMessage()

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnseenContent)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("userTappedScrollToBottom clears userScrolledAway")
    func testUserTappedScrollToBottom() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.contentDidArrive()
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnseenContent)

        coordinator.userTappedScrollToBottom()

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnseenContent)
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

        coordinator.didPrependHistory(using: nil)
        #expect(!coordinator.userScrolledAway)
    }

    // MARK: - hasUnseenContent

    @Test("contentDidArrive does nothing when not scrolled away")
    func testContentDidArriveWhenAtBottom() {
        let coordinator = ScrollStateCoordinator()

        coordinator.contentDidArrive()

        #expect(!coordinator.hasUnseenContent)
        #expect(!coordinator.shouldShowNewContentPill)
    }

    @Test("contentDidArrive sets hasUnseenContent when scrolled away")
    func testContentDidArriveWhenScrolledAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.userScrolledAway)

        coordinator.contentDidArrive()

        #expect(coordinator.hasUnseenContent)
        #expect(coordinator.shouldShowNewContentPill)
    }

    @Test("Scrolling to bottom clears hasUnseenContent")
    func testScrollToBottomClearsUnseenContent() {
        let coordinator = ScrollStateCoordinator()

        // Scroll away and mark unseen content
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.contentDidArrive()
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.hasUnseenContent)

        // Scroll back to bottom
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: true)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        #expect(!coordinator.hasUnseenContent)
        #expect(!coordinator.shouldShowNewContentPill)
    }

    @Test("shouldShowNewContentPill requires both userScrolledAway and hasUnseenContent")
    func testPillRequiresBothFlags() {
        let coordinator = ScrollStateCoordinator()

        // Only userScrolledAway — no pill
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.hasUnseenContent)
        #expect(!coordinator.shouldShowNewContentPill)

        // Now add unseen content — pill shows
        coordinator.contentDidArrive()
        #expect(coordinator.shouldShowNewContentPill)
    }

    @Test("Pill persists after streaming would end")
    func testPillPersistsAfterStreaming() {
        let coordinator = ScrollStateCoordinator()

        // User scrolls away during streaming
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        coordinator.contentDidArrive()

        #expect(coordinator.shouldShowNewContentPill)

        // "Streaming ends" — nothing in coordinator changes, pill persists
        // (isProcessing would become false externally, but pill doesn't depend on it)
        #expect(coordinator.shouldShowNewContentPill)
    }

    // MARK: - Pill Visibility

    @Test("shouldShowNewContentPill is false when at bottom")
    func testPillNotVisibleWhenAtBottom() {
        let coordinator = ScrollStateCoordinator()

        #expect(!coordinator.shouldShowNewContentPill)
    }

    // MARK: - Bug Fix Scenarios

    @Test("Post-processing content growth does not show pill")
    func testPostProcessingContentGrowth() {
        let coordinator = ScrollStateCoordinator()

        coordinator.geometryChanged(isNearBottom: false)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.shouldShowNewContentPill)
    }

    @Test("Load earlier messages does not trigger pill")
    func testLoadEarlierMessages() {
        let coordinator = ScrollStateCoordinator()

        // User scrolled up to load history
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.userScrolledAway)

        coordinator.willPrependHistory(firstVisibleId: UUID())

        // No contentDidArrive during history load → no pill
        #expect(!coordinator.shouldShowNewContentPill)
    }

    @Test("Content growth during streaming with no user touch does not show pill")
    func testStreamingContentGrowthNoTouch() {
        let coordinator = ScrollStateCoordinator()

        coordinator.geometryChanged(isNearBottom: false)

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

        // Content arrives while scrolled away
        coordinator.contentDidArrive()

        #expect(coordinator.userScrolledAway)
        #expect(coordinator.shouldShowNewContentPill)
        #expect(!coordinator.shouldAutoScroll)

        // User taps pill
        coordinator.userTappedScrollToBottom()

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnseenContent)
        #expect(!coordinator.shouldShowNewContentPill)
        #expect(coordinator.shouldAutoScroll)
    }

    // MARK: - Callback Ordering Race

    @Test("Geometry fires after phase goes to idle: userScrolledAway still set")
    func testGeometryAfterPhaseIdle() {
        let coordinator = ScrollStateCoordinator()

        // User starts interacting
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)

        // User lifts finger — phase goes to idle BEFORE geometry reports position
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        // Geometry fires late with isNearBottom: false — user was scrolled away
        // hadUserInteraction bridges the gap so userScrolledAway is still set
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("hadUserInteraction consumed after late geometry resolves")
    func testHadUserInteractionConsumed() {
        let coordinator = ScrollStateCoordinator()

        // User interacts and lifts
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        // Late geometry fires — consumes hadUserInteraction
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.userScrolledAway)

        // Subsequent content growth geometry should NOT re-set userScrolledAway
        // (simulate: user tapped pill, then content grows)
        coordinator.userTappedScrollToBottom()
        #expect(!coordinator.userScrolledAway)

        // Content growth triggers geometry (no user interaction)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(!coordinator.userScrolledAway)
    }

    @Test("Pill tap followed by programmatic scroll does not re-trigger userScrolledAway")
    func testPillTapDoesNotRetrigger() {
        let coordinator = ScrollStateCoordinator()

        // User scrolls away
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.contentDidArrive()
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.shouldShowNewContentPill)

        // User taps pill → clears everything including hadUserInteraction
        coordinator.userTappedScrollToBottom()
        #expect(!coordinator.userScrolledAway)

        // Programmatic scroll animates to bottom — mid-animation geometry might be false
        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.geometryChanged(isNearBottom: false)
        // animating is NOT user interaction, hadUserInteraction is false → no re-trigger
        #expect(!coordinator.userScrolledAway)

        // Animation completes at bottom
        coordinator.geometryChanged(isNearBottom: true)
        coordinator.scrollPhaseChanged(from: .animating, to: .idle)
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("User already not-at-bottom when interacting: userScrolledAway set on idle")
    func testAlreadyNotAtBottomWhenInteracting() {
        let coordinator = ScrollStateCoordinator()

        // Simulate streaming state: geometry reported not-near-bottom (dist > threshold)
        // but no user interaction, so userScrolledAway is false
        coordinator.geometryChanged(isNearBottom: false)
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)

        // User starts interacting — auto-scroll pauses
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        #expect(!coordinator.shouldAutoScroll)

        // User scrolls up — geometry Bool stays false (no change, no callback)
        // geometryChanged is NOT called — this is the exact bug scenario

        // User lifts finger — phase handler detects not-at-bottom
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("Deep link navigation does not show pill")
    func testDeepLinkNoPill() {
        let coordinator = ScrollStateCoordinator()

        // scrollToTarget sets userScrolledAway but NOT hasUnseenContent
        coordinator.scrollToTarget(messageId: UUID(), using: nil)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.hasUnseenContent)
        #expect(!coordinator.shouldShowNewContentPill)
    }
}
