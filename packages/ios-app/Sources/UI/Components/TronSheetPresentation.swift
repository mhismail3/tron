import SwiftUI
import UIKit

enum TronSheetTarget: Equatable {
    case fit(CGFloat)
    case large
}

struct SheetDeck: Equatable, Sendable {
    var peek: CGFloat = 12
    var inset: CGFloat = 10
    var falloff: CGFloat = 0.62
    var visibleDepth: CGFloat = 6

    func steps(_ depth: CGFloat) -> CGFloat {
        depth > 0 ? (1 - pow(falloff, depth)) / (1 - falloff) : 0
    }

    func contentOpacity(_ depth: CGFloat) -> CGFloat {
        let t = min(max((depth - 0.55) / 0.45, 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    func card(behind front: CGRect, depth: CGFloat) -> CGRect {
        let back = steps(depth)
        let dx = min(inset * back, front.width * 0.25)
        return CGRect(x: front.minX + dx, y: front.minY - peek * back, width: front.width - 2 * dx,
                      height: front.height + peek * back)
    }
}

@MainActor
final class TronSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
    static let shared = TronSheetTransitioningDelegate()

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        TronSheetTransition(presenting: true)
    }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        TronSheetTransition(presenting: false)
    }
}

@MainActor
private final class TronSheetTransition: NSObject, UIViewControllerAnimatedTransitioning {
    let presenting: Bool

    init(presenting: Bool) { self.presenting = presenting }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        TronSheetStage.response
    }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        guard let controller = context.viewController(forKey: presenting ? .to : .from),
              let stage = TronSheetStage.stage(of: controller) else { return context.completeTransition(!context.transitionWasCancelled) }
        if presenting { stage.open(context) } else { stage.close(context) }
    }
}

private final class TronSheetCardView: UIView {
    var escape: (() -> Bool)?
    override func accessibilityPerformEscape() -> Bool { escape?() ?? false }
}

@MainActor
final class TronSheetStage: NSObject, UIGestureRecognizerDelegate {
    private enum Phase { case measuring, shown, dismissing }

    static let response: TimeInterval = 0.45
    private static let inset: CGFloat = 8
    private static let toolbarDrop: CGFloat = 16
    private static let dimming: CGFloat = 0.478
    private static let deck = SheetDeck()
    private static var live: [TronSheetStage] = []
    private static var keyboardTop = CGFloat.infinity

