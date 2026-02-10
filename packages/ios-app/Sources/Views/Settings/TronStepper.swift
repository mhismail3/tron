import SwiftUI

/// Themed stepper that renders +/- buttons with emerald tint,
/// matching the settings UI in both light and dark mode.
struct TronStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1

    @Environment(\.colorScheme) private var colorScheme

    private var canDecrement: Bool { value - step >= range.lowerBound }
    private var canIncrement: Bool { value + step <= range.upperBound }

    var body: some View {
        HStack(spacing: 0) {
            stepperButton(systemName: "minus", enabled: canDecrement) {
                value = max(range.lowerBound, value - step)
            }

            Divider()
                .frame(height: 18)

            stepperButton(systemName: "plus", enabled: canIncrement) {
                value = min(range.upperBound, value + step)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.tronEmerald.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.tronEmerald.opacity(0.25), lineWidth: 0.5)
        )
        .fixedSize()
    }

    @ViewBuilder
    private func stepperButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(enabled ? .tronEmerald : .tronTextDisabled)
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
