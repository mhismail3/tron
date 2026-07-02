import Testing
import SwiftUI
@testable import TronMobile

/// Tests for earlier-history autoload and prefetch policy.
@Suite("Scroll History Autoload Tests")
@MainActor
struct ScrollHistoryAutoloadTests {
    @Test("Top autoload policy waits for initial load")
    func testTopAutoloadPolicyWaitsForInitialLoad() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: false,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))
    }

    @Test("Top autoload policy waits until viewport is near top")
    func testTopAutoloadPolicyWaitsUntilNearTop() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: false
        ))
    }

    @Test("Top autoload threshold prefetches before literal top")
    func testTopAutoloadThresholdPrefetchesBeforeLiteralTop() {
        #expect(ChatHistoryAutoloadPolicy.topDistanceThreshold(viewportHeight: 300) == 700)
        #expect(ChatHistoryAutoloadPolicy.topDistanceThreshold(viewportHeight: 800) == 1_600)
        #expect(ChatHistoryAutoloadPolicy.topDistanceThreshold(viewportHeight: 1_200) == 1_800)
    }

    @Test("Top autoload policy does not trigger away from top")
    func testTopAutoloadPolicyDoesNotTriggerAwayFromTop() {
        let coordinator = ScrollStateCoordinator()

        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: false
        ))
    }

    @Test("Top autoload policy does not trigger while loading")
    func testTopAutoloadPolicyDoesNotTriggerWhileLoading() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: true,
            isNearTop: true
        ))
    }

    @Test("Top autoload policy triggers at top detent even before scroll-away settles")
    func testTopAutoloadPolicyTriggersAtTopDetentBeforeScrollAwaySettles() {
        let coordinator = ScrollStateCoordinator()

        #expect(coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))
    }

    @Test("Earlier history prefetch waits for user scroll-away")
    func testEarlierHistoryPrefetchWaitsForUserScrollAway() {
        let coordinator = ScrollStateCoordinator()

        #expect(!coordinator.shouldPrefetchEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))
    }

    @Test("Earlier history prefetch starts after user scrolls away")
    func testEarlierHistoryPrefetchStartsAfterUserScrollAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.shouldPrefetchEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))
    }

    @Test("Earlier history prefetch can start when phase marks scroll-away")
    func testEarlierHistoryPrefetchStartsAfterPhaseMarksScrollAway() {
        let coordinator = ScrollStateCoordinator()

        // Content growth reported not-near-bottom before the user touched the
        // scroll view. This must not count as user intent.
        coordinator.geometryChanged(isNearBottom: false)
        #expect(!coordinator.userScrolledAway)

        // The user then interacts while the geometry Bool remains false, so the
        // view may not receive another geometry-change action. The phase handler
        // still marks the scroll-away interval when interaction ends.
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        #expect(coordinator.beginEarlierHistoryPrefetchIfNeeded(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))
    }

    @Test("Earlier history prefetch is one-shot until returning to bottom")
    func testEarlierHistoryPrefetchIsOneShotUntilBottom() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.beginEarlierHistoryPrefetchIfNeeded(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))
        #expect(!coordinator.shouldPrefetchEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))
        #expect(!coordinator.beginEarlierHistoryPrefetchIfNeeded(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))

        coordinator.geometryChanged(isNearBottom: true)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.beginEarlierHistoryPrefetchIfNeeded(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))
    }

    @Test("Earlier history prefetch waits during existing prepend")
    func testEarlierHistoryPrefetchWaitsDuringExistingPrepend() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.willPrependHistory(anchor: nil)

        #expect(!coordinator.shouldPrefetchEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false
        ))
    }

    @Test("Canceled history prepend restores scroll coordinator")
    func testCanceledHistoryPrependRestoresCoordinator() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.willPrependHistory(anchor: nil)
        #expect(!coordinator.shouldAutoScroll)
        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))

        coordinator.cancelPrependHistory()

        #expect(coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))
    }
}
