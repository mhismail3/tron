import SwiftUI
import UIKit

/// One presentation-time geometry owns the glass, contents, and clipping edge.
/// Animating an outer frame around a destination-sized clipped child lets that
/// child's composited glass escape the *visible* frame during the transition.
struct ConfigurationSliderSurface<Content: View, Label: View>: View, @preconcurrency Animatable {
    let source: CGRect
    let target: CGRect
    var fraction: CGFloat
    let reduceMotion: Bool
    let accent: Color
    private let content: Content
    private let label: Label

    init(
        source: CGRect, target: CGRect, fraction: CGFloat,
        reduceMotion: Bool, accent: Color,
        @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label
    ) {
        self.source = source
        self.target = target
        self.fraction = fraction
        self.reduceMotion = reduceMotion
        self.accent = accent
        // Build payloads on input changes, not for every interpolated geometry
        // sample. In particular, font/label construction is not animation work.
        self.content = content()
        self.label = label()
    }

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        let phase = min(1, max(0, fraction))
        let geometry = reduceMotion ? 1 : phase
        let frame = CGRect(
            x: source.minX + (target.minX - source.minX) * geometry,
            y: source.minY + (target.minY - source.minY) * geometry,
            width: source.width + (target.width - source.width) * geometry,
            height: source.height + (target.height - source.height) * geometry
        )
        let radius = source.height / 2 + (32 - source.height / 2) * geometry
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let reveal = min(1, max(0, (phase - 0.18) / 0.82))

        ZStack(alignment: .topLeading) {
            // Keep backdrop sampling in a native effect view at alpha 1. The
            // effect's own feather mask controls intensity; fading a composited
            // SwiftUI material can leave little/no actual blur on device.
            ConfigurationSliderBackdrop(fraction: phase)
                .frame(width: frame.width + 192, height: frame.height + 192)
                .position(x: frame.midX, y: frame.midY)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            Color.tronSurface.opacity(0.18 * phase)
                .frame(width: frame.width, height: frame.height)
                .overlay(alignment: .topTrailing) {
                    content
                        .frame(width: target.width, height: target.height)
                        .opacity(reveal * reveal * (3 - 2 * reveal))
                        .allowsHitTesting(phase == 1)
                        .accessibilityHidden(phase < 1)
                }
                .overlay {
                    label
                        .frame(width: source.width, height: source.height)
                        .opacity(max(0, 1 - phase * 3))
                        .accessibilityHidden(true)
                }
                // Clip at the interpolated viewport, not the child's final
                // layout bounds. Apply glass afterward to preserve its rim.
                .clipShape(shape)
                // A light neutral fill quiets clear glass without returning
                // to opaque lavender. The native backdrop supplies softening
                // while this material retains the translucent rim.
                .glassEffect(.clear.tint(accent.opacity(0.08)), in: shape)
                .contentShape(shape)
                .onTapGesture {} // Blank glass is not an outside-dismiss tap.
                .shadow(color: accent.opacity(0.12 * phase), radius: 24, y: 10)
                .opacity(reduceMotion ? phase : 1)
                .position(x: frame.midX, y: frame.midY)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transaction { transaction in
            // Do not start a second layout animation from each interpolated
            // sample. Settled slider gestures retain their own spring motion.
            if phase < 1 { transaction.animation = nil }
        }
    }
}

private struct ConfigurationSliderBackdrop: UIViewRepresentable {
    let fraction: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> ConfigurationSliderBackdropView {
        ConfigurationSliderBackdropView()
    }

    func updateUIView(_ view: ConfigurationSliderBackdropView, context: Context) {
        let style: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        if view.overrideUserInterfaceStyle != style { view.overrideUserInterfaceStyle = style }
        view.fraction = fraction
    }
}

/// Public backdrop blur with a GPU-interpolated elliptical falloff. No snapshot,
/// private blur filter, per-frame bitmap, or sheet-wide effect is needed.
private final class ConfigurationSliderBackdropView: UIVisualEffectView {
    private let featherView = UIView()
    private let feather = CAGradientLayer()
    var fraction: CGFloat = 0 {
        didSet {
            guard fraction != oldValue else { return }
            updateMask()
        }
    }

