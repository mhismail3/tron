import SwiftUI
import AppKit
import Darwin

@main
struct TronMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        TronFontLoader.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if TronMacRuntime.isRunningUnderTests() {
                    TestHostView()
                } else if MacCommandLineMode.current.isCommand {
                    CommandModeHostView()
                } else {
                    RootView()
                }
            }
                .environment(\.environmentSetup, EnvironmentSetup.live)
                // App-wide tint — every system control (focus rings,
                // default buttons, toggles) inherits emerald instead
                // of system blue. Custom controls in
                // `WizardButtonStyle.swift` reach for `.tronEmerald`
                // directly so they stay emerald even if a sub-view
                // overrides the tint locally.
                .tint(Color.tronEmerald)
                // Width is pinned at 480, and wizard height is fixed
                // to the tallest onboarding step. `RootView`
                // propagates the chosen size per mode
                // (loading/wizard/menu-bar-only); `.contentSize`
                // below tells SwiftUI to size the window to whatever
                // that content reports. `WindowConfigurator` still
                // strips `.resizable` from the style mask so the user
                // can't drag-resize.
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
                    if TronMacRuntime.isRunningUnderTests() {
                        window.orderOut(nil)
                        return
                    }
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.titlebarAppearsTransparent = true
                    window.titleVisibility = .hidden
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

enum TronMacRuntime {
    /// Xcode has exposed different test-host markers across XCTest,
    /// Swift Testing, and runner generations. Treat any known marker as
    /// a test host so CI never boots wizard/menu side effects just to run
    /// logic tests.
    static func isRunningUnderTests(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["TRON_MAC_TEST_HOST"] == "1"
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}

struct TestHostView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
    }
}

/// Top-level switcher between Wizard and Menu Bar modes.
///
/// Decision rule: presence of the `~/.tron/internal/run/.onboarded` sentinel.
/// - Missing → wizard window.
/// - Present → window dismisses; AppDelegate transforms the process to
///   `.accessory` and installs the menu bar item.
///
/// The activation policy follows mode: `.regular` for the wizard
/// window, `.accessory` for menu-bar-only. Post-onboarding pairing
/// info is handled by a dedicated menu-bar window controller rather
/// than remounting the wizard.
struct RootView: View {
    @Environment(\.environmentSetup) private var setup
    @State private var mode: AppMode = .loading

    var body: some View {
        Group {
            switch mode {
            case .loading:
                // Pin the loading canvas to the final wizard size so
                // the window does not resize between loading and the
                // first step.
                ProgressView("Loading…")
                    .controlSize(.large)
                    .frame(width: WizardLayout.width, height: WizardLayout.height)
            case .wizard:
                // `WizardView` → `WizardShell` applies one fixed
                // `.frame(width: WizardLayout.width, height: WizardLayout.height)`
                // so step transitions do not fight window resizing.
                WizardView()
            case .menuBarOnly:
                MenuBarHostView()
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
/// SwiftUI's WindowGroup has something to draw before the window is
/// orderOut'd.
struct MenuBarHostView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                if let window = NSApp.windows.first {
                    window.orderOut(nil)
                }
            }
    }
}

struct CommandModeHostView: View {
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear {
                switch MacCommandLineMode.current {
                case .probeScreenRecordingAndQuit:
                    NSApp.setActivationPolicy(.prohibited)
                case .startServerAndQuit, .uninstallAndQuit, .normal:
                    NSApp.setActivationPolicy(.accessory)
                }
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBarController: MenuBarController?
    private var actionHandler: MenuBarActionHandler?
    private var wizardCompletionObserver: NSObjectProtocol?
    private var instanceLock: SingleInstanceLock?

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch MacCommandLineMode.current {
        case .startServerAndQuit:
            startServerAndQuit()
            return
        case .uninstallAndQuit:
            uninstallAndQuit()
            return
        case .probeScreenRecordingAndQuit(let resultPath):
            probeScreenRecordingAndQuit(resultPath: resultPath)
            return
        case .normal:
            break
        }

        // The test host app launches inside `xcodebuild test`; skip
        // wrapper locks, menu-bar setup, launchd checks, and wizard
        // observers so logic tests do not manage a real server.
        if TronMacRuntime.isRunningUnderTests() {
            return
        }

        let setup = EnvironmentSetup.live
        // Install the per-wrapper lock first. The installed release and
        // an Xcode Debug companion intentionally use different lock
        // files so wrapper UI work can happen while production runs.
        let lock = SingleInstanceLock(lockFileURL: setup.wrapperLockPath)
        guard lock.acquire() else {
            NSLog("[Tron] Another instance of this Tron wrapper is already running. Exiting.")
            NSApp.terminate(nil)
            return
        }
        instanceLock = lock

        if setup.onboardedSentinelExists() {
            installMenuBar(setup: setup, context: .existingOnboardedLaunch)
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
                let setup = EnvironmentSetup.live
                if !setup.canManageLaunchAgent {
                    NSLog("[Tron] Debug companion wizard completion does not install the production menu bar.")
                    return
                }
                self.installMenuBar(setup: setup, context: .wizardCompletion)
                NSApp.setActivationPolicy(.accessory)
                for window in NSApp.windows {
                    window.orderOut(nil)
                }
            }
        }
    }

