import SwiftUI

/// Primary CTA: skeuomorphic rounded-rectangle button with a top-down
/// emerald gradient, a soft white top-edge bevel, a dark bottom-edge
/// inset, and dual drop shadows (emerald glow + black crispness). When
/// pressed, the bevels invert (top inset / bottom highlight), the
/// outer shadows shrink, and a slight darkness wash overlays the fill —
/// the classic "pushed into the surface" feel that flat buttons can't
/// quite sell. Replaces the old capsule because the wizard wanted more
/// physical depth than gradient-on-pill could provide.
///
/// All animations are spring-driven so the press feels tactile rather
/// than mechanical; hover lifts both the glow and the highlight a
/// touch so the cursor's intent is acknowledged before commitment.
struct WizardPrimaryButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.body, design: .rounded).weight(.semibold))
            .foregroundStyle(.white)
            // Auto-sized rectangle — the wizard docks the primary CTA
            // in the bottom-right corner alongside a left-docked
            // secondary button, so a `maxWidth: .infinity` would push
            // the layout off-axis. `minWidth` keeps the visual weight
            // consistent across short labels ("Continue") and longer
            // ones ("I'm paired").
            .frame(minWidth: 132)
            .padding(.vertical, 11)
            .padding(.horizontal, 24)
            .background(skeuomorphicBackground(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.18), value: isHovering)
            .onHover { isHovering = $0 }
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// Composes the four-layer skeuomorphic stack: gradient fill, top
    /// bevel, bottom bevel, and outer shadows. The shape is wrapped in
    /// `.compositingGroup()` so the `.plusLighter` blends on the
    /// bevels operate against the composed background rather than
    /// punching through to whatever sits below the button.
    @ViewBuilder
    private func skeuomorphicBackground(pressed: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)

        ZStack {
            // Layer 1 — base gradient. Always mint→emeraldDeep top-to-
            // bottom; the "pressed" feel comes from inverting the
            // bevels (Layers 2 + 3) and from the brightness wash, not
            // from re-coloring the fill. Real-world buttons don't
            // change material when pressed, only the way light catches
            // their edges.
            shape
                .fill(LinearGradient(
                    colors: [Color.tronMint, Color.tronEmeraldDeep],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .brightness(pressed ? -0.05 : (isHovering ? 0.03 : 0))

            // Layer 2 — top-edge bevel. Resting: a faint white stroke
            // along the top half implies light coming from above.
            // Pressed: a faint dark stroke along the top implies the
            // button has been pushed down so the upper edge is now
            // recessed and shadowed.
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

            // Layer 3 — bottom-edge bevel, mirror of Layer 2. Resting:
            // a faint dark stroke at the bottom implies the lower
            // edge is shadowed (because light is coming from above).
            // Pressed: a faint white stroke at the bottom implies the
            // button has been pushed in and the lower edge now
            // catches light from below.
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
        .compositingGroup()
        // Outer shadow 1 — branded emerald glow. Bright and wide on
        // hover (acknowledges the cursor); shrunk dramatically on
        // press so the button reads as flush with the surface.
        .shadow(
            color: Color.tronEmerald.opacity(pressed ? 0.18 : (isHovering ? 0.50 : 0.32)),
            radius: pressed ? 3 : (isHovering ? 14 : 9),
            x: 0,
            y: pressed ? 1 : (isHovering ? 6 : 3)
        )
        // Outer shadow 2 — tight, neutral black. Adds crispness under
        // the gradient that the colored glow alone can't provide;
        // also shrinks on press.
        .shadow(
            color: Color.black.opacity(pressed ? 0.08 : 0.20),
            radius: pressed ? 1 : 4,
            x: 0,
            y: pressed ? 0 : 2
        )
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
