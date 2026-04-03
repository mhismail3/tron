import SwiftUI

/// Applies a vertical drag gesture with rubber-band resistance to toggle
/// the pull-up panel between collapsed and expanded positions.
@available(iOS 26.0, *)
struct InputAreaDragModifier: ViewModifier {
    @Bindable var panelState: PullUpPanelState
    var onWillExpand: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .offset(y: panelState.dragOffset)
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        let raw = value.translation.height

                        // Direction lock: only respond to the correct direction
                        switch panelState.position {
                        case .collapsed:
                            // Only respond to upward pull (negative translation)
                            guard raw < 0 else {
                                panelState.dragOffset = 0
                                return
                            }
                        case .expanded:
                            // Only respond to downward pull (positive translation)
                            guard raw > 0 else {
                                panelState.dragOffset = 0
                                return
                            }
                        }

                        panelState.dragOffset = Self.rubberBand(
                            raw,
                            limit: PullUpPanelState.expandedHeight,
                            factor: PullUpPanelState.rubberBandFactor
                        )
                    }
                    .onEnded { value in
                        let distance = abs(panelState.dragOffset)
                        let velocity = value.predictedEndLocation.y - value.location.y

                        // Check if we should toggle position
                        let distanceTriggered = distance > PullUpPanelState.dragThreshold
                        let velocityTriggered: Bool
                        switch panelState.position {
                        case .collapsed:
                            // Upward flick = negative velocity
                            velocityTriggered = velocity < -PullUpPanelState.velocityThreshold
                        case .expanded:
                            // Downward flick = positive velocity
                            velocityTriggered = velocity > PullUpPanelState.velocityThreshold
                        }

                        let shouldToggle = distanceTriggered || velocityTriggered

                        if shouldToggle && !panelState.isExpanded {
                            onWillExpand?()
                        }

                        withAnimation(.tronSnap) {
                            panelState.dragOffset = 0
                            if shouldToggle {
                                panelState.position = panelState.isExpanded ? .collapsed : .expanded
                            }
                        }
                    }
            )
    }

    // MARK: - Rubber-Band Physics

    /// Logarithmic resistance curve: small drags feel near-1:1, large drags attenuate.
    /// - Parameters:
    ///   - rawOffset: Raw finger translation in points
    ///   - limit: Maximum meaningful offset (panel height)
    ///   - factor: Resistance multiplier (0.0–1.0, lower = more resistant)
    /// - Returns: Visually attenuated offset
    static func rubberBand(_ rawOffset: CGFloat, limit: CGFloat, factor: CGFloat) -> CGFloat {
        let sign: CGFloat = rawOffset < 0 ? -1 : 1
        let magnitude = abs(rawOffset)
        return sign * factor * limit * log2(1 + magnitude / limit)
    }
}
