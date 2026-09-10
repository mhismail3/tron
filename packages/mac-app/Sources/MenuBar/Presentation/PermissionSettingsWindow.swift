import AppKit
import SwiftUI

/// One ordinary settings window; it does not remount or rewrite onboarding.
@MainActor
final class PermissionSettingsWindow: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    init(setup: EnvironmentSetup, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Tron Permissions"
        window.minSize = NSSize(width: 480, height: 400)
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: PermissionSettingsContent().environment(\.environmentSetup, setup))
        super.init(window: window)
        window.delegate = self
        window.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    func windowWillClose(_ notification: Notification) {
        // Detach the hosted surface so its probes/notification token retire;
        // accepted consent remains owned by NativeHostCoordinator.
        window?.contentViewController = nil
        onClose()
    }
}

private struct PermissionSettingsContent: View {
    @State private var statuses: [Permission: PermissionStatus] = [:]
    var body: some View {
        PermissionSetupView(statuses: $statuses)
            .padding(24)
            .frame(minWidth: 432, minHeight: 320)
    }
}
