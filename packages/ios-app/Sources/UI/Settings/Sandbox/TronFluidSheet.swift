import SwiftUI
import UIKit

// The Sandbox's in-house sheet: a floating Liquid Glass card that sizes to its
// content and morphs out of the control that opened it, on one interruptible
// spring. Sandbox only; production sheets keep the shared managed presenter.
//
// Ownership and ordering:
// - Height belongs to SwiftUI layout. `TronFluidSheetLayout` sizes the card to
//   its scrolling body's ideal height, capped below the status bar, so a content
//   change made in an animated transaction resizes the card in that transaction.
// - Motion belongs to `TronFluidSheetModel`: `morph` (0 at the source control,
//   1 presented) runs on the spring; `drag` (points below rest) follows the
//   finger directly. Both are render-only: `TronFluidSheetMorph` derives the
//   glass shape, the content's transform and the dim from them each frame, so
//   no motion frame lays anything out or re-evaluates the content.
// - The card is mounted once, when the presenter appears, and stays mounted;
//   presenting only animates. Closed, it draws nothing and takes no input.
// - Interruption starts from the values the effect last drew, never a target.

struct TronFluidSheetMotion: Sendable {
    /// Perceptual duration (Apple's "response") shared by every motion.
    static let response: Double = 0.42
    /// Critically damped by default; a small overshoot only after a flick.
    static let momentumBounce: Double = 0.14
    /// Playground slow motion stretches time, never the curve's shape.
    var slowMotion: Double = 1
    var reduceMotion = false

    /// State-driven motion: presenting, dismissing by tap, and content resizing.
    var spring: Animation {
        reduceMotion ? .easeInOut(duration: 0.22 * slowMotion)
            : .interpolatingSpring(duration: Self.response * slowMotion, bounce: 0)
    }

    /// The same spring started at a velocity given as a fraction of the
    /// remaining change per second (SwiftUI's relative initial velocity).
    func release(relativeVelocity: Double, momentum: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.2 * slowMotion)
            : .interpolatingSpring(duration: Self.response * slowMotion,
                                   bounce: momentum ? Self.momentumBounce : 0,
                                   initialVelocity: relativeVelocity)
    }

    /// Apple's projection: how far a flick at `velocity` points per second travels.
    static func projectedDistance(velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// Progressive resistance past a boundary: the further past, the less it follows.
    static func rubberBand(_ overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
    }
}

/// What sheet content may use: close its sheet, and animate its own changes on
/// the sheet's spring so the card resizes in the same transaction.
struct TronFluidSheetActions: Sendable {
    var dismiss: @MainActor @Sendable () -> Void = {}
    var motion = TronFluidSheetMotion()
}

private struct TronFluidSheetActionsKey: EnvironmentKey {
    static let defaultValue = TronFluidSheetActions()
}

private struct TronFluidSheetSourceKey: EnvironmentKey {
    static let defaultValue: TronFluidSheetModel? = nil
}

extension EnvironmentValues {
    var tronFluidSheet: TronFluidSheetActions {
        get { self[TronFluidSheetActionsKey.self] }
        set { self[TronFluidSheetActionsKey.self] = newValue }
    }

    /// The enclosing fluid sheet, for the control that opens it.
    fileprivate var tronFluidSheetSource: TronFluidSheetModel? {
        get { self[TronFluidSheetSourceKey.self] }
        set { self[TronFluidSheetSourceKey.self] = newValue }
    }
}

/// Values the morph effect last drew. Written while rendering and read by the
/// gesture: a measurement, never state, so it invalidates nothing.
final class TronFluidSheetProbe: @unchecked Sendable {
    var morph: CGFloat = 0
    var drag: CGFloat = 0
    var shape: CGRect = .zero
}

/// One sheet's motion. `morph`, `drag` and `isActive` are tracked state; the
/// geometry is measured bookkeeping read by the effect and the gesture.
@Observable @MainActor
final class TronFluidSheetModel {
    /// 0 at the source control, 1 presented.
    var morph: CGFloat = 0
    /// Points below rest; negative is a rubber-banded lift.
    var drag: CGFloat = 0
    /// Presented or still moving: the stage takes input and is visible to
    /// accessibility only while active.
    var isActive = false

