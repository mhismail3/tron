import CoreGraphics

/// Owns the first-open transcript reveal invariant for chat sessions.
///
/// Existing sessions can take a short moment to reconstruct and settle their
/// bottom scroll anchor. During that window the shell keeps transcript content
/// hidden while the composer placeholder carries the loading status, then fades
/// the already-bottom-anchored content in once initial load is complete.
enum ChatTranscriptRevealPolicy {
    static let initialBottomTolerance: CGFloat = 16
    static let initialStableBottomSamples = 2
    static let initialBottomSettleAttempts = 36
    static let initialScrollProxyWaitAttempts = 20
    static let initialSettleDelayMilliseconds = 60
    static let autoscrollBottomTolerance: CGFloat = 100

    static func contentOpacity(initialLoadComplete: Bool) -> Double {
        initialLoadComplete ? 1 : 0
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
