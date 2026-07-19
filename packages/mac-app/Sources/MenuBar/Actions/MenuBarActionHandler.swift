import AppKit
import Foundation
import UserNotifications

/// Typed commands emitted by the pure menu builder and executed by the
/// controller-owned action handler.
enum MenuBarAction: Equatable, Sendable {
    case showPairingInfo
    case viewLogs
    case sendFeedback
    case pauseServer
    case resumeServer
    case restartServer
    case stopDevServer
    case uninstall
}

/// Owns the side effects behind typed menu-bar actions (launchctl,
/// NSWorkspace, dialogs, notifications, and feedback issue links).
/// `MenuBarController` owns one handler for exactly its own lifecycle.
@MainActor
final class MenuBarActionHandler {
    private let setup: EnvironmentSetup

    /// Handle on the menu-bar controller so re-pairing can request a
    /// status refresh and pause/resume can re-render the menu.
    weak var menuBarController: MenuBarController?

    init(setup: EnvironmentSetup) {
        self.setup = setup
    }

    func perform(_ action: MenuBarAction) async {
        switch action {
        case .showPairingInfo:
            menuBarController?.showPairingInfoWindow()
        case .viewLogs:
            menuBarController?.showLogsWindow()
        case .sendFeedback:
            await sendFeedback()
        case .pauseServer:
            await pauseServer()
        case .resumeServer:
            await resumeServer()
        case .restartServer:
            await restartServer()
        case .stopDevServer:
            await stopDevServer()
        case .uninstall:
            await confirmAndUninstall()
        }
    }

    // MARK: - Actions

    private func restartServer() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Restart blocked") else { return }
        applyBusy(.restarting)
        let outcome = await LaunchAgentLoader.ensureLoaded(
            manager: setup.launchAgentManager,
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        switch outcome {
        case .ok, .alreadyLoaded:
            await finishServerStartAction(
                successTitle: "Tron server restarted",
                successBody: "The menu bar status has been refreshed.",
                failureTitle: "Restart failed"
            )
            return
        case .requiresApproval(let message):
            await refreshStatus()
            LoginItemsSettingsOpener.open()
            await MenuBarNotifier.post(title: "Restart blocked", body: message)
            await presentNonBlockingError(title: "Restart blocked", message: message)
        case .launchdRefused(let message), .unknown(let message):
            await refreshStatus()
            await MenuBarNotifier.post(title: "Restart failed", body: message)
            await presentNonBlockingError(title: "Restart failed", message: message)
        case .binaryMissing(let path):
            await refreshStatus()
            let message = "Binary missing: \(path)"
            await MenuBarNotifier.post(title: "Restart failed", body: message)
            await presentNonBlockingError(title: "Restart failed", message: message)
        }
    }

    private func pauseServer() async {
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

    private func resumeServer() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Resume blocked") else { return }
        applyBusy(.resuming)
        let outcome = await setup.launchAgentManager.load(
            plistPath: setup.launchAgentPlistPath,
            label: setup.launchAgentLabel
        )
        switch outcome {
        case .ok, .alreadyLoaded:
            await finishServerStartAction(
                successTitle: "Tron server resumed",
                successBody: "The menu bar status has been refreshed.",
                failureTitle: "Resume failed"
            )
            return
        case .requiresApproval(let message):
            await refreshStatus()
            LoginItemsSettingsOpener.open()
            await MenuBarNotifier.post(title: "Resume blocked", body: message)
            await presentNonBlockingError(title: "Resume blocked", message: message)
        case .launchdRefused(let message), .unknown(let message):
            await refreshStatus()
            await MenuBarNotifier.post(title: "Resume failed", body: message)
            await presentNonBlockingError(title: "Resume failed", message: message)
        case .binaryMissing(let path):
            await refreshStatus()
            let message = "Binary missing: \(path)"
            await MenuBarNotifier.post(title: "Resume failed", body: message)
            await presentNonBlockingError(title: "Resume failed", message: message)
        }
    }

    private func stopDevServer() async {
        let current = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        let port = current.state.runningPort ?? setup.serverPort
        applyBusy(.stoppingDevServer)

        switch await setup.stopDevServer(port) {
        case .stopped:
            let outcome = await resumeServerAfterDevStop()
            switch outcome {
            case .ok, .alreadyLoaded:
                await finishServerStartAction(
                    successTitle: "Dev server stopped",
                    successBody: "The installed Tron Server is running again.",
                    failureTitle: "Resume failed"
                )
            case .requiresApproval(let message):
                await refreshStatus()
                LoginItemsSettingsOpener.open()
                await MenuBarNotifier.post(title: "Resume blocked", body: message)
                await presentNonBlockingError(title: "Resume blocked", message: message)
            case .launchdRefused(let message), .unknown(let message):
                await refreshStatus()
                await MenuBarNotifier.post(title: "Resume failed", body: message)
                await presentNonBlockingError(title: "Resume failed", message: message)
            case .binaryMissing(let path):
                await refreshStatus()
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

    private func sendFeedback() async {
        let snapshot = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        await MenuBarFeedbackAction.present(snapshot: snapshot, token: setup.readBearerToken())
    }

    private func confirmAndUninstall() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Uninstall blocked") else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Tron?"
        alert.informativeText = """
        This unregisters the Tron Server Login Item.

        Your workspace files in ~/.tron/workspace/ and your conversation history in ~/.tron/internal/database/ are preserved.
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
        resetSettingsCheckbox.toolTip = "Also clears [settings] overrides from ~/.tron/profiles/user/profile.toml. The database is never removed."
        let resetCredentialsCheckbox = NSButton(
            checkboxWithTitle: "Reset saved credentials",
            target: nil,
            action: nil
        )
        resetCredentialsCheckbox.toolTip = "Also removes ~/.tron/profiles/auth.json. The database is never removed."

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

    private func finishServerStartAction(
        successTitle: String,
        successBody: String,
        failureTitle: String
    ) async {
        let health = await ServerHealthAwaiter.waitForHealthy(setup: setup)
        await refreshStatus()

        if case .success = health {
            await MenuBarNotifier.post(title: successTitle, body: successBody)
            return
        }

        let message = unhealthyStartMessage(result: health)
        await MenuBarNotifier.post(title: failureTitle, body: message)
        await presentNonBlockingError(title: failureTitle, message: message)
    }

    private func unhealthyStartMessage(result: ServerPingResult) -> String {
        switch result {
        case .success:
            return "The server is running."
        case .unauthorized:
            return "The Tron Server started but rejected the local bearer token. Re-pair or restart after updating /Applications/Tron.app."
        case .unreachable, .timeout, .malformedResponse:
            return "The Tron Server was loaded by ServiceManagement, but /health never became reachable. Update or reinstall /Applications/Tron.app, then restart the server."
        }
    }

    private func applyBusy(_ action: ServerBusyAction) {
        let current = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        menuBarController?.applySnapshot(ServerStatusSnapshot(
            state: .busy(action),
            tailscaleIP: current.tailscaleIP,
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
