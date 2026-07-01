import SwiftUI

// MARK: - Floating New Session Button (iOS 26 Liquid Glass)

internal enum FloatingNewSessionButtonAccessibility {
    static let label = "New Session"
    static let hint = "Opens the new session sheet"
}

struct FloatingNewSessionButton: View {
    let action: () -> Void
    var onLongPress: (() -> Void)?
    var size: CGFloat = 44
    var accent: Color = .tronEmerald

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(TronTypography.sans(size: TronTypography.sizeXL, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(accent.opacity(0.25)).interactive(), in: .circle)
        .accessibilityLabel(FloatingNewSessionButtonAccessibility.label)
        .accessibilityHint(FloatingNewSessionButtonAccessibility.hint)
        .onLongPressGesture(minimumDuration: 0.5) {
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
            onLongPress?() ?? action()
        }
    }
}
