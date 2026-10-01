import Foundation

// The chat viewport values ChatInteractionTrace records: the scroll commands and
// layout mutations that move the viewport, and the transcript geometry and
// physical-tail verdict they are judged against. The views and coordinators
// that produce them stay in UI/Chat; the viewport mode state machine is in
// ChatViewportMode.swift.

package enum ChatScrollAnimation: Equatable, Sendable {
    case disabled
    case smooth(duration: Double)
}

package struct ChatScrollCommand: Equatable, Sendable {
    package enum Origin: Equatable, Sendable {
        case presentation
        case catchUp
        case oldestHistory
        case layout
        case prepend
    }

    package enum Destination: Equatable, Sendable {
        case tail
        case oldestHistory
        /// Exact semantic row target used when restoring a reader's position.
        case row(String)
        case offsetY(CGFloat)
    }

    package let token: Int
    package let presentation: Int
    package let origin: Origin
    package let destination: Destination
    package let animation: ChatScrollAnimation

    package init(token: Int, presentation: Int, origin: Origin, destination: Destination, animation: ChatScrollAnimation) {
        self.token = token
        self.presentation = presentation
        self.origin = origin
        self.destination = destination
        self.animation = animation
    }
}

package enum ChatLayoutMutation: Hashable, Sendable {
    case keyboard
    case submission
    case transcriptGrowth
}

package enum ChatPhysicalTailClassification: Equatable, Sendable {
    case aligned
    case belowViewport
    case aboveViewport
    case incomplete
    case stale
}

