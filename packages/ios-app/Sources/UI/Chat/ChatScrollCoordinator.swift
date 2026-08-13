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
    private var prependInterruptedByUser = false

    var canAutomaticallyFollow: Bool {
        !userScrolledAway
            && !isUserInteracting
            && !isNativeUserOwned
            && !pendingNativeUserGeometry
            && !isUserDrivenSettling
            && !isPrependingHistory
    }

    /// Prepend correction may continue across asynchronous row layout, but a new
    /// gesture permanently transfers ownership back to the user.
    var canRestorePrependPosition: Bool {
        isPrependingHistory && !prependInterruptedByUser && !isUserInteracting
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
        prependInterruptedByUser = false
    }

    func scrollPositionChanged(isPositionedByUser: Bool) {
        if isPositionedByUser {
            pendingNativeUserGeometry = true
            if isPrependingHistory { prependInterruptedByUser = true }
        }
        isNativeUserOwned = isPositionedByUser
        if isPositionedByUser, !isAtBottom {
            commitScrollAway()
        }
    }

    /// Returns true when deferred transcript growth should issue one bottom
    /// command now that direct interaction or an in-flight command has settled.
    @discardableResult
    func scrollPhaseChanged(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        finalGeometry: ChatTranscriptGeometry?
    ) -> Bool {
        if newPhase == .idle, let finalGeometry {
            _ = geometryChanged(previous: finalGeometry, current: finalGeometry)
        }

        let wasInteracting = isUserInteracting
        let wasUserDrivenSettling = isUserDrivenSettling
        isUserInteracting = Self.isDirectUserPhase(newPhase)
        isUserDrivenSettling = newPhase == .animating
            && (wasUserDrivenSettling || Self.isDirectUserPhase(oldPhase))

        if isUserInteracting && !wasInteracting {
            hadUserInteraction = true
            if isPrependingHistory { prependInterruptedByUser = true }
        }
        if wasInteracting && !isUserInteracting,
           finalGeometry?.isAtExactBottom != true {
            commitScrollAway()
        }

        guard newPhase == .idle else { return false }
        if finalGeometry?.isAtExactBottom == true {
            releaseAtBottom()
            return false
        }

        // A nonanimated request can be coalesced before reaching the newest
        // extent. Preserve one retry opportunity instead of silently dropping it.
        if automaticBottomRequestOutstanding, !userScrolledAway {
            pendingGrowthFollow = true
        }
        guard pendingGrowthFollow, canAutomaticallyFollow else { return false }
        pendingGrowthFollow = false
        automaticBottomRequestOutstanding = true
        return true
    }

    /// Returns true exactly when measured transcript growth should issue one
    /// automatic bottom command. Progress-only updates with no height delta do not.
    @discardableResult
    func geometryChanged(
        previous: ChatTranscriptGeometry,
        current: ChatTranscriptGeometry
    ) -> Bool {
        let previousAtBottom = isAtBottom
        let grew = current.contentHeight > previous.contentHeight + 0.5
        let hasUserAttribution = isUserInteracting
            || hadUserInteraction
            || isNativeUserOwned
            || pendingNativeUserGeometry
            || isUserDrivenSettling

        isAtBottom = current.isAtBottom
        if hasUserAttribution && !current.isAtExactBottom {
            commitScrollAway()
        } else if current.isAtExactBottom {
            releaseAtBottom()
        }

        pendingNativeUserGeometry = false
        if !isUserInteracting { hadUserInteraction = false }

        if automaticBottomRequestOutstanding {
            if grew, !userScrolledAway { pendingGrowthFollow = true }
            return false
        }

        guard previous.isValid,
              grew,
              previousAtBottom,
              canAutomaticallyFollow else {
            if grew, previousAtBottom, !userScrolledAway {
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
        guard current.isViewportOnlyChange(from: previous) else { return }
        if current.isAtExactBottom {
            releaseAtBottom()
        } else if isUserInteracting || isNativeUserOwned || pendingNativeUserGeometry {
            commitScrollAway()
        } else if previous.isAtBottom || isAtBottom {
            // Preserve logical pinned ownership while SwiftUI applies the safe-
            // area inset. The inset itself must not issue a scroll command.
            isAtBottom = true
        } else {
            isAtBottom = current.isAtBottom
        }
        pendingNativeUserGeometry = false
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

    /// Opening owns the viewport before the transcript becomes interactive.
    /// Positioning remains best-effort and never participates in readiness.
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
        releaseAtBottom()
    }

    func semanticResponseArrived() {
        if userScrolledAway { hasUnreadContent = true }
    }

    func beginPrependingHistory() {
        isPrependingHistory = true
        prependInterruptedByUser = false
        pendingGrowthFollow = false
    }

    func endPrependingHistory(preserveScrolledAway: Bool) {
        isPrependingHistory = false
        pendingGrowthFollow = false
        guard !prependInterruptedByUser else {
            prependInterruptedByUser = false
            return
        }
        userScrolledAway = preserveScrolledAway
        if preserveScrolledAway { isAtBottom = false }
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