    @ObservationIgnored let probe = TronFluidSheetProbe()
    /// The stage (the window) and the card's laid-out size; the card rests
    /// centred at the stage's bottom, `margin` above its edge.
    @ObservationIgnored var stageFrame: CGRect = .zero
    @ObservationIgnored var cardSize: CGSize = .zero
    @ObservationIgnored var margin: CGFloat = 8
    /// The source control's frame, in window space.
    @ObservationIgnored var sourceFrame: CGRect?
    @ObservationIgnored var sourceRadius: CGFloat = 22
    /// Uniform corner radius at rest: concentric with the display at the bottom
    /// (its corner radius less the card's margin) and the same at the top. It
    /// never changes with position, so dragging leaves the corners alone.
    @ObservationIgnored var restRadius: CGFloat = 40
    @ObservationIgnored var isDragging = false
    @ObservationIgnored private var isPresented = false
    /// Bumped by every new motion, so a superseded completion does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var motion = TronFluidSheetMotion()
    @ObservationIgnored var onPresentedChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onSettled: (_ presented: Bool) -> Void = { _ in }

    /// The morph's non-animated inputs, read when the presenter's body runs.
    var inputs: TronFluidSheetMorphInputs {
        TronFluidSheetMorphInputs(source: sourceFrame, sourceRadius: sourceRadius, stage: stageFrame, margin: margin,
                                  restRadius: restRadius, reduceMotion: motion.reduceMotion)
    }

    /// The card's resting frame in window space.
    var restFrame: CGRect {
        CGRect(x: stageFrame.midX - cardSize.width / 2, y: stageFrame.maxY - margin - cardSize.height,
               width: cardSize.width, height: cardSize.height)
    }

    /// The card's shape as drawn this frame, for the gesture's hit region.
    var visibleShape: CGRect { probe.shape }

    func present() {
        isPresented = true
        generation += 1
        let token = generation
        if !isActive {
            isActive = true
            TronHaptics.shared.play(.sheetPresented)
        }
        withAnimation(motion.spring) {
            morph = 1
            drag = 0
        } completion: { [weak self] in
            guard let self, token == self.generation else { return }
            self.onSettled(true)
        }
    }

    /// Collapses back into the source from wherever it is drawn, carrying a
    /// release velocity (points per second toward the source) when there is one.
    func dismiss(velocity: CGFloat = 0) {
        guard isActive, isPresented else { return }
        isPresented = false
        generation += 1
        let token = generation
        let distance = max(abs((restFrame.midY + drag) - (sourceFrame?.midY ?? restFrame.maxY)), 1)
        let relative = min(abs(velocity) / distance, 12)
        withAnimation(motion.release(relativeVelocity: Double(relative), momentum: false)) {
            morph = 0
        } completion: { [weak self] in
            guard let self, token == self.generation else { return }
            self.isActive = false
            self.drag = 0
            self.onSettled(false)
        }
    }

    /// Catches the sheet where it is drawn; the in-flight motion stops there.
    /// A caught dismissal is presented again, so the presenter's binding follows.
    func grab() {
        isDragging = true
        generation += 1
        let morph = motion.reduceMotion ? self.morph : probe.morph
        let drag = probe.drag
        withoutAnimation {
            self.morph = morph
            self.drag = drag
        }
        if !isPresented {
            isPresented = true
            onPresentedChange(true)
        }
    }

    /// Follows the finger 1:1 below rest; above it the lift resists.
    func track(rawOffset: CGFloat) {
        let offset = rawOffset < 0
            ? -TronFluidSheetMotion.rubberBand(-rawOffset, dimension: restFrame.height) : rawOffset
        withoutAnimation { drag = offset }
    }