    init() {
        super.init(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        feather.type = .radial
        feather.startPoint = CGPoint(x: 0.5, y: 0.5)
        feather.endPoint = CGPoint(x: 1, y: 1)
        feather.locations = [0, 0.45, 0.75, 0.95, 1]
        featherView.layer.addSublayer(feather)
        updateMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard featherView.frame != bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        featherView.frame = bounds
        feather.frame = featherView.bounds
        installMask()
        CATransaction.commit()
    }

    private func updateMask() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feather.colors = [CGFloat(1), 1, 0.38, 0, 0].map {
            UIColor.white.withAlphaComponent($0 * fraction).cgColor
        }
        installMask()
        CATransaction.commit()
    }

    private func installMask() {
        // UIVisualEffectView forwards UIView masks to its internal backdrop
        // views; CALayer.mask does not follow that contract. UIKit copies the
        // mask, so reassign after size/strength changes, per its public docs:
        // developer.apple.com/documentation/uikit/uivisualeffectview
        mask = nil
        mask = featherView
    }
}

/// Labels use the same center coordinates as the thumb/dots. Only a colliding
/// default label moves to a second line; its horizontal detent anchor never moves.
struct ContextWindowSliderLabelsLayout: Layout {
    let defaultProgress: Double
    static let trackInset = ConfigurationSliderTrack.inset

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        let labels = measurements(subviews, width: width)
        return CGSize(width: width, height: labels.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let labels = measurements(subviews, width: bounds.width)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + labels.centers[index].x, y: bounds.minY + labels.centers[index].y),
                anchor: .center,
                proposal: ProposedViewSize(labels.sizes[index])
            )
        }
    }

    private func measurements(_ subviews: Subviews, width: CGFloat) -> (sizes: [CGSize], centers: [CGPoint], height: CGFloat) {
        let inset = Self.trackInset
        let sizes = subviews.enumerated().map { index, subview in
            subview.sizeThatFits(ProposedViewSize(width: index == 1 ? width : 2 * (inset + 12), height: nil))
        }
        guard sizes.count == 3 else { return (sizes, [], 0) }
        let placement = Self.placement(sizes: sizes, width: width, defaultProgress: defaultProgress)
        return (sizes, placement.centers, placement.height)
    }

    /// Places minimum, Default, and maximum label centers. Default follows its
    /// track stop but slides just inside a colliding endpoint label, so a
    /// default at (or near) a bound stays on the endpoint row instead of
    /// dropping to a low-contrast line against the container's bottom edge.
    /// Only when the row genuinely lacks room does Default wrap below, still
    /// clamped fully inside the bounds.
    static func placement(sizes: [CGSize], width: CGFloat, defaultProgress: Double) -> (centers: [CGPoint], height: CGFloat) {
        let inset = trackInset, gap: CGFloat = 8
        let rowHeight = sizes.map(\.height).max() ?? 0
        let x0 = inset, x2 = width - inset
        let track = inset + CGFloat(min(1, max(0, defaultProgress))) * max(0, width - 2 * inset)
        let half = sizes[1].width / 2
        let lower = x0 + sizes[0].width / 2 + gap + half
        let upper = x2 - sizes[2].width / 2 - gap - half
        let endpoints = [CGPoint(x: x0, y: rowHeight / 2), CGPoint(x: x2, y: rowHeight / 2)]
        if lower <= upper {
            let x = min(upper, max(lower, track))
            return ([endpoints[0], CGPoint(x: x, y: rowHeight / 2), endpoints[1]], rowHeight)
        }
        let x = min(max(half, width - half), max(half, track))
        return ([endpoints[0], CGPoint(x: x, y: rowHeight + 6 + sizes[1].height / 2), endpoints[1]],
                rowHeight + 6 + sizes[1].height)
    }
}
