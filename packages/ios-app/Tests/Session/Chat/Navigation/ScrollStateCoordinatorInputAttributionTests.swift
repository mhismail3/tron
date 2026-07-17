import Testing
import SwiftUI
@testable import TronMobile

/// Callback-order and geometry-classification coverage for indirect scroll input.
@Suite("ScrollStateCoordinator Input Attribution Tests")
@MainActor
struct ScrollStateCoordinatorInputAttributionTests {
    @Test("Native scroll ownership commits accessibility scroll-away")
    func testNativeOwnershipCommitsAccessibilityScrollAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(!coordinator.shouldAutoScroll)
        coordinator.geometryChanged(isNearBottom: false)
        coordinator.contentDidArrive()

        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnseenContent)
        #expect(!coordinator.shouldAutoScroll)
        #expect(coordinator.shouldShowNewContentPill)
    }

    @Test("Geometry-only accessibility movement commits scroll-away")
    func testGeometryOnlyAccessibilityMovementCommitsScrollAway() {
        let coordinator = ScrollStateCoordinator()
        coordinator.geometryChanged(
            isNearBottom: false,
            isPositionedByUser: false,
            userMovedTowardOlderContent: true
        )
        coordinator.contentDidArrive()

        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnseenContent)
        #expect(coordinator.shouldShowNewContentPill)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("History prepend owns upward geometry and does not manufacture user intent")
    func testHistoryPrependIgnoresUpwardGeometryIntent() {
        let coordinator = ScrollStateCoordinator()

        coordinator.willPrependHistory(anchor: nil)
        coordinator.geometryChanged(
            isNearBottom: false,
            isPositionedByUser: false,
            userMovedTowardOlderContent: true
        )
        coordinator.contentDidArrive()

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnseenContent)
        #expect(!coordinator.shouldAutoScroll)

        coordinator.cancelPrependHistory()
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Stable page-sized upward movement is directional user intent")
    func testDetectsStablePageSizedUpwardMovement() {
        #expect(ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 15_930,
            newContentOffsetY: 12_347,
            oldDistanceFromBottom: 49,
            newDistanceFromBottom: 3_632,
            oldViewportHeight: 780,
            newViewportHeight: 780,
            oldBottomInset: 84,
            newBottomInset: 84
        ))
    }

    @Test("A real page move remains detectable while content grows")
    func testDetectsPageMovementDuringContentGrowth() {
        #expect(ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 4_000,
            newContentOffsetY: 3_200,
            oldDistanceFromBottom: 20,
            newDistanceFromBottom: 1_020,
            oldViewportHeight: 800,
            newViewportHeight: 800,
            oldBottomInset: 84,
            newBottomInset: 84
        ))
    }

    @Test("Downward app movement and stationary content growth are not upward intent")
    func testRejectsAppMovementAndStationaryContentGrowth() {
        #expect(!ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 1_000,
            newContentOffsetY: 1_600,
            oldDistanceFromBottom: 20,
            newDistanceFromBottom: 20,
            oldViewportHeight: 780,
            newViewportHeight: 780,
            oldBottomInset: 84,
            newBottomInset: 84
        ))
        #expect(!ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 1_000,
            newContentOffsetY: 1_000,
            oldDistanceFromBottom: 20,
            newDistanceFromBottom: 500,
            oldViewportHeight: 780,
            newViewportHeight: 780,
            oldBottomInset: 84,
            newBottomInset: 84
        ))
    }

    @Test("Anchor correction with flat bottom distance is not upward user intent")
    func testRejectsAnchorCorrectionWithFlatBottomDistance() {
        #expect(!ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 1_000,
            newContentOffsetY: 500,
            oldDistanceFromBottom: 300,
            newDistanceFromBottom: 300,
            oldViewportHeight: 780,
            newViewportHeight: 780,
            oldBottomInset: 84,
            newBottomInset: 84
        ))
    }

    @Test("Small layout correction is below the accessibility page threshold")
    func testRejectsSmallUpwardCorrection() {
        #expect(!ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 1_000,
            newContentOffsetY: 900,
            oldDistanceFromBottom: 20,
            newDistanceFromBottom: 120,
            oldViewportHeight: 780,
            newViewportHeight: 780,
            oldBottomInset: 84,
            newBottomInset: 84
        ))
    }

    @Test("Container or composer resize cannot masquerade as upward user intent")
    func testRejectsUpwardOffsetDuringLayoutResize() {
        #expect(!ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 1_000,
            newContentOffsetY: 500,
            oldDistanceFromBottom: 20,
            newDistanceFromBottom: 520,
            oldViewportHeight: 780,
            newViewportHeight: 480,
            oldBottomInset: 84,
            newBottomInset: 84
        ))
        #expect(!ScrollStateCoordinator.isMovementTowardOlderContent(
            oldContentOffsetY: 1_000,
            newContentOffsetY: 500,
            oldDistanceFromBottom: 20,
            newDistanceFromBottom: 520,
            oldViewportHeight: 780,
            newViewportHeight: 780,
            oldBottomInset: 84,
            newBottomInset: 384
        ))
    }

    @Test("Directional geometry inside bottom tolerance does not latch scroll-away")
    func testNearBottomDirectionalGeometryDoesNotLatch() {
        let coordinator = ScrollStateCoordinator()

        coordinator.geometryChanged(
            isNearBottom: true,
            userMovedTowardOlderContent: true
        )

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Near-bottom accessibility animation retains ownership until idle")
    func testNearBottomAccessibilityAnimationRetainsOwnershipUntilIdle() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(isNearBottom: true)
        coordinator.contentDidArrive()

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
        #expect(!coordinator.shouldReleaseNativeScrollOwnership)

        coordinator.scrollPhaseChanged(from: .animating, to: .idle)

        #expect(coordinator.shouldReleaseNativeScrollOwnership)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Near-bottom geometry before native ownership also resumes at idle")
    func testNearBottomGeometryBeforeNativeOwnershipResumesAtIdle() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.geometryChanged(
            isNearBottom: true,
            isPositionedByUser: true
        )
        coordinator.scrollPositionChanged(isPositionedByUser: true)

        #expect(!coordinator.shouldAutoScroll)

        coordinator.scrollPhaseChanged(from: .animating, to: .idle)

        #expect(coordinator.shouldReleaseNativeScrollOwnership)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Native takeover does not inherit geometry from an app animation")
    func testNativeTakeoverDuringAppAnimationWaitsForUserGeometry() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.geometryChanged(
            isNearBottom: true,
            isPositionedByUser: false
        )
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.scrollPhaseChanged(from: .animating, to: .idle)

        #expect(!coordinator.shouldAutoScroll)

        coordinator.geometryChanged(
            isNearBottom: false,
            isPositionedByUser: true
        )

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("Final near geometry consumes pending ownership after binding turns app-owned")
    func testFinalNearGeometryConsumesPendingAfterOwnershipEnds() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.scrollPositionChanged(isPositionedByUser: false)
        coordinator.geometryChanged(
            isNearBottom: true,
            isPositionedByUser: false
        )

        #expect(coordinator.shouldReleaseNativeScrollOwnership)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Final near geometry does not resume before native animation reaches idle")
    func testFinalNearGeometryWaitsForNativeAnimationIdle() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.scrollPositionChanged(isPositionedByUser: false)
        coordinator.geometryChanged(
            isNearBottom: true,
            isPositionedByUser: false
        )

        #expect(!coordinator.shouldAutoScroll)

        coordinator.scrollPhaseChanged(from: .animating, to: .idle)

        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Late accessibility geometry remains attributed after phase idle")
    func testNativeGeometryAfterPhaseIdleCommitsScrollAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.scrollPhaseChanged(from: .animating, to: .idle)

        #expect(!coordinator.shouldAutoScroll)

        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("Idle phase geometry preserves native attribution after an earlier near sample")
    func testIdlePhaseGeometryCommitsNativeScrollAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(
            isNearBottom: true,
            isPositionedByUser: true
        )
        coordinator.scrollPhaseChanged(
            from: .animating,
            to: .idle,
            finalIsNearBottom: false
        )
        coordinator.contentDidArrive()

        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnseenContent)
        #expect(!coordinator.shouldAutoScroll)
        #expect(coordinator.shouldShowNewContentPill)
    }

    @Test("Idle phase geometry retains native origin after ownership clears")
    func testIdlePhaseGeometryCommitsAfterNativeOwnershipEnds() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(
            isNearBottom: true,
            isPositionedByUser: true
        )
        coordinator.scrollPositionChanged(isPositionedByUser: false)
        coordinator.scrollPhaseChanged(
            from: .animating,
            to: .idle,
            finalIsNearBottom: false
        )

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("Native ownership arriving after geometry still commits scroll-away")
    func testNativeOwnershipAfterGeometryCommitsScrollAway() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.shouldAutoScroll)

        coordinator.scrollPositionChanged(isPositionedByUser: true)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("App ownership restores a pinned accessibility position")
    func testAppOwnershipRestoresPinnedPosition() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(!coordinator.shouldAutoScroll)

        coordinator.appWillPositionScroll()

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("App takeover clears native animation provenance")
    func testAppTakeoverIgnoresProgrammaticAwayGeometry() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPhaseChanged(from: .idle, to: .animating)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.appWillPositionScroll()
        coordinator.geometryChanged(isNearBottom: false)

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

    @Test("Returning to bottom re-arms a later accessibility scroll-away")
    func testReturningToBottomRearmsNativeOwnership() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(isNearBottom: false)
        #expect(coordinator.userScrolledAway)

        coordinator.geometryChanged(isNearBottom: true)
        #expect(coordinator.shouldAutoScroll)

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("Foreground commits an away native position then clears transient ownership")
    func testForegroundCommitsAwayNativePosition() {
        let coordinator = ScrollStateCoordinator()

        coordinator.geometryChanged(isNearBottom: false)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.sceneDidBecomeActive()

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("Foreground samples stale native ownership before catch-up")
    func testForegroundSamplesNativeOwnershipBeforeCatchUp() {
        let coordinator = ScrollStateCoordinator()

        coordinator.sceneDidBecomeActive(isPositionedByUser: true)

        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)

        coordinator.geometryChanged(isNearBottom: false)

        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.shouldAutoScroll)
    }

    @Test("Foreground clears pending native geometry when the bound owner has ended")
    func testForegroundClearsEndedNativeOwnership() {
        let coordinator = ScrollStateCoordinator()

        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(!coordinator.shouldAutoScroll)

        coordinator.sceneDidBecomeActive(isPositionedByUser: false)

        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.shouldAutoScroll)
    }

}
