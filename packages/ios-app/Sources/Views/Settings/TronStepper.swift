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
                .frame(height: 20)

            stepperButton(systemName: "plus", enabled: canIncrement) {
                value = min(range.upperBound, value + step)
            }
        }
        .background(
            Capsule(style: .continuous)
                .fill(Color.tronEmerald.opacity(colorScheme == .dark ? 0.12 : 0.08))
        )
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
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
                .frame(width: 44, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(StepperButtonStyle(enabled: enabled))
        .disabled(!enabled)
    }
}

/// Button style that provides a subtle scale + opacity press feedback.
private struct StepperButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed && enabled ? 0.5 : 1)
            .scaleEffect(configuration.isPressed && enabled ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
