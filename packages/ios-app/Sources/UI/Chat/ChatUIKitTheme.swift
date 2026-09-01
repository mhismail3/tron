import Foundation
@preconcurrency import UIKit

/// UIKit bridge for the canonical Tron palette and presentation contracts.
/// Dynamic colors resolve against the receiving view's traits; owners call
/// `refreshTheme()` for layer-backed colors that store CGColor snapshots.
enum ChatUIKitTheme {
    private static func dynamic(light: String, dark: String) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }

    static let background = dynamic(light: "#F7F8FA", dark: "#090A0C")
    static let surface = dynamic(light: "#FFFFFF", dark: "#16181D")
    static let elevatedSurface = dynamic(light: "#EEF2F6", dark: "#252A32")
    static let toolBubble = dynamic(light: "#E0F2FE", dark: "#14324A")
    static let primary = dynamic(light: "#111827", dark: "#F8FAFC")
    static let secondary = dynamic(light: "#4B5563", dark: "#AAB2BF")
    static let muted = dynamic(light: "#6B7280", dark: "#8B949E")
    static let disabled = dynamic(light: "#9CA3AF", dark: "#5B6472")
    static let emerald = dynamic(light: "#059669", dark: "#10B981")
    static let cyan = dynamic(light: "#0891B2", dark: "#06B6D4")
    static let purple = dynamic(light: "#7C3AED", dark: "#8B5CF6")
    static let indigo = dynamic(light: "#6366F1", dark: "#818CF8")
    static let amber = dynamic(light: "#D97706", dark: "#F59E0B")
    static let error = dynamic(light: "#DC2626", dark: "#EF4444")
    static let info = dynamic(light: "#0EA5E9", dark: "#38BDF8")
    static let blue = dynamic(light: "#2563EB", dark: "#3B82F6")
    static let border = dynamic(light: "#D8DEE6", dark: "#3B424D")

    @MainActor static func material() -> UIVisualEffect {
        // SwiftUI's `.thinMaterial` is the canonical Tron glass treatment.
        UIBlurEffect(style: .systemThinMaterial)
    }

    static let codeTextInsets = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    static let codeLineSpacing: CGFloat = 3

    static func tint(_ color: UIColor, opacity: CGFloat) -> UIColor {
        color.withAlphaComponent(opacity)
    }

    static func notificationColor(_ tone: ChatNotificationTone) -> UIColor {
        switch tone {
        case .error: return error
        case .warning: return amber
        case .purple: return purple
        case .information: return info
        case .command: return indigo
        case .tool, .accent: return emerald
        case .neutral: return muted
        }
    }
}

/// UIKit equivalent of `TronPulseLoadingIndicator`. It deliberately owns no
/// work outside a visible, active presentation and becomes a static dot when
/// Reduce Motion is enabled.
@MainActor
final class ChatUIKitPulseLoadingView: UIView {
    var accentColor: UIColor = ChatUIKitTheme.emerald { didSet { setNeedsDisplay() } }
    private var active = true
    private var displayLink: CADisplayLink?
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var visible = false
    nonisolated(unsafe) private var sceneObservers: [NSObjectProtocol] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        let center = NotificationCenter.default
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification] {
            sceneObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateDisplayLink() }
            })
        }
    }

    convenience init(accent: UIColor) {
        self.init(frame: .zero)
        accentColor = accent
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        let center = NotificationCenter.default
        sceneObservers.forEach { center.removeObserver($0) }
    }

    func startAnimating() {
        active = true
        startedAt = ProcessInfo.processInfo.systemUptime
        updateDisplayLink()
        setNeedsDisplay()
    }

    func stopAnimating() {
        active = false
        displayLink?.invalidate()
        displayLink = nil
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        visible = window != nil
        updateDisplayLink()
    }


    override func layoutSubviews() {
        super.layoutSubviews()
        updateDisplayLink()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let diameter = min(bounds.width, bounds.height)
        guard diameter > 0 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        if reduceMotion {
            let radius = diameter * 0.24
            context.setFillColor(accentColor.withAlphaComponent(0.72).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            return
        }
        let time = ProcessInfo.processInfo.systemUptime - startedAt
        for pulse in 0..<3 {
            let progress = (time / 1.6 - Double(pulse) / 3).truncatingRemainder(dividingBy: 1).positiveRemainder
            let scale = 0.08 + 0.92 * min(1, max(0, progress))
            let remaining = 1 - min(1, max(0, progress))
            let alpha = 0.62 * remaining * remaining
            let radius = diameter * 0.5 * scale
            context.setFillColor(accentColor.withAlphaComponent(alpha).cgColor)
            context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }
    }

    private func updateDisplayLink() {
        let sceneActive = window?.windowScene?.activationState == .foregroundActive
        let shouldAnimate = active && visible && sceneActive && !UIAccessibility.isReduceMotionEnabled
        if shouldAnimate, displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !shouldAnimate {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick() {
        // Display-link ticks continue only as a cheap paused clock while the
        // scene is backgrounded; no drawing or animation work is performed.
        guard window?.windowScene?.activationState == .foregroundActive else { return }
        setNeedsDisplay()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            setNeedsLayout(); setNeedsDisplay()
        }
        updateDisplayLink()
    }
}

private extension Double {
    var positiveRemainder: Double { self >= 0 ? self : self + ceil(-self) }
}
