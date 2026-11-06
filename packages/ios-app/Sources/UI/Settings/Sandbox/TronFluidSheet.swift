import SwiftUI
import UIKit

// The Sandbox's in-house sheet: a floating Liquid Glass card that sizes to its
// content and moves on one interruptible spring. Sandbox only; production sheets
// keep the shared managed presenter.
//
// Ownership and ordering:
// - Height belongs to SwiftUI layout. `TronFluidSheetLayout` asks the scrolling
//   body for its ideal (content) height and caps it, so a content change made in
//   an animated transaction resizes the card in that same transaction. No height
//   is measured into state, so there is no geometry feedback loop.
// - Position belongs to `TronFluidSheetModel.position`: 0 presented, 1 fully
//   below the screen, negative a rubber-banded lift. Only the dim and one
//   geometry effect observe it, so a drag frame never re-evaluates the content.
// - Interruption starts from the value the geometry effect last drew, never the
//   target, so a sheet caught mid-motion stays exactly where it is seen.
// - Present, dismiss, release and content resizing share `TronFluidSheetMotion`;
//   a release hands the finger's velocity to the spring.

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

    /// The same spring started at the finger's velocity, given as a fraction of
    /// the remaining distance per second (SwiftUI's relative initial velocity).
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

extension EnvironmentValues {
    var tronFluidSheet: TronFluidSheetActions {
        get { self[TronFluidSheetActionsKey.self] }
        set { self[TronFluidSheetActionsKey.self] = newValue }
    }
}

/// The value the geometry effect last drew. Written during rendering, read by
/// the gesture: a measurement, never state, so it invalidates nothing.
final class TronFluidSheetProbe: @unchecked Sendable {
    var position: CGFloat = 1
    var travel: CGFloat = 1
}

/// One sheet's motion. `position`, `opacity` and `isMounted` are the tracked
/// state; the rest is bookkeeping for gesture and completion callbacks.
@Observable @MainActor
final class TronFluidSheetModel {
    var position: CGFloat = 1
    /// Reduce Motion presents and dismisses with a cross-fade instead of travel.
    var opacity: Double = 1
    var isMounted = false

    @ObservationIgnored let probe = TronFluidSheetProbe()
    /// The card's padded frame in stage (window) space, before translation.
    @ObservationIgnored var cardFrame: CGRect = .zero
    @ObservationIgnored var isDismissing = false
    @ObservationIgnored var isDragging = false
    /// Bumped by every new motion, so a superseded completion does nothing.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var motion = TronFluidSheetMotion()
    @ObservationIgnored var onPresentedChange: (Bool) -> Void = { _ in }
    @ObservationIgnored var onSettled: (_ presented: Bool) -> Void = { _ in }

    /// Distance from presented to hidden: the card and its bottom margin.
    var travel: CGFloat { max(cardFrame.height, 1) }

    /// The card's frame as drawn this frame.
    var visibleCardFrame: CGRect { cardFrame.offsetBy(dx: 0, dy: probe.position * probe.travel) }

    func present() {
        isDismissing = false
        generation += 1
        let token = generation
        let animate = { [self] in
            withAnimation(motion.spring) {
                position = 0
                opacity = 1
            } completion: { [weak self] in
                guard let self, token == self.generation else { return }
                self.onSettled(true)
            }
        }
        guard !isMounted else {
            // Reversing a dismissal: the spring retargets with its velocity.
            animate()
            return
        }
        isMounted = true
        position = motion.reduceMotion ? 0 : 1
        opacity = motion.reduceMotion ? 0 : 1
        probe.position = position
        TronHaptics.shared.play(.sheetPresented)
        // Inserted at its start value in this update; the spring starts on the next.
        Task { @MainActor in
            guard token == self.generation else { return }
            animate()
        }
    }

    func dismiss(velocity: CGFloat = 0) {
        guard isMounted, !isDismissing else { return }
        isDismissing = true
        generation += 1
        let token = generation
        let animation = motion.reduceMotion ? motion.spring
            : motion.release(relativeVelocity: relativeVelocity(velocity, to: 1), momentum: false)
        withAnimation(animation) {
            if motion.reduceMotion { opacity = 0 } else { position = 1 }
        } completion: { [weak self] in
            guard let self, token == self.generation else { return }
            self.isDismissing = false
            self.isMounted = false
            self.position = 1
            self.opacity = 1
            self.probe.position = 1
            self.onSettled(false)
        }
    }

