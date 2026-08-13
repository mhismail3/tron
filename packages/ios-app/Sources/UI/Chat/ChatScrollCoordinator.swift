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
    private var userInteractionStartOffsetY: CGFloat?

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
        userInteractionStartOffsetY = nil
    }

    func scrollPositionChanged(isPositionedByUser: Bool) {
        if isPositionedByUser {
            pendingNativeUserGeometry = true
            if isPrependingHistory { prependInterruptedByUser = true }
        }
        // Native ownership alone is not scroll-away intent. In particular, it
        // can remain true while streamed growth moves the bottom underneath a
        // reader. Geometry direction decides whether the user moved upward.
        isNativeUserOwned = isPositionedByUser
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
            userInteractionStartOffsetY = finalGeometry?.offsetY
            if isPrependingHistory { prependInterruptedByUser = true }
        }

        guard newPhase == .idle else { return false }
        let movedTowardOlderContent = userInteractionStartOffsetY.map { start in
            guard let finalGeometry else { return false }
            return finalGeometry.offsetY < start - 1
        } ?? false
        userInteractionStartOffsetY = nil

        if finalGeometry?.isAtExactBottom == true {
            releaseAtBottom()
            return false
        }
        if wasInteracting,
           movedTowardOlderContent,
           (!isPrependingHistory || prependInterruptedByUser) {
            commitScrollAway()
            return false
        }

        // Idle ends transient native ownership only when no upward intent was
        // observed. This lets a pinned reader recover if growth and gesture-end
        // geometry were coalesced into one non-bottom sample.
        if !userScrolledAway {
            isNativeUserOwned = false
            pendingNativeUserGeometry = false
            isUserDrivenSettling = false
        }
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
        let movedTowardOlderContent = previous.isValid
            && current.offsetY < previous.offsetY - 1
        let hasUserAttribution = isUserInteracting
            || hadUserInteraction
            || isNativeUserOwned
            || pendingNativeUserGeometry
            || isUserDrivenSettling

        isAtBottom = current.isAtBottom
        if current.isAtExactBottom {
            releaseAtBottom()
        } else if hasUserAttribution,
                  movedTowardOlderContent,
                  (!isPrependingHistory || prependInterruptedByUser) {
            commitScrollAway()
        }

        pendingNativeUserGeometry = false
        if !isUserInteracting { hadUserInteraction = false }

        if automaticBottomRequestOutstanding {
            guard grew, !userScrolledAway else { return false }
            // Every measured height increase gets a fresh bottom command. A
            // nonanimated ScrollPosition write can be coalesced without an idle
            // phase, so waiting for acknowledgement loses the streaming edge.
            if canAutomaticallyFollow {
                pendingGrowthFollow = false
                return true
            }
            pendingGrowthFollow = true
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
        // Keyboard, composer, attachment-strip, and safe-area changes do not
        // express transcript navigation. Preserve the durable follow/detach mode
        // and wait for directional transcript geometry before changing ownership.
        isAtBottom = !userScrolledAway
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
        // The tap is explicit intent to resume following. Treat it as logically
        // pinned immediately so growth during the animated jump cannot detach it.
        isAtBottom = true
        userScrolledAway = false
        hasUnreadContent = false
        pendingGrowthFollow = false
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
