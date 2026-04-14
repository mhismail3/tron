import SwiftUI

// MARK: - Status Pills Column (iOS 26 Liquid Glass)

/// Status pill column: agent control pill showing model name and context percentage.
@available(iOS 26.0, *)
struct StatusPillsColumn: View {
    // Context info
    let contextPercentage: Int
    let contextWindow: Int
    let lastTurnInputTokens: Int

    // Model info
    var modelName: String?

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

    private var displayModelName: String {
        modelName ?? "—"
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            agentControlPill
                .scaleEffect(hasAppeared ? 1 : 0.3, anchor: .bottom)
                .opacity(hasAppeared ? 1 : 0)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: hasAppeared)
    }

    // MARK: - Agent Control Pill

    private var agentControlPill: some View {
        Button {
            onContextTap?()
        } label: {
            HStack(spacing: 0) {
                Text(readOnly ? "—" : displayModelName)
                    .foregroundStyle(readOnly ? .tronEmerald.opacity(0.5) : .tronEmerald)

                Text(readOnly ? "" : " • \(contextPercentage)%")
                    .foregroundStyle(readOnly ? .tronEmerald.opacity(0.5) : contextPercentageColor)
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
