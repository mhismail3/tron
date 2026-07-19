import Testing
import SwiftUI
@testable import TronMobile

/// Tests for earlier-history autoload policy.
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
        #expect(ChatHistoryAutoloadPolicy.topDistanceThreshold(viewportHeight: 300) == 420)
        #expect(ChatHistoryAutoloadPolicy.topDistanceThreshold(viewportHeight: 800) == 720)
        #expect(ChatHistoryAutoloadPolicy.topDistanceThreshold(viewportHeight: 1_200) == 900)
    }

    @Test("Top autoload waits one stable geometry delay before prepending")
    func testTopAutoloadStableGeometryDelayIsBounded() {
        #expect(ChatHistoryAutoloadPolicy.stableGeometryDelayMilliseconds == 120)
    }

    @Test("Top autoload re-arms from user-driven scroll phases")
    func testTopAutoloadRearmsFromUserDrivenScrollPhases() {
        #expect(ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
            phase: .interacting,
            isPositionedByUser: false
        ))
        #expect(ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
            phase: .tracking,
            isPositionedByUser: false
        ))
        #expect(ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
            phase: .decelerating,
            isPositionedByUser: false
        ))
        #expect(!ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
            phase: .idle,
            isPositionedByUser: false
        ))
        #expect(!ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
            phase: .animating,
            isPositionedByUser: false
        ))
    }

    @Test("Native ownership re-arms top autoload during indirect scrolling")
    func testTopAutoloadRearmsFromNativeOwnership() {
        #expect(ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
            phase: .animating,
            isPositionedByUser: true
        ))
    }

    @Test("Geometry-only accessibility pages re-arm repeated top autoload")
    func testTopAutoloadRearmsFromGeometryOnlyAccessibilityMovement() {
        #expect(ChatHistoryAutoloadPolicy.shouldRearmTopDetent(
            phase: .idle,
            isPositionedByUser: false,
            movedTowardOlderContent: true
        ))
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

    @Test("Top autoload policy waits while user interaction is active")
    func testTopAutoloadPolicyWaitsWhileUserInteractionIsActive() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))

        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)
        #expect(coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))
    }

    @Test("Scroll-away alone does not trigger history autoload")
    func testScrollAwayAloneDoesNotTriggerHistoryAutoload() {
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

    @Test("Phase-marked scroll-away still waits for top detent")
    func testPhaseMarkedScrollAwayStillWaitsForTopDetent() {
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

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: false
        ))
        #expect(coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))
    }

    @Test("Top-detent autoload waits during existing prepend")
    func testTopDetentAutoloadWaitsDuringExistingPrepend() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.willPrependHistory(anchor: nil)

        #expect(!coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
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
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle)

        #expect(coordinator.shouldAutoloadEarlierMessages(
            hasMoreMessages: true,
            initialLoadComplete: true,
            isLoadingMoreMessages: false,
            isNearTop: true
        ))
    }
}
