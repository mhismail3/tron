import SwiftUI

/// Liquid glass container revealed below the input bar.
/// Has its own easy-dismiss drag gesture (lower threshold than the input bar pull-up).
@available(iOS 26.0, *)
struct PullUpPanelView: View {
    @Bindable var panelState: PullUpPanelState
    var onSuggestionTapped: ((String) -> Void)?

    /// Drag offset local to the panel dismiss gesture.
    @State private var dismissOffset: CGFloat = 0

    private static let dismissThreshold: CGFloat = 30
    private static let dismissVelocityThreshold: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            if panelState.suggestions.isEmpty {
                Spacer()
            } else {
                suggestionChips
            }
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

    // MARK: - Suggestion Chips

    private var suggestionChips: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(panelState.suggestions, id: \.self) { suggestion in
                    Button {
                        onSuggestionTapped?(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