package struct ChatTranscriptGeometry: Equatable {
    package let offsetY: CGFloat
    package let contentHeight: CGFloat
    package let containerHeight: CGFloat
    package let bottomInset: CGFloat
    /// Native visible content edges in the scroll content coordinate space.
    /// Synthetic tests may omit them and use the legacy-field fallback.
    package let visibleTopY: CGFloat?
    let visibleBottomY: CGFloat?

    package init(
        offsetY: CGFloat,
        contentHeight: CGFloat,
        containerHeight: CGFloat,
        bottomInset: CGFloat = 0,
        visibleTopY: CGFloat? = nil,
        visibleBottomY: CGFloat? = nil
    ) {
        self.offsetY = offsetY
        self.contentHeight = contentHeight
        self.containerHeight = containerHeight
        self.bottomInset = bottomInset
        self.visibleTopY = visibleTopY
        self.visibleBottomY = visibleBottomY
    }

    package static let zero = ChatTranscriptGeometry(offsetY: 0, contentHeight: 0, containerHeight: 0)
    // Zero-height content is a valid empty pinned presentation. The mounted
    // tail marker supplies the physical proof once SwiftUI has laid it out.
    package var isValid: Bool { contentHeight >= 0 && containerHeight > 0 }
    package var distanceFromBottom: CGFloat {
        // `visibleRect` is SwiftUI's native, atomically derived content-space
        // viewport. Do not reconstruct it from offset/container/inset fields,
        // which can settle in different LazyVStack/keyboard layout frames.
        let rawDistance = if let visibleBottomY {
            contentHeight + bottomInset - visibleBottomY
        } else {
            contentHeight + bottomInset - offsetY - containerHeight
        }
        guard rawDistance.isFinite else { return .greatestFiniteMagnitude }
        return max(0, rawDistance)
    }
    static let catchUpDistance: CGFloat = 16
    /// A marker frame, rather than clamped distance, is authoritative for
    /// short content. Under-sized content is bottom-aligned by the native
    /// anchor, so blank space after its edge is expected rather than drift.
    package var isPastBottomEdge: Bool {
        guard isValid else { return false }
        let contentBottom = contentHeight + bottomInset
        guard contentBottom.isFinite, offsetY.isFinite else { return false }
        // A visible edge beyond a short content edge is normal bottom-aligned
        // blank space, but an offset below the legal bottom is impossible and
        // must not be mistaken for an underflow presentation.
        let maximumOffset = max(0, contentBottom - containerHeight)
        if let visibleBottomY {
            guard visibleBottomY.isFinite else { return false }
            if contentBottom <= containerHeight + 2 {
                // A short transcript naturally leaves blank space below its
                // content. An in-bounds visible edge still cannot accompany an
                // offset below the legal bottom.
                return visibleBottomY <= contentBottom + 2
                    && offsetY > maximumOffset + 2
            }
            return offsetY > maximumOffset + 2
                || visibleBottomY > contentBottom + 2
        }
        return offsetY > maximumOffset + 2
    }
    package var hasScrollableOverflow: Bool {
        let contentBottom = contentHeight + bottomInset
        return isValid && contentBottom.isFinite && contentBottom > containerHeight + 2
    }
    /// Native short-content alignment is legal only for a plausible viewport;
    /// current marker evidence, not a fabricated minimum height, proves its tail.
    package var isNativeUnderflow: Bool { !hasScrollableOverflow && isPlausibleOpeningViewport }
    package var isAtBottom: Bool { isValid && !isPastBottomEdge && distanceFromBottom <= 80 }
    var isAtExactBottom: Bool { isValid && !isPastBottomEdge && distanceFromBottom <= 2 }
    /// Physical scroll settling commonly stops a few points above the computed
    /// edge because content insets and pixel rounding update in separate frames.
    /// This tighter-than-"near bottom" boundary is user-equivalent to reaching
    /// the tail and is used to dismiss catch-up without requiring a tap.
    package var isAtCatchUpBoundary: Bool {
        isValid && !isPastBottomEdge && distanceFromBottom <= Self.catchUpDistance
    }

    /// Opening accepts short content at the native bottom anchor. For overflow
    /// content the visible tail edge still rejects a transient overshoot.
    package var isPlausibleOpeningViewport: Bool {
        guard isValid else { return false }
        let contentBottom = contentHeight + bottomInset
        guard contentBottom.isFinite, offsetY.isFinite else { return false }
        let maximumOffset = max(0, contentBottom - containerHeight)
        if let visibleBottomY {
            guard visibleBottomY.isFinite else { return false }
            if contentBottom <= containerHeight + 2 {
                // Native underflow alignment may expose legal blank space after
                // the short content edge.
                return visibleBottomY > contentBottom + 2
                    || offsetY <= maximumOffset + 2
            }
            return offsetY <= maximumOffset + 2
                && visibleBottomY <= contentBottom + 2
        }
        return offsetY <= maximumOffset + 2
    }

    /// A direct native viewport move changes the content offset or visible
    /// content rect without changing the measured layout. Keyboard, composer,
    /// and row-size changes are structural and cannot impersonate user intent.
    package func hasIndependentViewportMovement(from previous: Self) -> Bool {
        guard !hasStructuralChange(from: previous) else { return false }
        if abs(offsetY - previous.offsetY) > 0.5 { return true }
        if let current = visibleTopY, let prior = previous.visibleTopY,
           abs(current - prior) > 0.5 { return true }
        if let current = visibleBottomY, let prior = previous.visibleBottomY,
           abs(current - prior) > 0.5 { return true }
        return false
    }

    package func hasStructuralChange(from previous: Self) -> Bool {
        abs(containerHeight - previous.containerHeight) > 0.5
            || abs(bottomInset - previous.bottomInset) > 0.5
            || abs(contentHeight - previous.contentHeight) > 0.5
    }

    package var isPlausibleBottomRubberBand: Bool {
        guard isPastBottomEdge, hasScrollableOverflow else { return false }
        let legalBottom = max(0, contentHeight + bottomInset - containerHeight)
        let overscroll = max(0, offsetY - legalBottom)
        let tolerance = min(160, max(48, containerHeight * 0.25))
        return overscroll <= tolerance
    }


}
