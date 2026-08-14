import SwiftUI
import Testing
@testable import TronMobile

@MainActor
@Suite("Chat scroll coordinator")
struct ChatScrollCoordinatorTests {
    private let bottom = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400)
    private let away = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_000, containerHeight: 400)

    @Test("native ownership and gesture completion durably detach")
    func nativeOwnershipDetaches() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.canAutomaticallyFollow)
        #expect(!coordinator.beginAutomaticBottomScroll())
    }

    @Test("geometry arriving before native ownership preserves upward intent")
    func geometryBeforeOwnershipDetaches() {
        let coordinator = ChatScrollCoordinator()
        coordinator.geometryChanged(previous: bottom, current: away)
        #expect(!coordinator.userScrolledAway)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.canAutomaticallyFollow)
    }

    @Test("phase final geometry preserves callback ordering")
    func phaseFinalGeometry() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        #expect(coordinator.userScrolledAway)
        coordinator.geometryChanged(previous: away, current: bottom)
        #expect(!coordinator.userScrolledAway)
    }

    @Test("pinned measured growth grants one command and progress without growth grants none")
    func pinnedGrowthCoalesces() {
        let coordinator = ChatScrollCoordinator()
        let grown = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_080, containerHeight: 400)
        #expect(coordinator.geometryChanged(previous: bottom, current: grown))
        #expect(coordinator.beginAutomaticBottomScroll())
        #expect(!coordinator.geometryChanged(previous: grown, current: grown))
        coordinator.confirmAutomaticBottomScroll(
            ChatTranscriptGeometry(offsetY: 680, contentHeight: 1_080, containerHeight: 400)
        )
        #expect(coordinator.canAutomaticallyFollow)
    }

    @Test("every measured streaming growth reissues a coalescible bottom command")
    func continuousGrowthKeepsFollowing() {
        let coordinator = ChatScrollCoordinator()
        let firstGrowth = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_080, containerHeight: 400)
        let secondGrowth = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_160, containerHeight: 400)
        #expect(coordinator.geometryChanged(previous: bottom, current: firstGrowth))
        #expect(coordinator.beginAutomaticBottomScroll())
        #expect(coordinator.geometryChanged(previous: firstGrowth, current: secondGrowth))
        #expect(coordinator.beginAutomaticBottomScroll())
        #expect(!coordinator.userScrolledAway)
    }

    @Test("native ownership plus stationary growth does not manufacture scroll-away")
    func stationaryGrowthDoesNotDetach() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        let grown = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_080, containerHeight: 400)
        #expect(!coordinator.geometryChanged(previous: bottom, current: grown))
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.scrollPhaseChanged(
            from: .interacting,
            to: .idle,
            finalGeometry: grown
        ))
        #expect(!coordinator.userScrolledAway)
    }

    @Test("user-driven settling commits upward movement only when it reaches idle")
    func userDrivenSettlingDetachesAtIdle() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.scrollPhaseChanged(from: .interacting, to: .animating, finalGeometry: nil)
        #expect(!coordinator.userScrolledAway)
        coordinator.scrollPhaseChanged(from: .animating, to: .idle, finalGeometry: away)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.isAtBottom)
    }

    @Test("settled bottom releases persistent scroll bindings only at idle")
    func settledBottomBindingRelease() {
        let coordinator = ChatScrollCoordinator()
        #expect(coordinator.canReleaseSettledScrollBinding)

        coordinator.scrollPhaseChanged(from: .idle, to: .animating, finalGeometry: bottom)
        #expect(coordinator.isScrollAnimating)
        #expect(!coordinator.canReleaseSettledScrollBinding)

        coordinator.scrollPhaseChanged(from: .animating, to: .idle, finalGeometry: bottom)
        #expect(!coordinator.isScrollAnimating)
        #expect(coordinator.canReleaseSettledScrollBinding)

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        #expect(!coordinator.canReleaseSettledScrollBinding)
    }

    @Test("bottom rubber-banding never detaches or exposes catch-up")
    func bottomRubberBandStaysPinned() {
        let coordinator = ChatScrollCoordinator()
        let overscrolledBottom = ChatTranscriptGeometry(
            offsetY: 630, contentHeight: 1_000, containerHeight: 400
        )
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: overscrolledBottom)
        coordinator.geometryChanged(previous: overscrolledBottom, current: bottom)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: bottom)
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
    }

    @Test("scrolling back to the exact bottom clears unread and resumes following")
    func manualReturnToBottomRepins() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        coordinator.semanticResponseArrived()
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)

        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: away)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: away, current: bottom)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: bottom)
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnreadContent)

        let grown = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_080, containerHeight: 400)
        #expect(coordinator.geometryChanged(previous: bottom, current: grown))
    }

    @Test("detached growth preserves viewport and marks semantic responses unread")
    func detachedGrowthAndUnread() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        let grownAway = ChatTranscriptGeometry(offsetY: 300, contentHeight: 1_080, containerHeight: 400)
        #expect(!coordinator.geometryChanged(previous: away, current: grownAway))
        coordinator.semanticResponseArrived()
        #expect(coordinator.hasUnreadContent)
    }

    @Test("prepend suppresses automatic following and restores detached state")
    func prependOwnership() {
        let coordinator = ChatScrollCoordinator()
        coordinator.beginPrependingHistory()
        #expect(!coordinator.beginAutomaticBottomScroll())
        let grown = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_200, containerHeight: 400)
        #expect(!coordinator.geometryChanged(previous: bottom, current: grown))
        coordinator.endPrependingHistory(preserveScrolledAway: true)
        #expect(coordinator.userScrolledAway)
    }

    @Test("a new user gesture cancels prepend correction and owns final state")
    func userInterruptsPrependRestoration() {
        let coordinator = ChatScrollCoordinator()
        coordinator.beginPrependingHistory()
        #expect(coordinator.canRestorePrependPosition)
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        #expect(!coordinator.canRestorePrependPosition)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        coordinator.endPrependingHistory(preserveScrolledAway: false)
        #expect(coordinator.userScrolledAway)
        #expect(!coordinator.isAtBottom)
    }

    @Test("composer inset change is viewport geometry, not transcript growth")
    func composerInsetDoesNotManufactureGrowth() {
        let coordinator = ChatScrollCoordinator()
        let before = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400, bottomInset: 72)
        let after = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 320, bottomInset: 152)
        #expect(after.isViewportOnlyChange(from: before))
        #expect(coordinator.viewportChanged(previous: before, current: after))
        #expect(!coordinator.hasUnreadContent)
        #expect(!coordinator.isAtBottom)
        #expect(coordinator.beginAutomaticBottomScroll())
    }

    @Test("mixed viewport resize and transcript growth follows only pinned readers")
    func mixedViewportAndGrowthOwnership() {
        let pinned = ChatScrollCoordinator()
        let mixed = ChatTranscriptGeometry(
            offsetY: 600, contentHeight: 1_080, containerHeight: 320, bottomInset: 80
        )
        #expect(mixed.hasViewportChange(from: bottom))
        #expect(pinned.viewportChanged(previous: bottom, current: mixed))

        let detached = ChatScrollCoordinator()
        detached.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        detached.scrollPositionChanged(isPositionedByUser: true)
        detached.geometryChanged(previous: bottom, current: away)
        detached.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        #expect(!detached.viewportChanged(previous: away, current: mixed))
        #expect(detached.userScrolledAway)
    }

    @Test("viewport changes preserve an existing detached reader")
    func detachedViewportChangeStaysDetached() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.semanticResponseArrived()
        let resized = ChatTranscriptGeometry(
            offsetY: 300, contentHeight: 1_000, containerHeight: 700, bottomInset: 0
        )
        #expect(resized.isAtExactBottom)
        #expect(!coordinator.viewportChanged(previous: away, current: resized))
        #expect(coordinator.userScrolledAway)
        #expect(coordinator.hasUnreadContent)
        #expect(!coordinator.isAtBottom)
    }

    @Test("manual scrolling to the practical tail boundary hides catch-up")
    func practicalBottomRepins() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: bottom)
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.scrollPhaseChanged(from: .interacting, to: .idle, finalGeometry: away)
        coordinator.semanticResponseArrived()

        let roundedTail = ChatTranscriptGeometry(
            offsetY: 589, contentHeight: 1_000, containerHeight: 400
        )
        coordinator.geometryChanged(previous: away, current: roundedTail)
        #expect(!coordinator.userScrolledAway)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.isAtBottom)
    }

    @Test("opening positioning can reissue bottom ownership without enabling ordinary follow")
    func openingPositioningOwnership() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        #expect(!coordinator.canAutomaticallyFollow)
        coordinator.beginOpeningBottomScroll()
        coordinator.beginOpeningBottomScroll()
        #expect(coordinator.beginAutomaticBottomScroll())
    }

    @Test("explicit app jump claims ownership and clears unread only after intent")
    func explicitJump() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPositionChanged(isPositionedByUser: true)
        coordinator.geometryChanged(previous: bottom, current: away)
        coordinator.semanticResponseArrived()
        #expect(coordinator.hasUnreadContent)
        #expect(coordinator.beginAutomaticBottomScroll(force: true))
        coordinator.clearUnreadAfterExplicitJump()
        #expect(!coordinator.hasUnreadContent)
        #expect(!coordinator.userScrolledAway)
        #expect(coordinator.isAtBottom)

        let growthDuringJump = ChatTranscriptGeometry(
            offsetY: 300, contentHeight: 1_080, containerHeight: 400
        )
        #expect(coordinator.geometryChanged(previous: away, current: growthDuringJump))
    }
}
