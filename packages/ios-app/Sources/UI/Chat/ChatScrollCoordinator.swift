import SwiftUI

/// Single owner for gateway-chat scroll intent. Geometry is an observation;
/// only explicit app requests mutate `ScrollPosition`, and direct/native user
/// ownership always wins over automatic following.
@Observable
@MainActor
final class ChatScrollCoordinator {
    private(set) var isAtBottom = true
    private(set) var userScrolledAway = false
    private(set) var hasUnreadContent = false
    private(set) var isUserInteracting = false
    private(set) var isPrependingHistory = false

    private var isNativeUserOwned = false
    private var pendingNativeUserGeometry = false
    private var hadUserInteraction = false
    private var isUserDrivenSettling = false
    private var automaticBottomRequestOutstanding = false
    private var pendingGrowthFollow = false

    var canAutomaticallyFollow: Bool {
        !userScrolledAway
            && !isUserInteracting
            && !isNativeUserOwned
            && !pendingNativeUserGeometry
            && !isUserDrivenSettling
            && !isPrependingHistory
    }

    func resetForPresentation() {
        isAtBottom = true
        userScrolledAway = false
        hasUnreadContent = false
        isUserInteracting = false
        isPrependingHistory = false
        isNativeUserOwned = false
        pendingNativeUserGeometry = false
        hadUserInteraction = false
        isUserDrivenSettling = false
        automaticBottomRequestOutstanding = false
        pendingGrowthFollow = false
    }

    func scrollPositionChanged(isPositionedByUser: Bool) {
        if isPositionedByUser && !isNativeUserOwned {
            pendingNativeUserGeometry = true
        }
        isNativeUserOwned = isPositionedByUser
        if isPositionedByUser, !isAtBottom {
            commitScrollAway()
        }
    }

    func scrollPhaseChanged(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        finalGeometry: ChatTranscriptGeometry?
    ) {
        if newPhase == .idle, let finalGeometry {
            geometryChanged(previous: finalGeometry, current: finalGeometry)
        }

        let wasInteracting = isUserInteracting
        let wasUserDrivenSettling = isUserDrivenSettling
        isUserInteracting = Self.isDirectUserPhase(newPhase)
        isUserDrivenSettling = newPhase == .animating
            && (wasUserDrivenSettling || Self.isDirectUserPhase(oldPhase))

        if isUserInteracting && !wasInteracting { hadUserInteraction = true }
        if wasInteracting && !isUserInteracting && !isAtBottom { commitScrollAway() }

        if newPhase == .idle {
            if isAtBottom {
                releaseAtBottom()
            }
            if pendingGrowthFollow, canAutomaticallyFollow {
                pendingGrowthFollow = false
            }
        }
    }

    /// Returns true exactly when measured transcript growth should issue one
    /// automatic bottom command. Progress-only updates with no height delta do not.
    @discardableResult
    func geometryChanged(
        previous: ChatTranscriptGeometry,
        current: ChatTranscriptGeometry
    ) -> Bool {
        let previousAtBottom = isAtBottom
        let hasUserAttribution = isUserInteracting
            || hadUserInteraction
            || isNativeUserOwned
            || pendingNativeUserGeometry
            || isUserDrivenSettling

        isAtBottom = current.isAtBottom
        if hasUserAttribution && !current.isAtBottom {
            commitScrollAway()
        } else if current.isAtExactBottom {
            releaseAtBottom()
        }

        pendingNativeUserGeometry = false
        if !isUserInteracting { hadUserInteraction = false }

        if automaticBottomRequestOutstanding {
            if current.isAtExactBottom { automaticBottomRequestOutstanding = false }
            return false
        }

        guard previous.isValid,
              current.contentHeight > previous.contentHeight + 0.5,
              previousAtBottom,
              canAutomaticallyFollow else {
            if current.contentHeight > previous.contentHeight + 0.5,
               previousAtBottom,
               !userScrolledAway {
                pendingGrowthFollow = true
            }
            return false
        }
        automaticBottomRequestOutstanding = true
        return true
    }

    /// Composer/safe-area changes resize the viewport; they are not transcript
    /// growth and must never manufacture a follow request or unread content.
    func viewportChanged(previous: ChatTranscriptGeometry, current: ChatTranscriptGeometry) {
        guard previous.contentHeight == current.contentHeight else { return }
        isAtBottom = current.isAtBottom
        if current.isAtExactBottom { releaseAtBottom() }
    }

    /// Claims app ownership before the binding mutation. Returns false when a
    /// gesture, rebound, native ownership, or prepend owns the viewport.
    func beginAutomaticBottomScroll(force: Bool = false) -> Bool {
        guard force || canAutomaticallyFollow || automaticBottomRequestOutstanding else { return false }
        isNativeUserOwned = false
        pendingNativeUserGeometry = false
        hadUserInteraction = false
        isUserDrivenSettling = false
        automaticBottomRequestOutstanding = true
        return true
    }

    /// Opening owns the viewport before the transcript is interactive. Repeated
    /// bounded positioning observations may therefore reissue the same command,
    /// while normal automatic following remains coalesced.
    func beginOpeningBottomScroll() {
        isNativeUserOwned = false
        pendingNativeUserGeometry = false
        hadUserInteraction = false
        isUserDrivenSettling = false
        automaticBottomRequestOutstanding = true
    }

    func confirmAutomaticBottomScroll(_ geometry: ChatTranscriptGeometry) {
        isAtBottom = geometry.isAtBottom
        guard geometry.isAtExactBottom else { return }
        automaticBottomRequestOutstanding = false
        userScrolledAway = false
        hasUnreadContent = false
        pendingGrowthFollow = false
    }

    func semanticResponseArrived() {
        if userScrolledAway { hasUnreadContent = true }
    }

    func beginPrependingHistory() {
        isPrependingHistory = true
        pendingGrowthFollow = false
    }

    func endPrependingHistory(preserveScrolledAway: Bool) {
        isPrependingHistory = false
        userScrolledAway = preserveScrolledAway
        isAtBottom = !preserveScrolledAway && isAtBottom
    }

    func clearUnreadAfterExplicitJump() {
        userScrolledAway = false
        hasUnreadContent = false
    }

    private func commitScrollAway() {
        userScrolledAway = true
        isAtBottom = false
        automaticBottomRequestOutstanding = false
        pendingGrowthFollow = false
    }

    private func releaseAtBottom() {
        isAtBottom = true
        userScrolledAway = false
        hasUnreadContent = false
        automaticBottomRequestOutstanding = false
        pendingGrowthFollow = false
        if !isUserInteracting {
            isNativeUserOwned = false
            pendingNativeUserGeometry = false
            isUserDrivenSettling = false
        }
    }

    private static func isDirectUserPhase(_ phase: ScrollPhase) -> Bool {
        phase == .interacting || phase == .tracking || phase == .decelerating
    }
}
