import SwiftUI

struct WizardPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.wizardButton)
            .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.72))
            .frame(minWidth: 132)
            .padding(.vertical, 11)
            .padding(.horizontal, 24)
            .background(skeuomorphicBackground(pressed: isEnabled && configuration.isPressed))
            .scaleEffect(isEnabled && configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovering)
            .onHover { isHovering = isEnabled && $0 }
            .contentShape(RoundedRectangle(cornerRadius: WizardLayout.buttonCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func skeuomorphicBackground(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: WizardLayout.buttonCornerRadius, style: .continuous)

        ZStack {
            if !isEnabled {
                shape
                    .fill(LinearGradient(
                        colors: [
                            Color.white.opacity(0.36),
                            Color.black.opacity(0.04),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                shape
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.8)
                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.35), Color.clear],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.5)
                        ),
                        lineWidth: 0.8
                    )
            } else {
                shape
                    .fill(LinearGradient(
                        colors: [Color.tronMint, Color.tronEmeraldDeep],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .brightness(pressed ? -0.05 : (isHovering ? 0.03 : 0))

                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: pressed
                                ? [Color.black.opacity(0.30), Color.clear]
                                : [Color.white.opacity(0.42), Color.clear],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.5)
                        ),
                        lineWidth: 1
                    )
                    .blendMode(pressed ? .normal : .plusLighter)

                shape
                    .strokeBorder(
                        LinearGradient(
                            colors: pressed
                                ? [Color.clear, Color.white.opacity(0.22)]
                                : [Color.clear, Color.black.opacity(0.28)],
                            startPoint: UnitPoint(x: 0.5, y: 0.5),
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .blendMode(pressed ? .plusLighter : .normal)
            }
        }
        .compositingGroup()
        .shadow(
            color: Color.tronEmerald.opacity(pressed ? 0.18 : (isHovering ? 0.50 : 0.32)),
            radius: isEnabled ? (pressed ? 3 : (isHovering ? 14 : 9)) : 0,
            x: 0,
            y: pressed ? 1 : (isHovering ? 6 : 3)
        )
        .shadow(
            color: Color.black.opacity(isEnabled ? (pressed ? 0.08 : 0.20) : 0.08),
            radius: isEnabled ? (pressed ? 1 : 4) : 1,
            x: 0,
            y: isEnabled ? (pressed ? 0 : 2) : 0.5
        )
    }
}

struct WizardLinkButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.wizardSecondaryButton)
            .foregroundStyle(textColor(pressed: configuration.isPressed))
            .padding(.vertical, 6)
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

struct WizardSecondaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(TronTypography.wizardSecondaryButton)
            .foregroundStyle(Color.tronEmerald)
            .padding(.vertical, 10)
            .padding(.horizontal, 22)
            .background(
                RoundedRectangle(cornerRadius: WizardLayout.buttonCornerRadius, style: .continuous)
                    .strokeBorder(
                        Color.tronEmerald.opacity(isHovering ? 0.65 : 0.35),
                        lineWidth: 1
                    )
                    .background(
                        RoundedRectangle(cornerRadius: WizardLayout.buttonCornerRadius, style: .continuous)
                            .fill(Color.tronEmerald.opacity(configuration.isPressed ? 0.18 : (isHovering ? 0.10 : 0)))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: WizardLayout.buttonCornerRadius, style: .continuous))
    }
}

struct WizardTertiaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(skeuomorphicBackground(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder
    private func skeuomorphicBackground(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

        ZStack {
            shape
                .fill(LinearGradient(
                    colors: [Color.tronMint, Color.tronEmeraldDeep],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .brightness(pressed ? -0.05 : (isHovering ? 0.03 : 0))

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: pressed
                            ? [Color.black.opacity(0.25), Color.clear]
                            : [Color.white.opacity(0.32), Color.clear],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.5)
                    ),
                    lineWidth: 0.8
                )
                .blendMode(pressed ? .normal : .plusLighter)

            shape
                .strokeBorder(
                    LinearGradient(
                        colors: pressed
                            ? [Color.clear, Color.white.opacity(0.18)]
                            : [Color.clear, Color.black.opacity(0.22)],
                        startPoint: UnitPoint(x: 0.5, y: 0.5),
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
                .blendMode(pressed ? .plusLighter : .normal)
        }
        .compositingGroup()
        .shadow(
            color: Color.tronEmerald.opacity(pressed ? 0.14 : (isHovering ? 0.36 : 0.22)),
            radius: pressed ? 2 : (isHovering ? 9 : 6),
            x: 0,
            y: pressed ? 1 : (isHovering ? 4 : 2)
        )
        .shadow(
            color: Color.black.opacity(pressed ? 0.06 : 0.14),
            radius: pressed ? 1 : 3,
            x: 0,
            y: pressed ? 0 : 1
        )
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
extension ButtonStyle where Self == WizardTertiaryButtonStyle {
    static var wizardTertiary: WizardTertiaryButtonStyle { WizardTertiaryButtonStyle() }
}
