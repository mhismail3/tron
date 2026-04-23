import SwiftUI
import AppKit

@main
struct TronMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.environmentSetup, EnvironmentSetup.live)
                .frame(minWidth: 540, minHeight: 720)
        }
        .windowResizability(.contentSize)
        .commandsRemoved()
    }
}

/// Top-level switcher between Wizard and Menu Bar modes.
///
/// Decision rule: presence of the `~/.tron/system/.onboarded` sentinel.
/// - Missing → wizard window.
/// - Present → window dismisses; AppDelegate transforms the process to
///   `.accessory` and installs the menu bar item.
struct RootView: View {
    @Environment(\.environmentSetup) private var setup
    @State private var mode: AppMode = .loading

    var body: some View {
        Group {
            switch mode {
            case .loading:
                ProgressView("Loading…")
                    .controlSize(.large)
            case .wizard:
                WizardView()
            case .menuBarOnly:
                MenuBarHostView(onShowPairingInfo: { mode = .wizard })
            }
        }
        .task(id: mode) {
            if mode == .loading {
                let onboarded = setup.onboardedSentinelExists()
                mode = onboarded ? .menuBarOnly : .wizard
                NSApp.setActivationPolicy(onboarded ? .accessory : .regular)
            }
        }
    }
}

enum AppMode: Equatable {
    case loading
    case wizard
    case menuBarOnly
}

/// Visible only in menu-bar mode. Acts as a launcher for the pairing-info
/// re-display flow ("Show pairing info…" menu item).
struct MenuBarHostView: View {
    let onShowPairingInfo: () -> Void

    var body: some View {
        // The window is hidden by NSApp.setActivationPolicy(.accessory) +
        // AppDelegate orderOut. This view exists so SwiftUI's WindowGroup
        // has SOMETHING to render before the window disappears.
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                if let window = NSApp.windows.first {
                    window.orderOut(nil)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var wizardCompletionObserver: NSObjectProtocol?
    private var sendFeedbackObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install single-instance lock first - if another Tron.app is
        // already running, this returns false and we exit gracefully.
        guard SingleInstanceLock.shared.acquire() else {
            NSLog("[Tron] Another Tron.app instance is already running. Exiting.")
            NSApp.terminate(nil)
            return
        }

        let setup = EnvironmentSetup.live
        if setup.onboardedSentinelExists() {
            installMenuBar(setup: setup)
        }
        // Otherwise the WindowGroup shows WizardView; menu bar is installed
        // when the wizard completes via NotificationCenter event.

        wizardCompletionObserver = NotificationCenter.default.addObserver(
            forName: .tronWizardDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The `.main` queue guarantees MainActor execution, but the
            // closure type is nominally `@Sendable`. Hop into a MainActor
            // task so we can touch `self` + AppKit APIs safely.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.installMenuBar(setup: EnvironmentSetup.live)
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
            }
        }

        sendFeedbackObserver = NotificationCenter.default.addObserver(
            forName: .tronMenuBarSendFeedback,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                await MenuBarFeedbackAction.present()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wizardCompletionObserver {
            NotificationCenter.default.removeObserver(wizardCompletionObserver)
        }
        if let sendFeedbackObserver {
            NotificationCenter.default.removeObserver(sendFeedbackObserver)
        }
        SingleInstanceLock.shared.release()
        menuBarController?.dispose()
    }

    private func installMenuBar(setup: EnvironmentSetup) {
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(setup: setup)
        menuBarController?.install()
    }
}

extension Notification.Name {
    static let tronWizardDidComplete = Notification.Name("com.tron.mac.wizard.didComplete")
    static let tronWizardShowPairingInfo = Notification.Name("com.tron.mac.wizard.showPairingInfo")
}
