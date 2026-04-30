import AppKit
import Foundation
import UserNotifications

/// Glue between the menu-bar `NotificationCenter` events and the actual
/// side-effecting code (launchctl, NSWorkspace, AppleScript dialogs).
///
/// The builder in `MenuBarItemBuilder` posts notifications instead of
/// invoking handlers directly so the View layer stays free of AppKit
/// process control. This handler installs one observer per notification
/// in `AppDelegate` and disposes them on terminate.
///
/// Each action is fire-and-forget: a Task performs subprocess work,
/// then any UI surfacing (dialogs, windows, notifications, GitHub
/// issue links) happens back on MainActor.
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
        observe(.tronMenuBarStopDevServer, on: center) { [weak self] in
            await self?.stopDevServer()
        }
        observe(.tronMenuBarShowPairingInfo, on: center) { [weak self] in
            self?.showPairingInfo()
        }
        observe(.tronMenuBarViewLogs, on: center) { [weak self] in
            self?.viewLogs()
        }
        observe(.tronMenuBarSendFeedback, on: center) { [weak self] in
            await self?.sendFeedback()
        }
        observe(.tronMenuBarCheckForUpdates, on: center) { [weak self] in
            await self?.checkForUpdates()
        }
        observe(.tronMenuBarUninstall, on: center) { [weak self] in
            await self?.confirmAndUninstall()
        }
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
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Restart blocked") else { return }
        applyBusy(.restarting)
        guard await syncManagedSkillsForServerStart(action: "restart") else {
            await refreshStatus()
            return
        }
        let outcome = await InstallLaunchAgentRunner.ensureLoaded(
            manager: setup.launchAgentManager,
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        await refreshStatus()
        switch outcome {
        case .ok, .alreadyLoaded:
            await MenuBarNotifier.post(title: "Tron server restarted", body: "The menu bar status has been refreshed.")
            return
        case .requiresApproval(let message):
            LoginItemsSettingsOpener.open()
            await MenuBarNotifier.post(title: "Restart blocked", body: message)
            await presentNonBlockingError(title: "Restart blocked", message: message)
        case .launchdRefused(let message), .unknown(let message):
            await MenuBarNotifier.post(title: "Restart failed", body: message)
            await presentNonBlockingError(title: "Restart failed", message: message)
        case .binaryMissing(let path):
            let message = "Binary missing: \(path)"
            await MenuBarNotifier.post(title: "Restart failed", body: message)
            await presentNonBlockingError(title: "Restart failed", message: message)
        }
    }

    func pauseServer() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Pause blocked") else { return }
        applyBusy(.pausing)
        let outcome = await setup.launchAgentManager.unload(label: setup.launchAgentLabel)
        await refreshStatus()
        switch outcome {
        case .ok, .alreadyLoaded:
            await MenuBarNotifier.post(title: "Tron server paused", body: "Resume it from the Tron menu bar when needed.")
        case .requiresApproval(let message):
            LoginItemsSettingsOpener.open()
            await MenuBarNotifier.post(title: "Pause blocked", body: message)
            await presentNonBlockingError(title: "Pause blocked", message: message)
        case .launchdRefused(let message), .unknown(let message):
            await MenuBarNotifier.post(title: "Pause failed", body: message)
            await presentNonBlockingError(title: "Pause failed", message: message)
        case .binaryMissing(let path):
            let message = "Binary missing: \(path)"
            await MenuBarNotifier.post(title: "Pause failed", body: message)
            await presentNonBlockingError(title: "Pause failed", message: message)
        }
    }

    func resumeServer() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Resume blocked") else { return }
        applyBusy(.resuming)
        guard await syncManagedSkillsForServerStart(action: "resume") else {
            await refreshStatus()
            return
        }
        let outcome = await setup.launchAgentManager.load(
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        await refreshStatus()
        switch outcome {
        case .ok, .alreadyLoaded:
            await MenuBarNotifier.post(title: "Tron server resumed", body: "The menu bar status has been refreshed.")
            return
        case .requiresApproval(let message):
            LoginItemsSettingsOpener.open()
            await MenuBarNotifier.post(title: "Resume blocked", body: message)
            await presentNonBlockingError(title: "Resume blocked", message: message)
        case .launchdRefused(let message), .unknown(let message):
            await MenuBarNotifier.post(title: "Resume failed", body: message)
            await presentNonBlockingError(title: "Resume failed", message: message)
        case .binaryMissing(let path):
            let message = "Binary missing: \(path)"
            await MenuBarNotifier.post(title: "Resume failed", body: message)
            await presentNonBlockingError(title: "Resume failed", message: message)
        }
    }

    func stopDevServer() async {
        let current = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        let port = current.port ?? setup.serverPort
        applyBusy(.stoppingDevServer)

        switch await setup.stopDevServer(port) {
        case .stopped:
            if setup.canManageLaunchAgent {
                guard await syncManagedSkillsForServerStart(action: "resume") else {
                    await refreshStatus()
                    return
                }
            }
            let outcome = await resumeServerAfterDevStop()
            await refreshStatus()
            switch outcome {
            case .ok, .alreadyLoaded:
                await MenuBarNotifier.post(title: "Dev server stopped", body: "The installed Tron Server is running again.")
            case .requiresApproval(let message):
                LoginItemsSettingsOpener.open()
                await MenuBarNotifier.post(title: "Resume blocked", body: message)
                await presentNonBlockingError(title: "Resume blocked", message: message)
            case .launchdRefused(let message), .unknown(let message):
                await MenuBarNotifier.post(title: "Resume failed", body: message)
                await presentNonBlockingError(title: "Resume failed", message: message)
            case .binaryMissing(let path):
                let message = "Binary missing: \(path)"
                await MenuBarNotifier.post(title: "Resume failed", body: message)
                await presentNonBlockingError(title: "Resume failed", message: message)
            }
        case .notActive:
            await refreshStatus()
            await MenuBarNotifier.post(title: "Dev server not active", body: "The menu bar status has been refreshed.")
        case .failed(let message):
            await refreshStatus()
            await MenuBarNotifier.post(title: "Stop dev server failed", body: message)
            await presentNonBlockingError(title: "Stop dev server failed", message: message)
        }
    }

    private func syncManagedSkillsForServerStart(action: String) async -> Bool {
        switch await setup.syncManagedSkills() {
        case .synced:
            return true
        case .failed(let message):
            let title = action == "resume" ? "Resume blocked" : "Restart blocked"
            await MenuBarNotifier.post(title: title, body: message)
            await presentNonBlockingError(title: title, message: "Could not sync bundled skills: \(message)")
            return false
        }
    }

    func showPairingInfo() {
        menuBarController?.showPairingInfoWindow(setup: setup)
    }

    func viewLogs() {
        menuBarController?.showLogsWindow(setup: setup)
    }

    func sendFeedback() async {
        let snapshot = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        await MenuBarFeedbackAction.present(snapshot: snapshot)
    }

    func checkForUpdates() async {
        if let url = URL(string: "https://github.com/mhismail3/tron/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    func confirmAndUninstall() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Uninstall blocked") else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Tron?"
        alert.informativeText = """
        This unregisters the Tron Server Login Item.

        Your workspace files in ~/.tron/workspace/ and your conversation history in ~/.tron/system/database/ are preserved.
        """
        alert.alertStyle = .warning
        let resetOptionsStack = NSStackView()
        resetOptionsStack.orientation = .vertical
        resetOptionsStack.alignment = .leading
        resetOptionsStack.spacing = 6

        let resetSettingsCheckbox = NSButton(
            checkboxWithTitle: "Reset settings",
            target: nil,
            action: nil
        )
        resetSettingsCheckbox.toolTip = "Also removes ~/.tron/system/settings.json. The database is never removed."
        let resetCredentialsCheckbox = NSButton(
            checkboxWithTitle: "Reset saved credentials",
            target: nil,
            action: nil
        )
        resetCredentialsCheckbox.toolTip = "Also removes ~/.tron/system/auth.json. The database is never removed."

        resetSettingsCheckbox.sizeToFit()
        resetCredentialsCheckbox.sizeToFit()
        let checkboxWidth = max(
            resetSettingsCheckbox.fittingSize.width,
            resetCredentialsCheckbox.fittingSize.width
        )
        let accessoryWidth = max(checkboxWidth, 300)
        let accessoryHeight = resetSettingsCheckbox.fittingSize.height
            + resetCredentialsCheckbox.fittingSize.height
            + resetOptionsStack.spacing
            + 8
        let resetOptionsAccessory = NSView(frame: NSRect(
            x: 0,
            y: 0,
            width: accessoryWidth,
            height: accessoryHeight
        ))
        resetOptionsStack.translatesAutoresizingMaskIntoConstraints = false
        resetOptionsStack.addArrangedSubview(resetSettingsCheckbox)
        resetOptionsStack.addArrangedSubview(resetCredentialsCheckbox)
        resetOptionsAccessory.addSubview(resetOptionsStack)
        NSLayoutConstraint.activate([
            resetOptionsStack.leadingAnchor.constraint(equalTo: resetOptionsAccessory.leadingAnchor),
            resetOptionsStack.trailingAnchor.constraint(lessThanOrEqualTo: resetOptionsAccessory.trailingAnchor),
            resetOptionsStack.topAnchor.constraint(equalTo: resetOptionsAccessory.topAnchor, constant: 4),
            resetOptionsStack.bottomAnchor.constraint(equalTo: resetOptionsAccessory.bottomAnchor, constant: -4),
        ])
        alert.accessoryView = resetOptionsAccessory
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        let outcome = await TronUninstaller.unregisterAndClean(
            setup: setup,
            options: TronUninstaller.Options(
                resetSettings: resetSettingsCheckbox.state == .on,
                resetCredentials: resetCredentialsCheckbox.state == .on
            )
        )
        switch outcome {
        case .ok, .alreadyLoaded:
            NSApp.terminate(nil)
        case .requiresApproval(let message), .launchdRefused(let message), .unknown(let message):
            if case .requiresApproval = outcome {
                LoginItemsSettingsOpener.open()
            }
            await presentNonBlockingError(
                title: "Uninstall failed",
                message: message
            )
        case .binaryMissing(let path):
            await presentNonBlockingError(
                title: "Uninstall failed",
                message: "Missing helper: \(path)"
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

    private func applyBusy(_ action: ServerBusyAction) {
        let current = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        menuBarController?.applySnapshot(ServerStatusSnapshot(
            state: .busy(action),
            port: current.port ?? setup.serverPort,
            tailscaleIP: current.tailscaleIP,
            bearerToken: current.bearerToken,
            processID: current.processID,
            uptime: current.uptime,
            isDevServerActive: current.isDevServerActive
        ))
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

    private func ensureLaunchAgentManagementAllowed(actionTitle: String) async -> Bool {
        guard setup.canManageLaunchAgent else {
            let message = "This Xcode wrapper is running in companion mode. Use the installed Tron.app for server install, pause, restart, and uninstall actions, or use the isolated install scheme for reinstall testing."
            await MenuBarNotifier.post(title: actionTitle, body: message)
            await presentNonBlockingError(title: actionTitle, message: message)
            return false
        }
        return true
    }

    private func resumeServerAfterDevStop() async -> LaunchAgentOutcome {
        if setup.canManageLaunchAgent {
            return await setup.launchAgentManager.load(
                plistPath: setup.launchAgentPlistPath,
                label: setup.launchAgentLabel
            )
        }

        let executable = TronPaths.releaseApplicationURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("Tron", isDirectory: false)
        guard FileManager.default.fileExists(atPath: executable.path) else {
            return .launchdRefused(
                message: "The installed Tron.app is required to resume the production server after stopping dev mode."
            )
        }
        let result = await Subprocess.run(
            executable: executable,
            arguments: ["--tron-start-server-and-quit"]
        )
        guard result.exitCode == 0 else {
            return .launchdRefused(
                message: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return .ok
    }

}

enum MenuBarNotifier {
    static func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "tron-menu-\(UUID().uuidString)", content: content, trigger: nil)
        try? await center.add(request)
    }
}