    /// Catches the sheet where it is drawn; the in-flight motion stops there. A
    /// caught dismissal is presented again, so the presenter's binding follows.
    func grab() -> CGFloat {
        isDragging = true
        generation += 1
        let current = motion.reduceMotion ? position : probe.position
        withoutAnimation {
            position = current
            opacity = 1
        }
        if isDismissing {
            isDismissing = false
            onPresentedChange(true)
        }
        return current
    }

    /// Follows the finger 1:1 below the presented edge; above it the lift resists.
    func track(rawOffset: CGFloat) {
        let offset = rawOffset < 0
            ? -TronFluidSheetMotion.rubberBand(-rawOffset, dimension: travel) : rawOffset
        withoutAnimation { position = offset / travel }
    }

    /// Projects the release and settles at the nearer rest: presented or gone.
    func release(velocity: CGFloat) {
        isDragging = false
        let offset = position * travel
        let projected = offset + TronFluidSheetMotion.projectedDistance(velocity: velocity)
        if projected > travel / 2 && velocity > -60 {
            onPresentedChange(false)
            dismiss(velocity: velocity)
        } else {
            generation += 1
            let token = generation
            let animation = motion.release(relativeVelocity: relativeVelocity(velocity, to: 0),
                                           momentum: abs(velocity) > 300 && offset > 1)
            withAnimation(animation) { position = 0 } completion: { [weak self] in
                guard let self, token == self.generation else { return }
                self.onSettled(true)
            }
        }
    }

    /// Points per second over the points left to travel.
    private func relativeVelocity(_ velocity: CGFloat, to target: CGFloat) -> Double {
        let remaining = (target - position) * travel
        guard abs(remaining) > 1 else { return 0 }
        return Double(velocity / remaining)
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
    /// pinned; the content scrolls only when the card reaches its cap.
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
}

/// The stage the card's frame and the pan are measured in; it fills the window.
private let tronFluidSheetStageSpace = "tron-fluid-sheet-stage"

private struct TronFluidSheetPresenter<Header: View, SheetContent: View, Footer: View>: ViewModifier {
    @Binding var isPresented: Bool
    let slowMotion: Double
    let onSettled: (Bool) -> Void
    let header: () -> Header
    let content: () -> SheetContent
    let footer: () -> Footer
    @State private var model = TronFluidSheetModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The card floats this far from the screen's sides and bottom, so its
    /// concentric corners follow the display's.
    private static var margin: CGFloat { 8 }

    func body(content presenter: Content) -> some View {
        let mounted = model.isMounted
        presenter
            .accessibilityHidden(mounted)
            .overlay {
                if mounted { stage }
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

    /// The dim and the card over the whole window. The reader respects the safe
    /// area so its insets are real, and only proposes them down: nothing it
    /// reads is written back, so it cannot loop.
    private var stage: some View {
        GeometryReader { proxy in
            let safe = proxy.safeAreaInsets
            ZStack(alignment: .bottom) {
                TronFluidSheetDim(model: model) { requestDismiss() }
                TronFluidSheetCard(maxHeight: max(proxy.size.height + safe.bottom - 12 - Self.margin, 160),
                                   bottomInset: max(safe.bottom - Self.margin, 0)) {
                    header()
                } content: {
                    self.content()
                } footer: {
                    footer()
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, Self.margin)
                .padding(.bottom, Self.margin)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(tronFluidSheetStageSpace)) } action: { frame in
                    model.cardFrame = frame
                }
                .modifier(TronFluidSheetTranslation(model: model))
                .environment(\.tronFluidSheet, TronFluidSheetActions(dismiss: dismissAction, motion: model.motion))
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityAction(.escape) { requestDismiss() }
                .accessibilityIdentifier("fluid-sheet")
            }
            .ignoresSafeArea()
            .coordinateSpace(.named(tronFluidSheetStageSpace))
            .gesture(TronFluidSheetPan(model: model))
        }
    }

