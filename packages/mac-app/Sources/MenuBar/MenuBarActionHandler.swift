import AppKit
import Foundation

/// Glue between the menu-bar `NotificationCenter` events and the actual
/// side-effecting code (launchctl, NSWorkspace, AppleScript dialogs).
///
/// The builder in `MenuBarItemBuilder` posts notifications instead of
/// invoking handlers directly so the View layer stays free of AppKit
/// process control. This handler installs one observer per notification
/// in `AppDelegate` and disposes them on terminate.
///
/// Each action is fire-and-forget: a Task hops to a background queue
/// for the subprocess work, then any UI surfacing (dialog, Console.app
/// open) is hopped back to MainActor.
@MainActor
final class MenuBarActionHandler {
    private let setup: EnvironmentSetup
    private var observers: [NSObjectProtocol] = []

    /// Handle on the menu-bar controller so re-pairing can request a
    /// status refresh and pause/resume can re-render the menu.
    weak var menuBarController: MenuBarController?

    init(setup: EnvironmentSetup) {
        self.setup = setup
    }

    deinit {
        // observers must already be removed before this point because
        // NotificationCenter strongly references them; we call install /
        // uninstall explicitly from AppDelegate's lifecycle hooks.
    }

    /// Wires every menu-bar notification to its handler. Idempotent —
    /// calling twice does NOT duplicate observers (the second call no-ops
    /// when `observers` is non-empty).
    func install() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default

        observe(.tronMenuBarRestartServer, on: center) { [weak self] in
            await self?.restartServer()
        }
        observe(.tronMenuBarPauseServer, on: center) { [weak self] in
            await self?.pauseServer()
        }
        observe(.tronMenuBarResumeServer, on: center) { [weak self] in
            await self?.resumeServer()
        }
        observe(.tronMenuBarViewLogs, on: center) { [weak self] in
            await self?.viewLogs()
        }
        observe(.tronMenuBarCheckForUpdates, on: center) { [weak self] in
            await self?.checkForUpdates()
        }
        observe(.tronMenuBarUninstall, on: center) { [weak self] in
            await self?.confirmAndUninstall()
        }
        // `.tronWizardShowPairingInfo` is observed directly by
        // `MenuBarHostView` (it owns the SwiftUI mode flip back to
        // wizard). Routing it through this handler would force us to
        // plumb mode mutation through AppDelegate.
    }

    func uninstall() {
        let center = NotificationCenter.default
        for token in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
    }

    // MARK: - Subscription helper

    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter,
        handler: @MainActor @escaping () async -> Void
    ) {
        // queue: nil so the closure runs synchronously on the posting
        // thread; we hop to MainActor + spawn the async Task ourselves so
        // the call site is explicit about its threading model.
        let token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            Task { @MainActor in
                await handler()
            }
        }
        observers.append(token)
    }

    // MARK: - Actions

    func restartServer() async {
        let outcome = await setup.launchAgentManager.restart(label: TronPaths.launchAgentLabel)
        await refreshStatus()
        switch outcome {
        case .ok, .alreadyLoaded:
            return
        case .launchdRefused(let message), .unknown(let message):
            await presentNonBlockingError(title: "Restart failed", message: message)
        case .binaryMissing(let path):
            await presentNonBlockingError(title: "Restart failed", message: "Binary missing: \(path)")
        }
    }

    func pauseServer() async {
        let outcome = await setup.launchAgentManager.unload(label: TronPaths.launchAgentLabel)
        await refreshStatus()
        if case .launchdRefused(let message) = outcome {
            await presentNonBlockingError(title: "Pause failed", message: message)
        }
    }

    func resumeServer() async {
        let outcome = await setup.launchAgentManager.load(
            plistPath: setup.launchAgentPlistPath,
            label: TronPaths.launchAgentLabel
        )
        await refreshStatus()
        switch outcome {
        case .ok, .alreadyLoaded:
            return
        case .launchdRefused(let message), .unknown(let message):
            await presentNonBlockingError(title: "Resume failed", message: message)
        case .binaryMissing(let path):
            await presentNonBlockingError(title: "Resume failed", message: "Binary missing: \(path)")
        }
    }

    func viewLogs() async {
        // Console.app filtered by subsystem is the canonical way to surface
        // launchd-managed log streams. Falls back to a plain log read if
        // Console.app refuses the URL (rare).
        if let url = URL(string: "x-apple.console:?subsystem=com.tron.server") {
            NSWorkspace.shared.open(url)
            return
        }
        // Last-resort: open the system log directory in Finder so the user
        // can still get to their logs without a hung action.
        NSWorkspace.shared.activateFileViewerSelecting([
            setup.tronHome.appendingPathComponent("system/database/log.db", isDirectory: false)
        ])
    }

    func checkForUpdates() async {
        // The user-mode auto-updater (when enabled in settings) emits
        // `server.update_*` events that surface in iOS / future Mac
        // banners. There's no in-app banner surface in the Mac wrapper
        // yet, so the canonical user-facing action for "Check for
        // updates…" is opening the GitHub Releases page — that's what
        // they actually want to look at.
        //
        // We ALSO fire-and-forget the CLI's `self-update check` so the
        // in-server scheduler advances state if the user happens to have
        // the auto-updater enabled. CLI failure is logged but doesn't
        // affect the UX (GitHub Releases is the source of truth).
        if let url = URL(string: "https://github.com/mhismail3/tron/releases/latest") {
            NSWorkspace.shared.open(url)
        }
        let trigger = await runTronCommand(arguments: ["self-update", "check"])
        if trigger.exitCode != 0 {
            NSLog("[menu-bar] self-update check exited \(trigger.exitCode): \(trigger.stderr)")
        }
    }

    func confirmAndUninstall() async {
        let alert = NSAlert()
        alert.messageText = "Uninstall Tron?"
        alert.informativeText = """
        This removes the Tron menu bar app, the headless server, and the LaunchAgent.

        Your workspace files in ~/.tron/workspace/ and your conversation history in ~/.tron/system/database/ are preserved.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let result = await runTronCommand(arguments: ["uninstall"])
        if result.exitCode == 0 {
            // Quit the wrapper after a successful uninstall — there's
            // nothing left to manage. The user reopens the DMG to reinstall.
            NSApp.terminate(nil)
        } else {
            await presentNonBlockingError(
                title: "Uninstall failed",
                message: result.stderr.isEmpty ? "tron uninstall returned exit \(result.exitCode)" : result.stderr
            )
        }
    }

    // MARK: - Helpers

    private func refreshStatus() async {
        // Triggers an immediate snapshot via the poller so the menu
        // re-renders within ~100ms instead of waiting for the next 30s tick.
        guard let controller = menuBarController else { return }
        let snapshot = await ServerStatusPoller.singleSnapshot(setup: setup)
        controller.applySnapshot(snapshot)
    }

    private func presentNonBlockingError(title: String, message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        // runModal blocks the main thread but we're already on MainActor
        // and the user explicitly invoked this action, so a brief modal is
        // expected UX (mirrors System Settings deep-link confirms).
        _ = alert.runModal()
    }

    /// Runs `tron <args>` asynchronously via `Subprocess.run`. Resolves
    /// the binary through the shared `TronCLI` helper so both this
    /// handler and `MenuBarFeedbackAction` walk the same install-location
    /// search order.
    private func runTronCommand(arguments: [String]) async -> ProcessResult {
        guard let tron = TronCLI.resolveBinary() else {
            return ProcessResult(exitCode: -1, stdout: "", stderr: "tron CLI not found in PATH")
        }
        return await Subprocess.run(executable: tron, arguments: arguments)
    }
}