    /// Projects the release and settles at the nearer rest: presented, or back
    /// in the source.
    func release(velocity: CGFloat) {
        isDragging = false
        let projected = drag + TronFluidSheetMotion.projectedDistance(velocity: velocity)
        if projected > restFrame.height / 2 && velocity > -60 {
            onPresentedChange(false)
            dismiss(velocity: max(velocity, 0))
            return
        }
        generation += 1
        let token = generation
        let relative = abs(drag) > 1 ? Double(velocity / -drag) : 0
        withAnimation(motion.release(relativeVelocity: relative, momentum: abs(velocity) > 300 && drag > 1)) {
            drag = 0
            morph = 1
        } completion: { [weak self] in
            guard let self, token == self.generation else { return }
            self.onSettled(true)
        }
    }

    private func withoutAnimation(_ body: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }
}

extension View {
    /// Presents the Sandbox's fluid sheet over this view, which should fill the
    /// window: the card floats inside its bounds. The header and footer stay
    /// pinned over the content, which scrolls under them only when the card
    /// reaches its cap. Mark the opening control with `tronFluidSheetSource()`
    /// so the sheet morphs out of it and back into it.
    func tronFluidSheet<Header: View, Content: View, Footer: View>(
        isPresented: Binding<Bool>,
        slowMotion: Double = 1,
        onSettled: @escaping (_ presented: Bool) -> Void = { _ in },
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder footer: @escaping () -> Footer
    ) -> some View {
        modifier(TronFluidSheetPresenter(isPresented: isPresented, slowMotion: slowMotion, onSettled: onSettled,
                                         header: header, content: content, footer: footer))
    }

    /// Marks the control the enclosing fluid sheet morphs out of. `cornerRadius`
    /// defaults to a capsule's (half the height). The control fades as the sheet
    /// leaves it and returns as the sheet lands back in it.
    func tronFluidSheetSource(cornerRadius: CGFloat? = nil) -> some View {
        modifier(TronFluidSheetSourceModifier(cornerRadius: cornerRadius))
    }
}

private struct TronFluidSheetSourceModifier: ViewModifier {
    let cornerRadius: CGFloat?
    @Environment(\.tronFluidSheetSource) private var model

    func body(content: Content) -> some View {
        if let model {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    model.sourceFrame = frame
                    model.sourceRadius = cornerRadius ?? frame.height / 2
                }
                .modifier(TronFluidSheetSourceFade(morph: model.morph))
        } else {
            content
        }
    }
}

/// The source control hands its place to the sheet early in the morph.
private struct TronFluidSheetSourceFade: ViewModifier, @preconcurrency Animatable {
    var morph: CGFloat
    var animatableData: CGFloat {
        get { morph }
        set { morph = newValue }
    }

    func body(content: Content) -> some View {
        content.opacity(Double(1 - min(max(morph * 4, 0), 1)))
    }
}

private struct TronFluidSheetPresenter<Header: View, SheetContent: View, Footer: View>: ViewModifier {
    @Binding var isPresented: Bool
    let slowMotion: Double
    let onSettled: (Bool) -> Void
    let header: () -> Header
    let content: () -> SheetContent
    let footer: () -> Footer
    @State private var model = TronFluidSheetModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card floats this far from the screen's sides and bottom.
    private static var margin: CGFloat { 8 }

    func body(content presenter: Content) -> some View {
        // Read here, not inside the stage's reader closure, so every morph and
        // drag change reaches the stage.
        let active = model.isActive
        let morph = model.morph
        let drag = model.drag
        presenter
            .environment(\.tronFluidSheetSource, model)
            .accessibilityHidden(active)
            .overlay {
                // Closed, the stage is decoration: no element, no input.
                stage(active: active, morph: morph, drag: drag)
                    .accessibilityHidden(!active)
            }
            .onAppear {
                configure()
                if isPresented { model.present() }
            }
            .onChange(of: isPresented) { _, presented in
                configure()
                if presented {
                    guard !model.isDragging else { return }
                    model.present()
                    Task { @MainActor in AccessibilityNotification.ScreenChanged(nil).post() }
                } else {
                    model.dismiss()
                }
            }
            .onChange(of: reduceMotion) { configure() }
            .onChange(of: slowMotion) { configure() }
    }

