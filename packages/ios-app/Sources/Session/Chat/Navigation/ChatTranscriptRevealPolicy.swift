import CoreGraphics

/// Owns the first-open transcript reveal invariant for chat sessions.
///
/// Existing sessions can take a short moment to reconstruct and settle their
/// scroll geometry. During that window the shell keeps transcript content hidden
/// while the composer placeholder carries the loading status. Undersized
/// transcripts reveal top-aligned; overflowing transcripts settle at the bottom.
enum ChatTranscriptRevealPolicy {
    static let initialBottomTolerance: CGFloat = 16
    static let initialStableBottomSamples = 2
    static let initialBottomSettleAttempts = 4
    static let initialScrollProxyWaitAttempts = 3
    static let initialScrollGeometryWaitAttempts = 3
    static let initialSettleDelayMilliseconds = 40
    static let initialShellLoadingBudgetMilliseconds = 5_000
    static let maximumTranscriptRevealDelayMilliseconds =
        initialScrollProxyWaitAttempts * 25
        + initialScrollGeometryWaitAttempts * 25
        + initialBottomSettleAttempts * initialSettleDelayMilliseconds
        + 80
    static let autoscrollBottomTolerance: CGFloat = 100
    static let scrollableOverflowTolerance: CGFloat = 1

    static func contentOpacity(initialLoadComplete: Bool) -> Double {
        initialLoadComplete ? 1 : 0
    }

    /// A delayed authoritative snapshot must never look like an empty chat.
    /// Cached messages are useful immediately while the server refreshes them;
    /// a genuinely empty session is known only after reconstruction commits.
    static func showsHistoryLoadingState(
        phase: ConversationHistoryPhase,
        hasMessages: Bool
    ) -> Bool {
        phase == .loading && !hasMessages
    }

    static func showsHistoryRecoveryState(
        phase: ConversationHistoryPhase,
        hasMessages: Bool
    ) -> Bool {
        phase == .recoverableFailure(hasCachedTranscript: false) && !hasMessages
    }

    static func bottomDistance(
        contentHeight: CGFloat,
        contentOffsetY: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat
    ) -> CGFloat {
        // SwiftUI reports the settled bottom roughly one effective bottom inset
        // above mathematical zero when a `safeAreaInset` input bar participates in
        // layout. Normalize that away so "at bottom" means the latest transcript
        // is pinned above the composer, not hidden below it.
        let rawDistance = contentHeight - contentOffsetY - containerHeight - bottomInset
        guard rawDistance.isFinite else { return .greatestFiniteMagnitude }
        return max(0, rawDistance)
    }

    /// Initial reveal follows the actual scroll target, not the padded content
    /// extent whose safe-area and tail spacing can remain below that target.
    static func bottomAnchorDistance(
        viewportHeight: CGFloat,
        anchorMaxY: CGFloat
    ) -> CGFloat {
        let distance = anchorMaxY - viewportHeight
        guard distance.isFinite else { return .greatestFiniteMagnitude }
        return max(0, distance)
    }

    static func isNearBottomForAutoscroll(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom < autoscrollBottomTolerance
    }

    static func shouldFollowTransientTail(
        wasVisible: Bool,
        isVisible: Bool,
        initialLoadComplete: Bool
    ) -> Bool {
        initialLoadComplete && !wasVisible && isVisible
    }

    static func shouldReconcileAuthoritativeTranscript(
        historyWasProvisional: Bool,
        reconstructionCompleted: Bool,
        userScrolledAway: Bool,
        hasDeepLinkTarget: Bool
    ) -> Bool {
        historyWasProvisional
            && reconstructionCompleted
            && !userScrolledAway
            && !hasDeepLinkTarget
    }

    /// Whether the transcript has a real scroll range after accounting for the
    /// composer's effective bottom inset. Bottom positioning an undersized
    /// transcript can move the entire stack instead of scrolling content.
    static func hasScrollableOverflow(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat
    ) -> Bool {
        guard contentHeight.isFinite,
              viewportHeight.isFinite,
              bottomInset.isFinite,
              viewportHeight > 0 else {
            return true
        }
        return contentHeight - viewportHeight - max(0, bottomInset)
            > scrollableOverflowTolerance
    }

    static func shouldRevealAtTop(
        hasScrollGeometry: Bool,
        hasScrollableOverflow: Bool
    ) -> Bool {
        hasScrollGeometry && !hasScrollableOverflow
    }

    /// Before geometry exists, preserve the existing conservative behavior.
    /// Once measured, programmatic bottom requests are valid only if content
    /// can actually scroll.
    static func shouldRequestBottomPosition(
        hasScrollGeometry: Bool,
        hasScrollableOverflow: Bool
    ) -> Bool {
        !hasScrollGeometry || hasScrollableOverflow
    }

    static func isAtInitialBottom(distanceFromBottom: CGFloat) -> Bool {
        distanceFromBottom.isFinite
            && distanceFromBottom <= initialBottomTolerance
    }

    static func isReadyToReveal(
        hasScrollProxy: Bool,
        consecutiveBottomSamples: Int,
        distanceFromBottom: CGFloat
    ) -> Bool {
        hasScrollProxy
            && consecutiveBottomSamples >= initialStableBottomSamples
            && isAtInitialBottom(distanceFromBottom: distanceFromBottom)
    }
}
