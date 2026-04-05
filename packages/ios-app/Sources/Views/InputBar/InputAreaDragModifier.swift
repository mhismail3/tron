import SwiftUI
import UIKit

/// Long-press-and-drag gesture on the input bar to reveal the suggestion row.
///
/// Hold for 0.3s → haptic + lift-off animation → drag/flick up to expand.
/// When expanded, a simple swipe down on the input bar collapses.
@available(iOS 26.0, *)
struct InputAreaDragModifier: ViewModifier {
    @Bindable var panelState: PullUpPanelState
    var isDisabled: Bool = false
    var onWillExpand: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .offset(y: panelState.dragOffset)
            .scaleEffect(panelState.isHoldActive ? 1.02 : 1.0)
            .shadow(
                color: panelState.isHoldActive ? .black.opacity(0.15) : .clear,
                radius: panelState.isHoldActive ? 8 : 0,
                y: panelState.isHoldActive ? 4 : 0
            )
            .gesture(!isDisabled && panelState.isExpanded ? dismissDragGesture : nil)
            .gesture(!isDisabled && !panelState.isExpanded ? holdAndDragGesture : nil)
    }

    // MARK: - Expand Gesture (long press + drag)

    private var holdAndDragGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .onChanged { _ in }
            .onEnded { _ in
                guard !panelState.isDragDisabled else { return }
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    panelState.isHoldActive = true
                }
            }
            .sequenced(before:
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        guard panelState.isHoldActive else { return }
                        let raw = value.translation.height
                        guard raw < 0 else {
                            panelState.dragOffset = 0
                            return
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
                        let shouldExpand = distance > PullUpPanelState.dragThreshold
                            || velocity < -PullUpPanelState.velocityThreshold

                        if shouldExpand {
                            onWillExpand?()
                        }

                        withAnimation(.tronSnap) {
                            panelState.dragOffset = 0
                            panelState.isHoldActive = false
                            if shouldExpand {
                                panelState.position = .expanded
                            }
                        }
                    }
            )
    }

    // MARK: - Dismiss Gesture (simple swipe down when expanded)

    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let raw = value.translation.height
                guard raw > 0 else {
                    panelState.dragOffset = 0
                    return
                }
                panelState.dragOffset = raw * 0.6
            }
            .onEnded { value in
                let distance = panelState.dragOffset
                let velocity = value.predictedEndLocation.y - value.location.y
                let shouldDismiss = distance > 20 || velocity > 120

                withAnimation(.tronSnap) {
                    panelState.dragOffset = 0
                    if shouldDismiss {
                        panelState.position = .collapsed
                    }
                }
            }
    }

    // MARK: - Rubber-Band Physics

    static func rubberBand(_ rawOffset: CGFloat, limit: CGFloat, factor: CGFloat) -> CGFloat {
        let sign: CGFloat = rawOffset < 0 ? -1 : 1
        let magnitude = abs(rawOffset)
        return sign * factor * limit * log2(1 + magnitude / limit)
    }
}