    static var isEnabled: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    var dismissAction: DismissAction?
    var animates = true
    private weak var presentedViewController: UIViewController?
    private weak var containerView: UIView?
    private let card = TronSheetCardView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect())
    private let backdrop = UIView()
    private let pan = UIPanGestureRecognizer()
    private var phase = Phase.measuring
    private var target = TronSheetTarget.large
    private var drag: CGFloat = 0
    private var lastTranslation: CGFloat = 0
    private weak var dragScroll: UIScrollView?
    private var releaseVelocity: CGFloat = 0
    private var below = 0
    private var opening: (any UIViewControllerContextTransitioning)?
    private var openedAt: CFTimeInterval = 0
    private var measured: TronSheetTarget?

    static func adopt(_ presented: UIViewController, animated: Bool) {
        let stage = stage(of: presented) ?? TronSheetStage(presented)
        stage.animates = animated
        if !live.contains(where: { $0 === stage }) { live.append(stage) }
        presented.transitioningDelegate = TronSheetTransitioningDelegate.shared
    }

    static func stage(of controller: UIViewController) -> TronSheetStage? {
        live.removeAll { $0.presentedViewController == nil }
        return live.first { $0.presentedViewController === controller }
    }

    private init(_ presented: UIViewController) {
        presentedViewController = presented
        super.init()
        presented.traitOverrides.userInterfaceLevel = .elevated
        let corners = UICornerConfiguration.corners(topLeftRadius: .fixed(38), topRightRadius: .fixed(38),
                                                    bottomLeftRadius: .fixed(54), bottomRightRadius: .fixed(54))
        card.cornerConfiguration = corners
        glass.cornerConfiguration = corners
        card.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        card.clipsToBounds = true
        card.accessibilityViewIsModal = true
        card.escape = { [weak self] in self?.requestDismiss(velocity: 0); return true }
        card.addSubview(glass)
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.delegate = self
        card.addGestureRecognizer(pan)
        backdrop.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
        #if HOSTED_TEST
        HostedPresentationProbe.sheetDrag = { controller, state, translation, velocity in
            TronSheetStage.stage(of: controller)?.drag(state, translation: translation, velocity: velocity)
        }
        #endif
    }

    func presentationDidEnd() {
        guard card.superview == nil, let presented = presentedViewController,
              let container = presented.view.superview else { return }
        install(in: container, content: presented.view)
        phase = .shown
        UIView.performWithoutAnimation { Self.layoutStack(in: container.window) }
    }

    private func install(in containerView: UIView, content: UIView) {
        guard card.superview == nil else { return }
        self.containerView = containerView
        backdrop.frame = containerView.bounds
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = .clear
        containerView.addSubview(backdrop)
        containerView.addSubview(card)
        content.autoresizingMask = []
        card.addSubview(content)
        below = Self.stack(in: containerView.window).count
        place(offscreen(restRect))
    }

    private func retire() {
        let window = containerView?.window
        NotificationCenter.default.removeObserver(self)
        pan.removeTarget(nil, action: nil)
        card.gestureRecognizers?.forEach(card.removeGestureRecognizer)
        backdrop.gestureRecognizers?.forEach(backdrop.removeGestureRecognizer)
        card.removeFromSuperview()
        backdrop.removeFromSuperview()
        Self.live.removeAll { $0 === self }
        UIView.performWithoutAnimation { Self.layoutStack(in: window) }
    }

    func appearance(_ style: UIUserInterfaceStyle) {
        card.overrideUserInterfaceStyle = style
    }

    func contentTarget(_ next: TronSheetTarget) {
        guard next != target else { return }
        target = next
        switch phase {
        case .measuring:
            if card.superview != nil { place(offscreen(restRect)) }
        case .shown:
            let window = containerView?.window
            if UIAccessibility.isReduceMotionEnabled { Self.layoutStack(in: window) } else { animate { Self.layoutStack(in: window) } }
        case .dismissing:
            break
        }
    }

    fileprivate func open(_ context: any UIViewControllerContextTransitioning) {
        guard let content = context.view(forKey: .to) ?? presentedViewController?.view else {
            return context.completeTransition(false)
        }
        install(in: context.containerView, content: content)
        card.layoutIfNeeded()
        opening = context
        openedAt = CACurrentMediaTime()
        measured = nil
        measureTick()
    }

    private func measureTick() {
        guard let context = opening else { return }
        presentedViewController?.view.layoutIfNeeded()
        let fitted = if case .fit = target { true } else { false }
        guard (fitted && measured == target) || CACurrentMediaTime() - openedAt > 0.12 else {
            measured = target
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(8))
                self?.measureTick()
            }
            return
        }
        opening = nil
        phase = .shown
        let window = containerView?.window
        let finish = {
            let completed = !context.transitionWasCancelled
            if !completed { self.retire() }
            context.completeTransition(completed)
        }
        if UIAccessibility.isReduceMotionEnabled || !animates {
            UIView.performWithoutAnimation { Self.layoutStack(in: window) }
            finish()
        } else {
            animate({ Self.layoutStack(in: window) }) { _ in finish() }
        }
    }

    fileprivate func close(_ context: any UIViewControllerContextTransitioning) {
        let window = containerView?.window
        let rest = restRect
        let away = offscreen(rest)
        let velocity = releaseVelocity / max(away.minY - rest.minY, 1)
        phase = .dismissing
        releaseVelocity = 0
        let finish = { (_: Bool) in
            let completed = !context.transitionWasCancelled
            if completed { self.retire() } else { self.phase = .shown; Self.layoutStack(in: window) }
            context.completeTransition(completed)
        }
        let changes = {
            self.place(away)
            self.backdrop.backgroundColor = .clear
            Self.layoutStack(in: window)
        }
        guard animates, !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation(changes)
            return finish(true)
        }
        animate(velocity: velocity, changes, completion: finish)
    }

    private var isFront: Bool { Self.stack(in: containerView?.window).last === self }

    private static func stack(in window: UIWindow?) -> [TronSheetStage] {
        live.removeAll { $0.presentedViewController == nil }
        return live.filter { $0.containerView?.window === window && $0.phase == .shown }
    }

    private static func layoutStack(in window: UIWindow?) {
        let sheets = stack(in: window)
        guard let front = sheets.last else { return }
        let frontRect = front.restRect
        let shift = front.drag > 0 ? min(front.drag / max(frontRect.height, 1), 1) : 0
        for (index, sheet) in sheets.enumerated() {
            let depth = CGFloat(sheets.count - 1 - index)
            let back = depth - shift
            let card = deck.card(behind: frontRect, depth: max(back, 1))
            sheet.place(depth == 0 ? frontRect : back >= 1 ? card : sheet.restRect.blend(to: card, back))
            sheet.card.alpha = depth > deck.visibleDepth ? 0 : 1
            sheet.presentedViewController?.view.alpha = deck.contentOpacity(max(back, 0))
            sheet.backdrop.backgroundColor = index == 0 ? UIColor.black.withAlphaComponent(dimming) : .clear
        }
    }

    static var maximumHeight: CGFloat {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.keyWindow }).first else { return .infinity }
        return cap(in: window.bounds, top: window.safeAreaInsets.top + deck.peek, keyboard: .infinity)
    }

    static var bottomSafeArea: CGFloat {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets.bottom ?? 0
    }

    private static func scale(_ bounds: CGRect) -> CGFloat { (bounds.width - 2 * inset) / max(bounds.width, 1) }

    private static func cap(in bounds: CGRect, top: CGFloat, keyboard: CGFloat) -> CGFloat {
        (min(bounds.maxY, keyboard) - inset - top) / scale(bounds)
    }

    private var keyboardTop: CGFloat { isFront || phase != .shown ? Self.keyboardTop : .infinity }

    private var room: CGFloat { Self.deck.peek * Self.deck.steps(CGFloat(below)) }

    private var layoutHeight: CGFloat {
        guard let containerView else { return 0 }
        let cap = Self.cap(in: containerView.bounds, top: containerView.safeAreaInsets.top + room, keyboard: keyboardTop)
        return switch target {
        case .fit(let height): min(height, cap)
        case .large: cap
        }
    }

    private var anchor: CGRect {
        guard let containerView else { return .zero }
        let bounds = containerView.bounds
        let height = layoutHeight * Self.scale(bounds)
        let bottom = min(bounds.maxY, keyboardTop) - Self.inset
        return CGRect(x: Self.inset, y: bottom - height, width: bounds.width - 2 * Self.inset, height: height)
    }

    private var restRect: CGRect {
        let rest = anchor
        let shown = drag >= 0 ? drag : -(1 - 1 / (-drag * 0.55 / max(rest.height, 1) + 1)) * rest.height
        return rest.offsetBy(dx: 0, dy: shown)
    }

    private func offscreen(_ rect: CGRect) -> CGRect {
        rect.offsetBy(dx: 0, dy: (containerView?.bounds.maxY ?? rect.maxY) - rect.minY)
    }

    private func place(_ rect: CGRect) {
        guard let containerView, let presented = presentedViewController else { return }
        let bounds = containerView.bounds
        let height = layoutHeight
        let scale = rect.width / max(bounds.width, 1)
        card.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: min(height, rect.height / max(scale, 0.01)))
        card.center = CGPoint(x: rect.midX, y: rect.minY)
        card.transform = CGAffineTransform(scaleX: scale, y: scale)
        glass.frame = card.bounds
        presented.view.frame = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        let current = presented.additionalSafeAreaInsets
        let inherited = (top: presented.view.safeAreaInsets.top - current.top, bottom: presented.view.safeAreaInsets.bottom - current.bottom)
        let wanted = UIEdgeInsets(top: Self.toolbarDrop - inherited.top, left: 0, bottom: Self.bottomSafeArea - inherited.bottom, right: 0)
        if abs(wanted.top - current.top) > 0.5 || abs(wanted.bottom - current.bottom) > 0.5 { presented.additionalSafeAreaInsets = wanted }
    }

    private func animate(velocity: CGFloat = 0, _ changes: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        UIView.animate(springDuration: Self.response, bounce: 0, initialSpringVelocity: velocity, delay: 0,
                       options: [.allowUserInteraction, .beginFromCurrentState], animations: changes, completion: completion)
    }

    private func requestDismiss(velocity: CGFloat) {
        guard phase == .shown, isFront, let presented = presentedViewController else { return }
        if presented.isModalInPresentation {
            if let controller = presented.presentationController { controller.delegate?.presentationControllerDidAttemptToDismiss?(controller) }
            settle(velocity: velocity)
            return
        }
        releaseVelocity = max(velocity, 0)
        animates = true
        dismissAction?()
    }

    private func settle(velocity: CGFloat) {
        let distance = drag
        drag = 0
        let window = containerView?.window
        animate(velocity: distance > 0 ? -velocity / distance : 0) { Self.layoutStack(in: window) }
    }

    @objc private func tapped() { requestDismiss(velocity: 0) }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { dragScroll = scrollView(at: gesture.location(in: card)) }
        drag(gesture.state, translation: gesture.translation(in: containerView).y, velocity: gesture.velocity(in: containerView).y)
    }

    fileprivate func drag(_ state: UIGestureRecognizer.State, translation: CGFloat, velocity: CGFloat) {
        guard phase == .shown, let containerView else { return }
        switch state {
        case .began:
            lastTranslation = translation
        case .changed:
            let delta = translation - lastTranslation
            lastTranslation = translation
            if let scroll = dragScroll {
                let top = -scroll.adjustedContentInset.top
                if drag <= 0, delta < 0 || scroll.contentOffset.y > top + 0.5 { return }
                drag = max(drag + delta, 0)
                scroll.contentOffset.y = top
            } else {
                drag += delta
            }
            Self.layoutStack(in: containerView.window)
        case .ended where drag > 0 && (velocity > 1000 || drag + velocity * 0.2 > restRect.height / 2):
            requestDismiss(velocity: velocity)
        case .ended, .cancelled, .failed:
            dragScroll = nil
            settle(velocity: velocity)
        default:
            break
        }
    }

    private func scrollView(at point: CGPoint) -> UIScrollView? {
        var view = card.hitTest(point, with: nil)
        while let current = view, current !== card {
            if let scroll = current as? UIScrollView, scroll.isScrollEnabled,
               scroll.contentSize.height + scroll.adjustedContentInset.top + scroll.adjustedContentInset.bottom > scroll.bounds.height + 0.5 {
                return scroll
            }
            view = current.superview
        }
        return nil
    }

    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        guard gesture === pan else { return true }
        let velocity = pan.velocity(in: containerView)
        return phase == .shown && isFront && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gesture: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    @objc private func keyboardWillShow(_ note: Notification) { keyboardChanged(note, shown: true) }
    @objc private func keyboardWillHide(_ note: Notification) { keyboardChanged(note, shown: false) }

    private func keyboardChanged(_ note: Notification, shown: Bool) {
        guard let containerView, let window = containerView.window else { return }
        var top = CGFloat.infinity
        if shown, let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue {
            let local = containerView.convert(frame, from: window.screen.coordinateSpace)
            if local.maxY >= containerView.bounds.maxY - 0.5, local.minY < containerView.bounds.maxY { top = local.minY }
        }
        Self.keyboardTop = top
        guard isFront else { return }
        let duration = note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let curve = note.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        guard duration > 0 else { return animate { Self.layoutStack(in: window) } }
        UIView.animate(withDuration: duration, delay: 0, options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curve << 16)]) {
            Self.layoutStack(in: window)
        }
    }
}

private extension CGRect {
    func blend(to other: CGRect, _ amount: CGFloat) -> CGRect {
        CGRect(x: minX + (other.minX - minX) * amount, y: minY + (other.minY - minY) * amount,
               width: width + (other.width - width) * amount, height: height + (other.height - height) * amount)
    }
}
