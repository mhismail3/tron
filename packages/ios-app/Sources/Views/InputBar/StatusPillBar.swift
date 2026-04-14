import SwiftUI

// MARK: - Status Pills Column (iOS 26 Liquid Glass)

/// Status pill column: token stats pill for context window access
/// Model and reasoning controls are available via the Agent Control sheet
@available(iOS 26.0, *)
struct StatusPillsColumn: View {
    // Context info
    let contextPercentage: Int
    let contextWindow: Int
    let lastTurnInputTokens: Int

    // Animation state
    let hasAppeared: Bool

    // Actions
    var onContextTap: (() -> Void)?

    // Read-only mode
    var readOnly: Bool = false

    // MARK: - Context Helpers

    private var contextPercentageColor: Color {
        if contextPercentage >= 95 {
            return .tronError
        } else if contextPercentage >= 80 {
            return .tronAmber
        }
        return .tronEmerald
    }

    private var tokensRemaining: Int {
        max(0, contextWindow - lastTurnInputTokens)
    }

    private var formattedTokensRemaining: String {
        TokenFormatter.format(tokensRemaining)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            tokenStatsPillWithChevrons
                .scaleEffect(hasAppeared ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared ? 1 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: hasAppeared)
    }

    // MARK: - Token Stats Pill

    private var tokenStatsPillWithChevrons: some View {
        Button {
            onContextTap?()
        } label: {
            HStack(spacing: 8) {
                // Context usage bar - use overlay + clipShape to prevent overflow
                Capsule()
                    .fill(Color.tronOverlay(0.2))
                    .frame(width: 40, height: 6)
                    .overlay(alignment: .leading) {
                        // Fill rectangle that gets clipped by parent Capsule shape
                        Rectangle()
                            .fill(readOnly ? Color.tronEmerald.opacity(0.3) : contextPercentageColor)
                            .frame(width: readOnly ? 0 : 40 * min(CGFloat(contextPercentage) / 100.0, 1.0))
                    }
                    .clipShape(Capsule())

                // Tokens remaining + Chevrons (spacing: 4 to match model pill)
                HStack(spacing: 4) {
                    Text(readOnly ? "—" : "\(formattedTokensRemaining) left")
                        .foregroundStyle(readOnly ? .tronEmerald.opacity(0.5) : contextPercentageColor)

                    if !readOnly {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(TronTypography.labelSM)
                            .foregroundStyle(contextPercentageColor)
                    }
                }
            }
            .font(TronTypography.pillValue)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)).interactive(), in: .capsule)
        .opacity(readOnly ? 0.5 : 1.0)
        .disabled(readOnly)
    }
}