    private func configure() {
        model.motion = TronFluidSheetMotion(slowMotion: slowMotion, reduceMotion: reduceMotion)
        model.onSettled = onSettled
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

/// The card's only per-frame reader of `position`: a geometry effect, so a drag
/// frame updates one transform and never lays the content out again.
private struct TronFluidSheetTranslation: ViewModifier {
    let model: TronFluidSheetModel

    func body(content: Content) -> some View {
        content
            .modifier(TronFluidSheetOffsetEffect(position: model.position, probe: model.probe))
            .opacity(model.opacity)
    }
}

private struct TronFluidSheetOffsetEffect: GeometryEffect {
    var position: CGFloat
    let probe: TronFluidSheetProbe

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        // The padded card's own height is its travel: hidden is exactly off screen.
        probe.position = position
        probe.travel = size.height
        return ProjectionTransform(CGAffineTransform(translationX: 0, y: position * size.height))
    }
}

/// The dim follows presentation progress continuously and closes the sheet on tap.
private struct TronFluidSheetDim: View {
    let model: TronFluidSheetModel
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let progress = min(max(1 - model.position, 0), 1) * model.opacity
        Color.black
            .opacity((colorScheme == .dark ? 0.42 : 0.22) * progress)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityHidden(true)
    }
}

/// The card: a pinned header and footer around a body that scrolls only when
/// the content is taller than the cap.
private struct TronFluidSheetCard<Header: View, Content: View, Footer: View>: View {
    let maxHeight: CGFloat
    let bottomInset: CGFloat
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content
    @ViewBuilder let footer: () -> Footer

    var body: some View {
        let shape = ConcentricRectangle(corners: .concentric(minimum: .fixed(34)), isUniform: true)
        TronFluidSheetLayout(maxHeight: maxHeight) {
            header()
            ScrollView(.vertical) {
                content()
            }
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            footer()
                .padding(.bottom, bottomInset)
        }
        .clipShape(shape)
        // A light wash under the content keeps the cards legible over a busy
        // backdrop: translucent cards never sit on bare clear glass.
        .background { shape.fill(Color.tronBackground.opacity(0.68)) }
        .glassEffect(.regular, in: shape)
        .contentShape(shape)
    }
}

/// Header and footer at their ideal heights; the body takes its ideal (content)
/// height up to what the cap leaves. One layout pass decides the card height,
/// so an animated content change animates the card with it.
struct TronFluidSheetLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 390
        let limit = min(maxHeight, proposal.height ?? .infinity)
        return CGSize(width: width, height: min(idealHeights(width: width, subviews: subviews).reduce(0, +), limit))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let heights = idealHeights(width: bounds.width, subviews: subviews)
        let body = max(bounds.height - heights[0] - heights[2], 0)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: heights[0]))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + heights[0]), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: body))
        subviews[2].place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: heights[2]))
    }

    private func idealHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
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
            guard model.isMounted, let pan = gestureRecognizer as? UIPanGestureRecognizer,
                  let window = pan.view?.window else { return false }
            let velocity = pan.velocity(in: nil)
            // Vertical intent only: horizontal pans belong to the content.
            guard abs(velocity.y) > abs(velocity.x) else { return false }
            let point = pan.location(in: nil)
            let card = model.visibleCardFrame
            guard card.contains(point) else { return false }
            scrollView = nil
            // A resting card shares the touch with its own scroll view, found
            // under the finger; a moving one is simply caught.
            var view = window.hitTest(point, with: nil)
            while let candidate = view, !(candidate is UIWindow) {
                if let scroll = candidate as? UIScrollView,
                   card.contains(scroll.convert(scroll.bounds, to: nil).insetBy(dx: 1, dy: 1)) {
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
            let caught = model.grab()
            sheetOffset = caught * model.travel
            lastTranslation = translation
            let resting = abs(caught) < 0.0005
            driving = !resting || !canScroll
            observeScroll()
        }

        func change(translation: CGFloat) {
            let delta = translation - lastTranslation
            lastTranslation = translation
            if !driving {
                // The content scrolls until it is at its top and the finger moves down.
                guard let scroll = scrollView, delta > 0, isAtTop(scroll) else { return }
                driving = true
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
            if wasDriving || model.position != 0 {
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
