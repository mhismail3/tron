import SwiftUI

/// The liquid action menu. One progress value, animated on the progress spring,
/// derives everything: the circles rise out of the trigger at 52-point intervals,
/// labels arrive after the first quarter, and the trigger's plus turns into a
/// close glyph. The circles share one `GlassEffectContainer`, so the system
/// fuses their glass into connecting bridges while they are close together.
/// Hit testing and accessibility follow the same open state, so a closed menu
/// takes no tap. A second tap retargets the spring from where the menu is drawn.
struct SandboxLiquidMenu: View {
    struct Item: Identifiable {
        let id: String
        let icon: String
        let label: String
        let action: () -> Void
    }

    let open: Bool
    let mounted: Bool
    let items: [Item]
    let onToggle: () -> Void
    static let spacing: CGFloat = 52

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            ZStack(alignment: .bottom) {
                ForEach(Array((mounted ? items : []).enumerated()), id: \.element.id) { index, item in
                    Button {
                        item.action()
                    } label: {
                        Image(systemName: item.icon)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.tronTextPrimary)
                            .frame(width: 40, height: 40)
                            .glassEffect(.regular.interactive(), in: .circle)
                            .frame(width: SandboxDesign.Size.hit, height: SandboxDesign.Size.hit)
                            .contentShape(Circle())
                    }
                    .buttonStyle(SandboxPressStyle())
                    // The circle alone is the element: its label is decoration drawn beside it.
                    .accessibilityLabel(item.label)
                    .accessibilityIdentifier("chat-proto-menu-\(item.id)")
                    .modifier(SandboxMenuItemEffect(progress: open ? 1 : 0, index: index, count: items.count, label: item.label))
                    .allowsHitTesting(open)
                    .accessibilityHidden(!open)
                }
                Button(action: onToggle) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.tronTextPrimary)
                        .modifier(SandboxTriggerGlyphEffect(progress: open ? 1 : 0))
                        .frame(width: SandboxDesign.Size.circle, height: SandboxDesign.Size.circle)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .contentShape(Circle())
                }
                .buttonStyle(SandboxPressStyle())
                .accessibilityLabel(open ? "Close actions" : "Actions")
                .accessibilityIdentifier("chat-proto-menu")
            }
        }
        .frame(width: SandboxDesign.Size.hit, height: SandboxDesign.Size.hit)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { if open { onToggle() } }
    }
}

/// One menu circle at progress p: its own slightly delayed share of p (closer
/// circles lead), its rise, its scale from the trigger, and its label.
private struct SandboxMenuItemEffect: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat
    let index: Int
    let count: Int
    let label: String

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        // A short lead for nearer circles reads as direction; ~20 ms at this response.
        let lead = CGFloat(index) * 0.05
        let local = min(max((progress - lead) / (1 - CGFloat(count - 1) * 0.05), 0), 1)
        let labelProgress = min(max((local - 0.25) / 0.75, 0), 1)
        // Glass inside a GlassEffectContainer is composited by the container and
        // ignores opacity, so a circle grows out of the trigger from zero scale
        // instead of fading in.
        content
            .scaleEffect(max(local, 0.001))
            .overlay(alignment: .trailing) {
                Text(label)
                    .font(SandboxDesign.Typeface.rowPrimary)
                    .foregroundStyle(Color.tronTextPrimary)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.tronSurface.opacity(0.92)))
                    .offset(x: -(SandboxDesign.Size.hit + 4) - 8 * (1 - labelProgress))
                    .opacity(Double(labelProgress))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .offset(y: -SandboxLiquidMenu.spacing * CGFloat(index + 1) * local)
    }
}

/// The trigger's plus turns 45° into a close glyph on the menu's progress.
private struct SandboxTriggerGlyphEffect: ViewModifier, @preconcurrency Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.rotationEffect(.degrees(45 * progress))
    }
}

/// The open menu's lower-region wash: canvas-coloured, transparent at its top,
/// so the transcript stays recognizable while the actions stay sharp. Tapping
/// it closes the menu; closed, it takes no input.
struct SandboxMenuWash: View {
    let open: Bool
    let onTap: () -> Void

    var body: some View {
        LinearGradient(stops: [.init(color: Color.tronBackground.opacity(0), location: 0),
                               .init(color: Color.tronBackground.opacity(0.82), location: 0.45),
                               .init(color: Color.tronBackground.opacity(0.94), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .opacity(open ? 1 : 0)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .allowsHitTesting(open)
            .accessibilityHidden(true)
    }
}

/// An inset panel: a compact sub-choice anchored below the header, 8 points from
/// the sides, at its content's height. It rises 16 points and scales from 0.96
/// with a light dim; the backdrop, the escape gesture or a choice dismisses it.
struct SandboxInsetPanel<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(colorScheme == .dark ? 0.36 : 0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
                .transition(.opacity)
            content()
                .frame(maxWidth: 520)
                .background(Color.tronBackground.opacity(0.7),
                            in: RoundedRectangle(cornerRadius: SandboxDesign.Radius.panel, style: .continuous))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: SandboxDesign.Radius.panel, style: .continuous))
                .padding(.horizontal, 8)
                .padding(.top, 56)
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape, onDismiss)
                .accessibilityIdentifier("chat-proto-panel")
                .transition(reduceMotion ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .offset(y: -16)))
        }
    }
}