    /// The dim, the glass and the card over the whole window, mounted once and
    /// kept: presenting animates, it never builds the card. The reader only
    /// proposes the window's size and insets down; nothing it reads is written
    /// back, so it cannot loop.
    private func stage(active: Bool, morph: CGFloat, drag: CGFloat) -> some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            ZStack(alignment: .bottom) {
                TronFluidSheetDim(morph: morph, drag: drag, model: model) { requestDismiss() }
                let inputs = model.inputs
                let shape = TronFluidSheetMorphShape(morph: morph, drag: drag, inputs: inputs)
                TronFluidSheetCard(maxHeight: max(proxy.size.height + safe.bottom - 12 - Self.margin, 160),
                                   bottomInset: max(safe.bottom - Self.margin, 0)) {
                    header()
                } content: {
                    self.content()
                } footer: {
                    footer()
                }
                .frame(maxWidth: 560)
                // The layout size, not a frame: the morph transform sits above
                // this reader and must not feed back into the card's rest.
                .onGeometryChange(for: CGSize.self) { $0.size } action: { model.cardSize = $0 }
                .modifier(TronFluidSheetReveal(morph: morph, reduceMotion: inputs.reduceMotion))
                .modifier(TronFluidSheetContentEffect(morph: morph, drag: drag, inputs: inputs, probe: model.probe))
                .clipShape(shape)
                .background {
                    // A light wash keeps the content legible over a busy backdrop:
                    // translucent cards never sit on bare clear glass.
                    shape.fill(Color.tronBackground.opacity(0.68))
                        .glassEffect(.regular, in: shape)
                        .opacity(inputs.reduceMotion ? Double(morph) : 1)
                }
                .contentShape(shape)
                .padding(.horizontal, Self.margin)
                .padding(.bottom, Self.margin)
                .environment(\.tronFluidSheet, TronFluidSheetActions(dismiss: dismissAction, motion: model.motion))
                // Mounted while closed, so it is no element then: its children
                // are ignored and it carries no identity.
                .accessibilityElement(children: active ? .contain : .ignore)
                .accessibilityAddTraits(active ? .isModal : [])
                .accessibilityAction(.escape) { requestDismiss() }
                .accessibilityHidden(!active)
                .accessibilityIdentifier(active ? "fluid-sheet" : "")
            }
            .ignoresSafeArea()
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.stageFrame = $0 }
            .gesture(TronFluidSheetPan(model: model))
            .allowsHitTesting(active)
        }
    }

    private func configure() {
        model.motion = TronFluidSheetMotion(slowMotion: slowMotion, reduceMotion: reduceMotion)
        model.onSettled = onSettled
        model.margin = Self.margin
        model.restRadius = max(TronDisplayCorner.radius - Self.margin, 28)
        let binding = $isPresented
        model.onPresentedChange = { presented in
            if binding.wrappedValue != presented { binding.wrappedValue = presented }
        }
    }

    private func requestDismiss() {
        guard isPresented else { return }
        isPresented = false
    }

    private var dismissAction: @MainActor @Sendable () -> Void {
        let binding = $isPresented
        return { if binding.wrappedValue { binding.wrappedValue = false } }
    }
}

/// The display's corner radius, so a card floating `margin` inside the screen
/// can be concentric with it at a fixed radius. UIKit has no public value
/// (`ConcentricRectangle` resolves against the display but re-resolves as the
/// view moves), so the screen's private `_displayCornerRadius` is read once,
/// Sandbox only, with a conservative fallback when it is absent.
@MainActor
enum TronDisplayCorner {
    static let radius: CGFloat = {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
        let value = (screen?.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
        return value > 0 ? value : 48
    }()
}

/// What the morph needs besides its two animated values, captured when the
/// presenter's body runs (a present or dismiss), never per frame.
struct TronFluidSheetMorphInputs: Equatable {
    var source: CGRect?
    var sourceRadius: CGFloat
    var stage: CGRect
    var margin: CGFloat
    var restRadius: CGFloat
    var reduceMotion: Bool

    /// The card's window origin at rest, for a laid-out size.
    func restOrigin(size: CGSize) -> CGPoint {
        CGPoint(x: stage.midX - size.width / 2, y: stage.maxY - margin - size.height)
    }

