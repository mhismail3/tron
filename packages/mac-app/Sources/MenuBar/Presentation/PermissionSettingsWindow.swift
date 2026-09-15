import AppKit
import SwiftUI

/// One ordinary settings window; it does not remount or rewrite onboarding.
@MainActor
final class PermissionSettingsWindow: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var measuredContentHeight: CGFloat?
    private var latestGeometryRequestID = UUID()
    init(setup: EnvironmentSetup, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let visibleFrame = NSScreen.main?.visibleFrame ?? PermissionSettingsWindowLayout.fallbackVisibleFrame
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PermissionSettingsWindowLayout.initialContentSize(for: visibleFrame)),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "Tron Permissions"
        // Keep the comfortable default while allowing a narrow/short display
        // to shrink instead of putting the title bar or content off-screen.
        window.contentMinSize = PermissionSettingsWindowLayout.minimumContentSize(for: visibleFrame)
        window.contentMaxSize = PermissionSettingsWindowLayout.maximumContentSize(for: visibleFrame)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        let hostingController = NSHostingController(rootView: PermissionSettingsContent(onContentHeight: { [weak self] height in
            self?.enqueueFit(height: height)
        }).environment(\.environmentSetup, setup))
        // AppKit owns the window's bounded geometry; SwiftUI must not replace
        // its minimum and maximum constraints with intrinsic sizing.
        hostingController.sizingOptions = []
        window.contentViewController = hostingController
        window.delegate = self
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    private func enqueueFit(height: CGFloat) {
        guard height.isFinite, height > 0, window != nil else { return }
        let requestID = UUID()
        latestGeometryRequestID = requestID
        // SwiftUI geometry is a presentation read. Always publish its fitting
        // work outside the view update, and fence queued callbacks by identity.
        DispatchQueue.main.async { [weak self] in
            self?.fitContent(height: height, requestID: requestID)
        }
    }
    private func fitContent(height: CGFloat, requestID: UUID) {
        guard requestID == latestGeometryRequestID,
              height.isFinite, height > 0, let window, window.contentViewController != nil else { return }
        guard measuredContentHeight.map({ abs($0 - height) > 1 }) != false else { return }
        measuredContentHeight = height
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? PermissionSettingsWindowLayout.fallbackVisibleFrame
        let maximum = PermissionSettingsWindowLayout.maximumContentSize(for: visible)
        let size = CGSize(width: min(window.contentLayoutRect.width, maximum.width), height: min(height + 48, maximum.height))
        window.contentMaxSize = maximum
        var frame = window.frameRect(forContentRect: CGRect(origin: .zero, size: size))
        frame.origin = CGPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.x = max(visible.minX + 12, min(frame.origin.x, visible.maxX - frame.width - 12))
        frame.origin.y = max(visible.minY + 12, min(frame.origin.y, visible.maxY - frame.height - 12))
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        window.setFrame(frame, display: true, animate: PermissionSettingsWindowLayout.shouldAnimate(isVisible: window.isVisible, reduceMotion: reduceMotion))
    }
    func windowDidChangeScreen(_ notification: Notification) {
        if let height = measuredContentHeight { enqueueFit(height: height) }
    }
    func windowWillClose(_ notification: Notification) {
        latestGeometryRequestID = UUID()
        measuredContentHeight = nil
        // Detach the hosted surface so its probes/notification token retire;
        // accepted consent remains owned by NativeHostCoordinator.
        window?.contentViewController = nil
        onClose()
    }
}

private struct PermissionSettingsContent: View {
    let onContentHeight: (CGFloat) -> Void
    @State private var statuses: [Permission: PermissionStatus] = [:]
    var body: some View {
        PermissionSetupView(statuses: $statuses, onContentHeight: onContentHeight)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Window geometry is bounded against the visible screen, not the full frame,
/// so the settings surface remains usable above the Dock and menu bar.
enum PermissionSettingsWindowLayout {
    static let idealContentSize = CGSize(width: 560, height: 640)
    static let minimumContentSize = CGSize(width: 440, height: 400)
    static let screenMargin: CGFloat = 24
    static let titleBarAllowance: CGFloat = 28
    static let fallbackVisibleFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    static func usableContentSize(for visibleFrame: CGRect) -> CGSize {
        CGSize(width: max(1, visibleFrame.width - 2 * screenMargin),
               height: max(1, visibleFrame.height - 2 * screenMargin - titleBarAllowance))
    }

    static func initialContentSize(for visibleFrame: CGRect) -> CGSize {
        let usable = usableContentSize(for: visibleFrame)
        return CGSize(width: min(idealContentSize.width, usable.width),
                      height: min(idealContentSize.height, usable.height))
    }

    static func minimumContentSize(for visibleFrame: CGRect) -> CGSize {
        let usable = usableContentSize(for: visibleFrame)
        return CGSize(width: min(minimumContentSize.width, usable.width),
                      height: min(minimumContentSize.height, usable.height))
    }

    static func maximumContentSize(for visibleFrame: CGRect) -> CGSize {
        usableContentSize(for: visibleFrame)
    }

    static func shouldAnimate(isVisible: Bool, reduceMotion: Bool) -> Bool {
        isVisible && !reduceMotion
    }
}
