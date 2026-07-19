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
    var messageViewportFrames: [UUID: CGRect] = [:]
    var isNearTopHistoryDetent = false
    var hasConsumedTopHistoryDetent = false

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