    /// The morph's rect and radius in the card's own coordinates, for its
    /// current (possibly animating) layout size: from the source control's frame
    /// and radius to the card's bounds moved by the drag. Without a source it
    /// rises from below. Empty when fully closed, so nothing draws.
    func shape(morph: CGFloat, drag: CGFloat, size: CGSize) -> (rect: CGRect, radius: CGFloat) {
        let rest = CGRect(x: 0, y: drag, width: size.width, height: size.height)
        if reduceMotion { return (morph > 0 ? rest : .zero, restRadius) }
        guard morph > 0.0001 else { return (.zero, restRadius) }
        let origin = restOrigin(size: size)
        let from = source.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) }
            ?? rest.offsetBy(dx: 0, dy: size.height + margin)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * morph }
        let rect = CGRect(x: lerp(from.minX, rest.minX), y: lerp(from.minY, rest.minY),
                          width: lerp(from.width, rest.width), height: lerp(from.height, rest.height))
        let radius = min(lerp(source == nil ? restRadius : sourceRadius, restRadius), min(rect.width, rect.height) / 2)
        return (rect, radius)
    }
}

/// The morph's shape inside the card's bounds; the bounds are the card's live
/// layout, so a content resize and the morph compose in one shape.
private struct TronFluidSheetMorphShape: Shape {
    var morph: CGFloat
    var drag: CGFloat
    let inputs: TronFluidSheetMorphInputs

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(morph, drag) }
        set { morph = newValue.first; drag = newValue.second }
    }

    func path(in bounds: CGRect) -> Path {
        let shape = inputs.shape(morph: morph, drag: drag, size: bounds.size)
        guard shape.rect.width > 0, shape.rect.height > 0 else { return Path() }
        return Path(roundedRect: shape.rect.offsetBy(dx: bounds.minX, dy: bounds.minY),
                    cornerRadius: max(shape.radius, 0), style: .continuous)
    }
}

/// The card's content rides the shape: one uniform scale and an offset (never
/// a stretch). Records the drawn values for the gesture.
private struct TronFluidSheetContentEffect: GeometryEffect {
    var morph: CGFloat
    var drag: CGFloat
    let inputs: TronFluidSheetMorphInputs
    let probe: TronFluidSheetProbe

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(morph, drag) }
        set { morph = newValue.first; drag = newValue.second }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let shape = inputs.shape(morph: morph, drag: drag, size: size)
        let origin = inputs.restOrigin(size: size)
        probe.morph = morph
        probe.drag = drag
        probe.shape = shape.rect.offsetBy(dx: origin.x, dy: origin.y)
        guard !inputs.reduceMotion, size.width > 0, shape.rect.width > 0 else {
            return ProjectionTransform(CGAffineTransform(translationX: 0, y: inputs.reduceMotion ? drag : 0))
        }
        let scale = shape.rect.width / size.width
        return ProjectionTransform(CGAffineTransform(translationX: shape.rect.minX, y: shape.rect.minY)
            .scaledBy(x: scale, y: scale))
    }
}

/// Content arrives once there is room to read it and leaves before it would
/// be squeezed; Reduce Motion cross-fades the whole card instead.
private struct TronFluidSheetReveal: ViewModifier, @preconcurrency Animatable {
    var morph: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { morph }
        set { morph = newValue }
    }

    func body(content: Content) -> some View {
        let reveal = min(max((morph - 0.35) / 0.45, 0), 1)
        content.opacity(reduceMotion ? Double(morph) : Double(reveal * reveal * (3 - 2 * reveal)))
    }
}

/// The dim follows the morph and the drag, and closes the sheet on tap.
private struct TronFluidSheetDim: View, @preconcurrency Animatable {
    var morph: CGFloat
    var drag: CGFloat
    let model: TronFluidSheetModel
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(morph, drag) }
        set { morph = newValue.first; drag = newValue.second }
    }

    var body: some View {
        let height = max(model.restFrame.height, 1)
        let progress = min(max(morph * (1 - max(drag, 0) / height), 0), 1)
        Color.black
            .opacity((colorScheme == .dark ? 0.42 : 0.22) * progress)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityHidden(true)
    }
}