    private func startServerAndQuit() {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            var exitCode: Int32 = 1
            defer {
                if exitCode == 0 {
                    NSApp.terminate(nil)
                } else {
                    Darwin.exit(exitCode)
                }
            }
            let result = await MacCommandModeServerStarter.start(setup: EnvironmentSetup.live)
            switch result {
            case .ok:
                exitCode = 0
            case .invalidApplicationLocation(let problem):
                NSLog("[Tron] Cannot start server from command mode: %@", problem)
            case .invalidBundledHelper(let problem):
                NSLog("[Tron] Cannot start server from command mode: %@", problem)
            case .unmanagedWrapper:
                NSLog("[Tron] Cannot start server from command mode: Debug companion mode does not manage the production server")
            case .launchAgentFailed(let outcome):
                NSLog("[Tron] Command-mode server start returned %@", String(describing: outcome))
            case .unhealthy(let health):
                NSLog(
                    "[Tron] Command-mode server start loaded the Login Item but /health did not pass: %@",
                    String(describing: health)
                )
            }
        }
    }

    private func uninstallAndQuit() {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            defer { NSApp.terminate(nil) }
            let outcome = await TronUninstaller.unregisterAndClean(setup: EnvironmentSetup.live)
            switch outcome {
            case .ok, .alreadyLoaded:
                NSLog("[Tron] Unregistered Tron Server")
            case .requiresApproval(let message), .launchdRefused(let message), .unknown(let message):
                NSLog("[Tron] Command-mode uninstall failed: %@", message)
            case .binaryMissing(let path):
                NSLog("[Tron] Command-mode uninstall missing helper: %@", path)
            }
        }
    }

    private func probeScreenRecordingAndQuit(resultPath: String?) {
        NSApp.setActivationPolicy(.prohibited)
        for window in NSApp.windows {
            window.orderOut(nil)
        }
        MacPermissionProbe.writeCurrentScreenRecordingProbeResult(to: resultPath)
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let wizardCompletionObserver {
            NotificationCenter.default.removeObserver(wizardCompletionObserver)
        }
        // Tear down menu bar + action observers BEFORE releasing the
        // single-instance lock so a second wrapper that races to launch
        // sees a clean state (no stale observers, no half-disposed
        // status item) by the time it acquires the lock.
        actionHandler?.uninstall()
        actionHandler = nil
        menuBarController?.dispose()
        menuBarController = nil
        instanceLock?.release()
        instanceLock = nil
    }

    private func installMenuBar(setup: EnvironmentSetup, context: MacAppStartupContext) {
        guard menuBarController == nil else { return }
        let controller = MenuBarController(setup: setup)
        let handler = MenuBarActionHandler(setup: setup)
        handler.menuBarController = controller
        handler.install()
        controller.install()
        menuBarController = controller
        actionHandler = handler
        Task { [weak controller] in
            _ = await MacAppStartupMaintenance.run(
                setup: setup,
                controller: controller,
                context: context
            )
        }
    }
}

extension Notification.Name {
    static let tronWizardDidComplete = Notification.Name("com.tron.mac.wizard.didComplete")
}
