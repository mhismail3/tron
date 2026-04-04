import SwiftUI

/// Suggestion chips revealed below the input bar with a backdrop blur.
/// Has its own easy-dismiss drag gesture (lower threshold than the input bar pull-up).
@available(iOS 26.0, *)
struct PullUpPanelView: View {
    @Bindable var panelState: PullUpPanelState
    var onSuggestionTapped: ((String) -> Void)?

    /// Drag offset local to the panel dismiss gesture.
    @State private var dismissOffset: CGFloat = 0

    /// Tracks which chip indices have appeared (drives stagger animation).
    @State private var visibleChips: Set<Int> = []

    /// Snapshot of suggestions used to detect new arrivals.
    @State private var lastSuggestionCount: Int = 0

    private static let dismissThreshold: CGFloat = 30
    private static let dismissVelocityThreshold: CGFloat = 150
    private static let staggerDelay: Double = 0.07

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if panelState.suggestions.isEmpty {
                Spacer()
            } else {
                panelContent
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: PullUpPanelState.expandedHeight)
        .contentShape(Rectangle())
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .offset(y: dismissOffset)
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    let raw = value.translation.height
                    guard raw > 0 else {
                        dismissOffset = 0
                        return
                    }
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
        .onChange(of: panelState.suggestions) { _, newSuggestions in
            guard newSuggestions.count != lastSuggestionCount else { return }
            lastSuggestionCount = newSuggestions.count
            visibleChips = []
            animateChipsIn(count: newSuggestions.count)
        }
        .onAppear {
            if !panelState.suggestions.isEmpty && visibleChips.isEmpty {
                animateChipsIn(count: panelState.suggestions.count)
            }
        }
    }

    // MARK: - Stagger Animation

    private func animateChipsIn(count: Int) {
        for index in 0..<count {
            let delay = Self.staggerDelay * Double(index)
            _ = withAnimation(.spring(response: 0.4, dampingFraction: 0.75).delay(delay)) {
                visibleChips.insert(index)
            }
        }
    }

    // MARK: - Panel Content

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suggestions")
                .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 4)

            ForEach(Array(panelState.suggestions.enumerated()), id: \.offset) { index, suggestion in
                let isVisible = visibleChips.contains(index)

                Button {
                    onSuggestionTapped?(suggestion)
                } label: {
                    Text(suggestion)
                        .font(TronTypography.mono(size: TronTypography.sizeBodySM, weight: .semibold))
                        .foregroundStyle(.tronEmerald)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .chipStyle(.tronEmerald, tintOpacity: 0.25, strokeOpacity: 0.3)
                .opacity(isVisible ? 1 : 0)
                .offset(y: isVisible ? 0 : 12)
            }
        }
        .padding(16)
    }
}
