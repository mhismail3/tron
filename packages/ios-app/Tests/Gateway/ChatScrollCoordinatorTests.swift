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

    @Test("phase final geometry preserves callback ordering")
    func phaseFinalGeometry() {
        let coordinator = ChatScrollCoordinator()
        coordinator.scrollPhaseChanged(from: .idle, to: .interacting, finalGeometry: nil)
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

    @Test("composer inset change is viewport geometry, not transcript growth")
    func composerInsetDoesNotManufactureGrowth() {
        let coordinator = ChatScrollCoordinator()
        let before = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 400, bottomInset: 72)
        let after = ChatTranscriptGeometry(offsetY: 600, contentHeight: 1_000, containerHeight: 320, bottomInset: 152)
        coordinator.viewportChanged(previous: before, current: after)
        #expect(!coordinator.hasUnreadContent)
        #expect(coordinator.canAutomaticallyFollow)
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
    }
}
