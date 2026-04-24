import SwiftUI

/// Primary CTA: filled emerald capsule that scales on press, lifts on
/// hover, and animates color shifts smoothly. Replaces SwiftUI's
/// `.buttonStyle(.borderedProminent)` for the wizard's main actions so
/// the modal feels alive rather than system-default — and so the
/// brand emerald is locked in regardless of the user's system accent
/// color or any local `.tint(_:)` override.
struct WizardPrimaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .padding(.horizontal, 24)
            .background(
                Capsule(style: .continuous)
                    // Mint→emerald gradient gives the capsule visible
                    // depth without losing the brand color at a glance.
                    .fill(LinearGradient.tronEmeraldGradient)
                    .brightness(configuration.isPressed ? -0.06 : (isHovering ? 0.04 : 0))
                    .shadow(
                        color: Color.tronEmerald.opacity(isHovering ? 0.55 : 0.30),
                        radius: isHovering ? 16 : 9,
                        x: 0,
                        y: isHovering ? 7 : 3
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovering ? 1.015 : 1.0))
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(Capsule())
    }
}

/// Tertiary CTA: borderless emerald text link that lifts on hover and
/// dims on press. Used for "I already have Tron running" and similar
/// secondary actions. Idle state is a softened emerald (so the link
/// doesn't compete with the primary CTA), hover snaps to full emerald.
struct WizardLinkButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundStyle(textColor(pressed: configuration.isPressed))
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
    }

    private func textColor(pressed: Bool) -> Color {
        if pressed { return Color.tronEmeraldDeep.opacity(0.7) }
        return isHovering ? Color.tronMint : Color.tronEmerald.opacity(0.75)
    }
}

/// Secondary CTA: emerald-outlined capsule. Used when a step has two
/// equally-weighted actions (e.g. "Skip" / "Continue"). The stroke +
/// label both use emerald so secondary buttons read as part of the
/// brand even when sitting beside the gradient-filled primary CTA.
struct WizardSecondaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.medium))
            .foregroundStyle(Color.tronEmerald)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(
                Capsule(style: .continuous)
                    .strokeBorder(
                        Color.tronEmerald.opacity(isHovering ? 0.65 : 0.35),
                        lineWidth: 1
                    )
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.tronEmerald.opacity(configuration.isPressed ? 0.18 : (isHovering ? 0.10 : 0)))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == WizardPrimaryButtonStyle {
    static var wizardPrimary: WizardPrimaryButtonStyle { WizardPrimaryButtonStyle() }
}
extension ButtonStyle where Self == WizardLinkButtonStyle {
    static var wizardLink: WizardLinkButtonStyle { WizardLinkButtonStyle() }
}
extension ButtonStyle where Self == WizardSecondaryButtonStyle {
    static var wizardSecondary: WizardSecondaryButtonStyle { WizardSecondaryButtonStyle() }
}
