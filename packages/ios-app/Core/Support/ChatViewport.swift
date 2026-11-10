import Foundation

package enum ChatScrollAnimation: Equatable, Sendable {
    case disabled
    case smooth(duration: Double)
}

package struct ChatScrollCommand: Equatable, Sendable {
    package enum Origin: Equatable, Sendable {
        case catchUp
        case oldestHistory
        case layout
        case prepend
        case annotationReveal
    }

    package enum Destination: Equatable, Sendable {
        case tail
        case oldestHistory
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
    package var isValid: Bool { contentHeight >= 0 && containerHeight > 0 }
    package var distanceFromBottom: CGFloat {
        let rawDistance = if let visibleBottomY {
            contentHeight + bottomInset - visibleBottomY
        } else {
            contentHeight + bottomInset - offsetY - containerHeight
        }
        guard rawDistance.isFinite else { return .greatestFiniteMagnitude }
        return max(0, rawDistance)
    }
    static let catchUpDistance: CGFloat = 16
    package var isPastBottomEdge: Bool {
        guard isValid else { return false }
        let contentBottom = contentHeight + bottomInset
        guard contentBottom.isFinite, offsetY.isFinite else { return false }
        let maximumOffset = max(0, contentBottom - containerHeight)
        if let visibleBottomY {
            guard visibleBottomY.isFinite else { return false }
            if contentBottom <= containerHeight + 2 {
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
    package var isNativeUnderflow: Bool { !hasScrollableOverflow && isPlausibleOpeningViewport }
    package var isAtBottom: Bool { isValid && !isPastBottomEdge && distanceFromBottom <= 80 }
    package var isAtCatchUpBoundary: Bool {
        isValid && !isPastBottomEdge && distanceFromBottom <= Self.catchUpDistance
    }

    package var isPlausibleOpeningViewport: Bool {
        guard isValid else { return false }
        let contentBottom = contentHeight + bottomInset
        guard contentBottom.isFinite, offsetY.isFinite else { return false }
        let maximumOffset = max(0, contentBottom - containerHeight)
        if let visibleBottomY {
            guard visibleBottomY.isFinite else { return false }
            if contentBottom <= containerHeight + 2 {
                return visibleBottomY > contentBottom + 2
                    || offsetY <= maximumOffset + 2
            }
            return offsetY <= maximumOffset + 2
                && visibleBottomY <= contentBottom + 2
        }
        return offsetY <= maximumOffset + 2
    }

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
