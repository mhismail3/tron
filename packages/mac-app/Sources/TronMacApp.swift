import SwiftUI
import AppKit

@main
struct TronMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.environmentSetup, EnvironmentSetup.live)
                // App-wide tint — every system control (focus rings,
                // default buttons, toggles) inherits emerald instead
                // of system blue. Custom controls in
                // `WizardButtonStyle.swift` reach for `.tronEmerald`
                // directly so they stay emerald even if a sub-view
                // overrides the tint locally.
                .tint(Color.tronEmerald)
                // Width is pinned at 480 for every step, but height
                // is driven per-step by `WizardStep.preferredHeight`
                // so the window grows/shrinks to fit the content.
                // `RootView` propagates the chosen size per mode
                // (loading/wizard/menu-bar-only); `.contentSize`
                // below tells SwiftUI to size the window to whatever
                // that content reports, and the wizard's internal
                // `.animation` on the frame value produces a smooth
                // spring-driven resize. `WindowConfigurator` still
                // strips `.resizable` from the style mask so the
                // user can't drag-resize.
                // `.containerBackground(_:for: .window)` paints the
                // material at the WINDOW level — under the entire
                // SwiftUI content view, on top of nothing. On macOS 26
                // (Tahoe) `.regularMaterial` automatically picks up the
                // Liquid Glass treatment with the live wallpaper bleed-
                // through; on older macOS it falls back to vibrancy.
                // Combined with the early-running `WindowConfigurator`
                // that flips `isOpaque = false`, this gives the
                // single-canvas glass look without a separate titlebar
                // region.
                .containerBackground(.regularMaterial, for: .window)
                .configureHostingWindow { window in
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
                    window.isMovableByWindowBackground = true
                    window.styleMask.insert(.fullSizeContentView)
                    // Strip the resize affordance entirely — paired with
                    // the fixed `.frame(...)` and `.contentSize`
                    // resizability above, the user has no way to drag
                    // the window larger.
                    window.styleMask.remove(.resizable)
                    // Anti-aliased rounded corners on the content view's
                    // layer so the glass clips cleanly against the
                    // wallpaper instead of showing a hard rectangular
                    // edge against the material.
                    window.contentView?.wantsLayer = true
                    window.contentView?.layer?.cornerRadius = 16
                    window.contentView?.layer?.masksToBounds = true
                }
        }
        .windowStyle(.hiddenTitleBar)
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
///
/// The menu-bar's "Show pairing info…" item flips `mode` back to
/// `.wizard` and pre-seeds `wizardEntryStep = .pairingInfo` so the
/// wizard remounts directly at the pairing step. The activation
/// policy follows mode: `.regular` for the wizard window, `.accessory`
/// for menu-bar-only.
struct RootView: View {
    @Environment(\.environmentSetup) private var setup
    @State private var mode: AppMode = .loading
    @State private var wizardEntryStep: WizardStep?

    var body: some View {
        Group {
            switch mode {
            case .loading:
                // Pin the loading canvas to a plausible wizard size so
                // the window opens at roughly the right dimensions
                // before `WizardView` takes over. Height = 360 matches
                // the default `WizardStep.preferredHeight` for the
                // most common opening step (Welcome).
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(width: 480, height: 360)
            case .wizard:
                // `WizardView` → `WizardShell` applies its own per-step
                // `.frame(width: 480, height: displayStep.preferredHeight)`
                // with an animated spring, so the window resizes as
                // the user navigates between steps.
                WizardView(initialStep: wizardEntryStep)
            case .menuBarOnly:
                MenuBarHostView(onShowPairingInfo: {
                    wizardEntryStep = .pairingInfo
                    mode = .wizard
                })
            }
        }
        .task(id: mode) {
            switch mode {
            case .loading:
                let onboarded = setup.onboardedSentinelExists()
                mode = onboarded ? .menuBarOnly : .wizard
            case .wizard:
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                // Window chrome (transparency, hidden titlebar, rounded
                // corners) is configured via `WindowConfigurator` in the
                // SwiftUI body — it runs synchronously on the first
                // layout pass, before the window is shown, avoiding a
                // one-frame flash of opaque chrome that this `.task`
                // path used to produce.
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            case .menuBarOnly:
                NSApp.setActivationPolicy(.accessory)
                wizardEntryStep = nil
            }
        }
    }
}

enum AppMode: Equatable {
    case loading
    case wizard
    case menuBarOnly
}

/// Visible only in menu-bar mode. Renders a 1×1 hidden placeholder so
/// SwiftUI's WindowGroup has SOMETHING to draw before the window is
/// orderOut'd. Listens for `.tronWizardShowPairingInfo` (posted by the
/// menu-bar item builder) and asks `RootView` to flip back to wizard
/// mode at the pairing step.
struct MenuBarHostView: View {
    let onShowPairingInfo: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                if let window = NSApp.windows.first {
                    window.orderOut(nil)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .tronWizardShowPairingInfo)) { _ in
                onShowPairingInfo()
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var actionHandler: MenuBarActionHandler?
    private var wizardCompletionObserver: NSObjectProtocol?
    private var sendFeedbackObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip the single-instance lock when running under XCTest. The
        // test host app launches inside `xcodebuild test` and would
        // otherwise refuse to start whenever a real Tron.app is running
        // on the dev machine, breaking tests for any contributor who
        // dogfoods. The env var is set by Xcode for every test run.
        let isUnderXCTest = ProcessInfo.processInfo.environment["XCTestSessionIdentifier"] != nil
        if !isUnderXCTest {
            // Install single-instance lock first — if another Tron.app
            // is already running, this returns false and we exit
            // gracefully.
            guard SingleInstanceLock.shared.acquire() else {
                NSLog("[Tron] Another Tron.app instance is already running. Exiting.")
                NSApp.terminate(nil)
                return
            }
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
        // Tear down menu bar + action observers BEFORE releasing the
        // single-instance lock so a second wrapper that races to launch
        // sees a clean state (no stale observers, no half-disposed
        // status item) by the time it acquires the lock.
        actionHandler?.uninstall()
        actionHandler = nil
        menuBarController?.dispose()
        menuBarController = nil
        SingleInstanceLock.shared.release()
    }

    private func installMenuBar(setup: EnvironmentSetup) {
        guard menuBarController == nil else { return }
        let controller = MenuBarController(setup: setup)
        let handler = MenuBarActionHandler(setup: setup)
        handler.menuBarController = controller
        // The "Show pairing info…" menu item is wired in `MenuBarHostView`
        // (see RootView), which owns the SwiftUI mode flip back to
        // wizard. AppDelegate intentionally stays out of that path.
        handler.install()
        controller.install()
        menuBarController = controller
        actionHandler = handler
    }
}

extension Notification.Name {
    static let tronWizardDidComplete = Notification.Name("com.tron.mac.wizard.didComplete")
    /// Posted by `MenuBarItemBuilder` when the user clicks "Show pairing
    /// info…" in the menu bar. Observed by `MenuBarHostView`, which
    /// asks `RootView` to flip back to wizard mode pre-seeded at the
    /// pairing step. Tests pin the descriptor sequence in
    /// `MenuBarItemBuilderTests.swift`.
    static let tronWizardShowPairingInfo = Notification.Name("com.tron.mac.wizard.showPairingInfo")
}