/// The card: a header and footer pinned over a body that scrolls under them
/// only when the content is taller than the cap. Content scrolled under an edge
/// gets a progressive blur and fade there, shown only while something is under it.
private struct TronFluidSheetCard<Header: View, Content: View, Footer: View>: View {
    let maxHeight: CGFloat
    let bottomInset: CGFloat
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer
    @State private var chrome = TronFluidSheetChromeHeights()
    @State private var edges = TronFluidSheetScrollEdges()

    var body: some View {
        TronFluidSheetLayout(maxHeight: maxHeight) {
            ScrollView(.vertical) {
                content()
                    .padding(.top, chrome.header)
                    .padding(.bottom, chrome.footer + bottomInset)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollEdgeEffectHidden(true, for: .vertical)
            .onScrollGeometryChange(for: TronFluidSheetScrollEdges.self) { geometry in
                TronFluidSheetScrollEdges(
                    underTop: geometry.contentOffset.y + geometry.contentInsets.top > 1,
                    underBottom: geometry.contentOffset.y + geometry.containerSize.height
                        < geometry.contentSize.height + geometry.contentInsets.bottom - 1)
            } action: { _, value in
                withAnimation(.easeOut(duration: 0.15)) { edges = value }
            }
            // The bands sit on the body, so the header and footer draw above them.
            .overlay(alignment: .top) {
                TronFluidSheetEdgeBlur(edge: .top, height: chrome.header + 22)
                    .opacity(edges.underTop ? 1 : 0)
            }
            .overlay(alignment: .bottom) {
                TronFluidSheetEdgeBlur(edge: .bottom, height: chrome.footer + bottomInset + 22)
                    .opacity(edges.underBottom ? 1 : 0)
            }
            header()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome.header = $0 }
            footer()
                .padding(.bottom, bottomInset)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chrome.footer = max($0 - bottomInset, 0) }
        }
    }
}

private struct TronFluidSheetChromeHeights: Equatable {
    var header: CGFloat = 0
    var footer: CGFloat = 0
}

struct TronFluidSheetScrollEdges: Equatable {
    var underTop = false
    var underBottom = false
}

/// A progressive blur and canvas fade along one edge: the system's thinnest
/// material masked from full strength at the edge to nothing, under a matching
/// fade, so scrolled content dissolves instead of cutting off.
private struct TronFluidSheetEdgeBlur: View {
    let edge: VerticalEdge
    let height: CGFloat

    var body: some View {
        let toward: UnitPoint = edge == .top ? .top : .bottom
        let away: UnitPoint = edge == .top ? .bottom : .top
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                             .init(color: .clear, location: 1)], startPoint: toward, endPoint: away))
            LinearGradient(stops: [.init(color: Color.tronBackground.opacity(0.85), location: 0),
                                   .init(color: Color.tronBackground.opacity(0.6), location: 0.5),
                                   .init(color: Color.tronBackground.opacity(0), location: 1)],
                           startPoint: toward, endPoint: away)
        }
        .frame(height: max(height, 0))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The body takes its ideal (content) height, which already includes room for
