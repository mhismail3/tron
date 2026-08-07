import SwiftUI

/// Imperative geometry cache owned by the chat transcript UI.
///
/// This type is intentionally not observable. Scroll and preference callbacks can
/// publish several measurements during one LazyVStack layout pass; keeping those
/// values outside SwiftUI presentation state prevents a measurement from invalidating
/// the same layout that produced it.
@MainActor
final class ChatViewportMeasurements {
    var scrollProxy: ScrollViewProxy?
    private(set) var initialDistanceFromBottom: CGFloat = .infinity
    private(set) var messageViewportHeight: CGFloat = 0
    private(set) var initialBottomAnchorMaxY: CGFloat?
    private(set) var scrollContentHeight: CGFloat = 0
    private(set) var scrollBottomInset: CGFloat = 0
    private(set) var currentDistanceFromBottom: CGFloat = .infinity
    private(set) var hasScrollGeometry = false
    private(set) var hasScrollableOverflow = true
    private(set) var scrollGeometryMessageCount: Int?
    var messageViewportFrames: [UUID: CGRect] = [:]
    var isNearTopHistoryDetent = false
    var hasConsumedTopHistoryDetent = false

    /// Discard geometry measured for an empty/provisional projection before a
    /// new transcript owns initial positioning. This prevents a late snapshot
    /// from being classified using the shell's earlier empty content size.
    func beginTranscriptPositioning(messageCount: Int) {
        // A geometry callback can win the race and already describe this exact
        // transcript. Preserve that fresh sample; only invalidate a sample
        // produced for a different projection (most commonly the empty shell).
        guard scrollGeometryMessageCount != messageCount else { return }
        initialDistanceFromBottom = .infinity
        initialBottomAnchorMaxY = nil
        scrollContentHeight = 0
        scrollBottomInset = 0
        currentDistanceFromBottom = .infinity
        hasScrollGeometry = false
        hasScrollableOverflow = true
        scrollGeometryMessageCount = nil
    }

    func recordViewportHeight(_ viewportHeight: CGFloat) {
        guard viewportHeight.isFinite else { return }
        messageViewportHeight = max(0, viewportHeight)
        guard messageViewportHeight > 0, let initialBottomAnchorMaxY else {
            initialDistanceFromBottom = .infinity
            return
        }
        updateInitialBottomDistance(
            viewportHeight: messageViewportHeight,
            anchorMaxY: initialBottomAnchorMaxY
        )
    }

    func recordInitialBottomAnchor(maxY: CGFloat?) {
        guard let maxY, maxY.isFinite else {
            initialBottomAnchorMaxY = nil
            initialDistanceFromBottom = .infinity
            return
        }
        initialBottomAnchorMaxY = maxY
        updateInitialBottomDistance(
            viewportHeight: messageViewportHeight,
            anchorMaxY: maxY
        )
    }

    func recordScrollGeometry(
        contentHeight: CGFloat,
        viewportHeight: CGFloat,
        bottomInset: CGFloat,
        distanceFromBottom: CGFloat = .infinity,
        messageCount: Int? = nil
    ) {
        guard contentHeight.isFinite,
              viewportHeight.isFinite,
              bottomInset.isFinite,
              contentHeight >= 0,
              viewportHeight > 0 else {
            return
        }
        scrollContentHeight = contentHeight
        scrollBottomInset = max(0, bottomInset)
        currentDistanceFromBottom = distanceFromBottom.isFinite
            ? max(0, distanceFromBottom)
            : .infinity
        hasScrollGeometry = true
        scrollGeometryMessageCount = messageCount
        hasScrollableOverflow = ChatTranscriptRevealPolicy.hasScrollableOverflow(
            contentHeight: contentHeight,
            viewportHeight: viewportHeight,
            bottomInset: bottomInset
        )
        recordViewportHeight(viewportHeight)
    }

    private func updateInitialBottomDistance(
        viewportHeight: CGFloat,
        anchorMaxY: CGFloat
    ) {
        guard viewportHeight > 0 else { return }
        initialDistanceFromBottom = ChatTranscriptRevealPolicy.bottomAnchorDistance(
            viewportHeight: viewportHeight,
            anchorMaxY: anchorMaxY
        )
    }
}
