import SwiftUI

/// Horizontal scrollable row of suggestion chips revealed below the input bar.
@available(iOS 26.0, *)
struct PullUpPanelView: View {
    @Bindable var panelState: PullUpPanelState
    var onSuggestionTapped: ((String) -> Void)?

    /// Tracks which chip indices have appeared (drives stagger animation).
    @State private var visibleChips: Set<Int> = []

    /// Snapshot of suggestions used to detect new arrivals.
    @State private var lastSuggestionCount: Int = 0

    private static let staggerDelay: Double = 0.06

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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
                    .scaleEffect(isVisible ? 1 : 0.8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .scrollClipDisabled()
        .fixedSize(horizontal: false, vertical: true)
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
}
