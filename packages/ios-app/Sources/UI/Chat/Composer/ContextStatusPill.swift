import SwiftUI

// MARK: - Context Status Pill

struct ContextStatusPill: View {
    let contextPercentage: Int
    var modelName: String?
    let hasAppeared: Bool
    var readOnly: Bool = false

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

    var body: some View {
        HStack(spacing: 0) {
            Text(readOnly ? "-" : displayModelName)
                .foregroundStyle(readOnly ? .tronEmerald.opacity(0.5) : .tronEmerald)

            Text(readOnly ? "" : " • \(contextPercentage)%")
                .foregroundStyle(readOnly ? .tronEmerald.opacity(0.5) : contextPercentageColor)
        }
        .font(TronTypography.pillValue)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular.tint(Color.tronPhthaloGreen.opacity(0.25)), in: .capsule)
        .scaleEffect(hasAppeared ? 1 : 0.3, anchor: .bottom)
        .opacity(hasAppeared ? (readOnly ? 0.5 : 1.0) : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: hasAppeared)
        .accessibilityLabel("Context status")
        .accessibilityValue(readOnly ? "Read only" : "\(displayModelName), \(contextPercentage)%")
    }
}
