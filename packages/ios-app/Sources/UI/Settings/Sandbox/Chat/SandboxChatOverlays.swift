import SwiftUI

/// The liquid action menu. One progress value, animated on the progress spring,
/// derives everything: the circles rise out of the trigger at 52-point intervals,
/// labels arrive after the first quarter, and the trigger's plus turns into a
/// close glyph. Under the glass circles, `SandboxLiquidBridges` draws the same
/// circles as one thresholded metaball silhouette from the same progress, so
/// thin bridges join them while they separate and vanish once they are apart.
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

    /// One circle's share of the menu's progress: nearer circles lead by a
    /// little (~20 ms at this response), which reads as direction.
    static func local(_ progress: CGFloat, index: Int, count: Int) -> CGFloat {
        let lead = CGFloat(index) * 0.05
        return min(max((progress - lead) / (1 - CGFloat(max(count - 1, 0)) * 0.05), 0), 1)
    }

    var body: some View {
        GlassEffectContainer(spacing: 18) {
            ZStack(alignment: .bottom) {
                if mounted {
                    SandboxLiquidBridges(progress: open ? 1 : 0, count: items.count)
                }
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
        let local = SandboxLiquidMenu.local(progress, index: index, count: count)
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

/// The menu's liquid silhouette: the trigger and every action circle at their
/// positions for this progress, blurred together and alpha-thresholded so
/// thin bridges form where circles are close (the guide's metaball recipe).
/// It is a tinted wash under the glass, strongest mid-flight and gone at rest,
/// so the resting look is the glass circles alone. Local bounds only; glyphs
/// and labels are never part of it. Reduce Motion draws nothing.
private struct SandboxLiquidBridges: View, @preconcurrency Animatable {
    var progress: CGFloat
    let count: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let height = SandboxLiquidMenu.spacing * CGFloat(count) + SandboxDesign.Size.hit + 24
        // Peaks while the circles separate; none fully closed or fully open.
        let presence = Double(sin(.pi * min(max(progress, 0), 1)))
        Canvas { context, size in
            context.addFilter(.alphaThreshold(min: 0.5, color: Color.tronPrimary))
            context.addFilter(.blur(radius: 7))
            context.drawLayer { layer in
                let x = size.width / 2
                let triggerY = size.height - 12 - SandboxDesign.Size.hit / 2
                let trigger = SandboxDesign.Size.circle / 2
                layer.fill(Path(ellipseIn: CGRect(x: x - trigger, y: triggerY - trigger, width: trigger * 2, height: trigger * 2)),
                           with: .color(.black))
                for index in 0..<count {
                    let local = SandboxLiquidMenu.local(progress, index: index, count: count)
                    guard local > 0.001 else { continue }
                    let radius = 20 * local
                    let y = triggerY - SandboxLiquidMenu.spacing * CGFloat(index + 1) * local
                    layer.fill(Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                               with: .color(.black))
                }
            }
        }
        .frame(width: SandboxDesign.Size.hit + 24, height: height)
        .offset(y: 12)
        .opacity(reduceMotion ? 0 : presence * (colorScheme == .dark ? 0.45 : 0.3))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
