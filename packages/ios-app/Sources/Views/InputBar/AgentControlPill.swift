import SwiftUI

// MARK: - Agent Control Pill (iOS 26 Liquid Glass)

/// Pill button showing model name and context percentage. Opens the Agent Control sheet.
@available(iOS 26.0, *)
struct AgentControlPill: View {
    // Context info
    let contextPercentage: Int

    // Model info
    var modelName: String?

    // Animation state
    let hasAppeared: Bool

    // Actions
    var onTap: (() -> Void)?

    // Read-only mode
    var readOnly: Bool = false

    // MARK: - Helpers

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
        Button {
            onTap?()
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
        .scaleEffect(hasAppeared ? 1 : 0.3, anchor: .bottom)
        .opacity(hasAppeared ? (readOnly ? 0.5 : 1.0) : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: hasAppeared)
        .disabled(readOnly)
    }
}
