import SwiftUI

/// Liquid glass container revealed below the input bar.
/// Has its own easy-dismiss drag gesture (lower threshold than the input bar pull-up).
@available(iOS 26.0, *)
struct PullUpPanelView: View {
    @Bindable var panelState: PullUpPanelState

    /// Drag offset local to the panel dismiss gesture.
    @State private var dismissOffset: CGFloat = 0

    private static let dismissThreshold: CGFloat = 30
    private static let dismissVelocityThreshold: CGFloat = 150

    var body: some View {
        VStack {
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .frame(height: PullUpPanelState.expandedHeight)
        .contentShape(Rectangle())
        .glassEffect(
            .regular.tint(Color.tronPhthaloGreen.opacity(0.15)),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .offset(y: dismissOffset)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    let raw = value.translation.height
                    // Only respond to downward pull
                    guard raw > 0 else {
                        dismissOffset = 0
                        return
                    }
                    // Light resistance — easier than input bar
                    dismissOffset = raw * 0.7
                }
                .onEnded { value in
                    let distance = dismissOffset
                    let velocity = value.predictedEndLocation.y - value.location.y

                    let shouldDismiss = distance > Self.dismissThreshold
                        || velocity > Self.dismissVelocityThreshold

                    withAnimation(.tronSnap) {
                        dismissOffset = 0
                        if shouldDismiss {
                            panelState.position = .collapsed
                        }
                    }
                }
        )
    }
}