/// the pinned chrome, up to the cap; it fills the card and the header and footer
/// float over its top and bottom. One layout pass decides the card height, so
/// an animated content change animates the card with it. An `EmptyView` footer
/// is no subview at all, so the footer is optional.
struct TronFluidSheetLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 390
        let limit = min(maxHeight, proposal.height ?? .infinity)
        let ideal = subviews.first?.sizeThatFits(ProposedViewSize(width: width, height: nil)).height ?? 0
        return CGSize(width: width, height: min(ideal, limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let body = subviews.first else { return }
        body.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
        if subviews.count > 1 {
            let header = subviews[1]
            header.place(at: bounds.origin, anchor: .topLeading,
                         proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
        if subviews.count > 2 {
            subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

/// The sheet's pan: one UIKit recognizer on the stage, so it can catch the card
/// wherever it is drawn mid-motion and share touches with the body's scroll view.
/// The scroll view never rubber-bands past its top while the sheet can move
/// instead; while the sheet moves the scroll view is held at its top, and once
/// the sheet is back at rest with the finger still rising the scroll view takes over.
private struct TronFluidSheetPan: UIGestureRecognizerRepresentable {
    let model: TronFluidSheetModel

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(model: model) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        // Window coordinates: the stage fills the window, and the scroll view's
        // own translation is measured in the same space.
        let translation = recognizer.translation(in: nil).y
        switch recognizer.state {
        case .began: coordinator.begin(translation: translation)
        case .changed: coordinator.change(translation: translation)
        case .ended: coordinator.end(velocity: recognizer.velocity(in: nil).y)
        case .cancelled, .failed: coordinator.end(velocity: 0)
        default: break
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: TronFluidSheetModel
        /// The card's scroll view under this touch, if any.
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        /// Whether this gesture currently moves the sheet (else the scroll view scrolls).
        private var driving = false
        private var lastTranslation: CGFloat = 0
        private var sheetOffset: CGFloat = 0

        init(model: TronFluidSheetModel) { self.model = model }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard model.isActive, let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let window = pan.view?.window else { return false }
            let velocity = pan.velocity(in: nil)
            // Vertical intent only: horizontal pans belong to the content.
            guard abs(velocity.y) > abs(velocity.x) else { return false }
            let point = pan.location(in: nil)
            let card = model.visibleShape
            guard card.contains(point) else { return false }
            scrollView = nil
            // A resting card shares the touch with its own scroll view, found
            // under the finger; a moving one is simply caught.
            var view = window.hitTest(point, with: nil)
            while let candidate = view, !(candidate is UIWindow) {
                if let scroll = candidate as? UIScrollView,
                   card.insetBy(dx: -1, dy: -1).contains(scroll.convert(scroll.bounds, to: nil)) {
                    scrollView = scroll
                    break
                }
                view = candidate.superview
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            guard let scroll = scrollView else { return false }
            return other === scroll.panGestureRecognizer
        }

        func begin(translation: CGFloat) {
            lastTranslation = translation
            // A moving card is caught where it is drawn. A resting one is left
            // alone (no state change mid-touch) until the gesture decides to move it.
            let moving = model.probe.morph < 0.999 || abs(model.probe.drag) > 0.5
            driving = moving || !canScroll
            if driving { model.grab() }
            sheetOffset = model.drag
            observeScroll()
        }

        func change(translation: CGFloat) {
            let delta = translation - lastTranslation
            lastTranslation = translation
            if !driving {
                // The content scrolls until it is at its top and the finger moves down.
                guard let scroll = scrollView, delta > 0, isAtTop(scroll) else { return }
                driving = true
                model.grab()
                sheetOffset = model.drag
            }
            var next = sheetOffset + delta
            if next < 0, canScroll {
                // Back at rest with the finger still rising: the scroll view takes over.
                next = 0
                driving = false
            }
            sheetOffset = next
            model.track(rawOffset: next)
            if driving, let scroll = scrollView { holdAtTop(scroll) }
        }

        func end(velocity: CGFloat) {
            let wasDriving = driving
            driving = false
            observation?.invalidate()
            observation = nil
            if wasDriving || model.drag != 0 {
                model.release(velocity: wasDriving ? velocity : 0)
            } else {
                model.isDragging = false
            }
            scrollView = nil
        }

        private var canScroll: Bool {
            guard let scroll = scrollView else { return false }
            let insets = scroll.adjustedContentInset
            return scroll.contentSize.height + insets.top + insets.bottom > scroll.bounds.height + 0.5
        }

        private func isAtTop(_ scroll: UIScrollView) -> Bool {
            scroll.contentOffset.y <= -scroll.adjustedContentInset.top + 0.5
        }

        private func holdAtTop(_ scroll: UIScrollView) {
            let top = -scroll.adjustedContentInset.top
            if abs(scroll.contentOffset.y - top) > 0.01 { scroll.contentOffset.y = top }
        }

        /// Whatever order UIKit runs the two recognizers' actions in, the scroll
        /// view stays at its top while the sheet moves and never stretches past it.
        private func observeScroll() {
            observation?.invalidate()
            guard let scroll = scrollView else { return }
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let top = -scroll.adjustedContentInset.top
                    if self.driving || scroll.contentOffset.y < top - 0.01 { self.holdAtTop(scroll) }
                }
            }
        }
    }
}
