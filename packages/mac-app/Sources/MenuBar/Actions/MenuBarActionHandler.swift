import AppKit
import Foundation
import UserNotifications

/// Typed commands emitted by the pure menu builder and executed by the
/// controller-owned action handler.
enum MenuBarAction: Equatable, Sendable {
    case showPairingInfo
    case showPermissions
    case showDebugPairingInfo
    case viewLogs
    case sendFeedback
    case quit
    case restartServer
    case uninstall
}

/// Owns the side effects behind typed menu-bar actions (launchctl,
/// NSWorkspace, dialogs, notifications, and feedback issue links).
/// `MenuBarController` owns one handler for exactly its own lifecycle.
@MainActor
final class MenuBarActionHandler {
    private let setup: EnvironmentSetup
    private let postNotification: (String, String) async -> Void
    private let presentError: (String, String) async -> Void
    private(set) var isBusy = false

    /// Handle on the menu-bar controller so re-pairing and lifecycle actions
    /// can request status refreshes and re-render the menu.
    weak var menuBarController: MenuBarController?

    init(
        setup: EnvironmentSetup,
        postNotification: @escaping (String, String) async -> Void = { title, body in
            await MenuBarNotifier.post(title: title, body: body)
        },
        presentError: @escaping (String, String) async -> Void = MenuBarActionHandler.defaultPresentNonBlockingError
    ) {
        self.setup = setup
        self.postNotification = postNotification
        self.presentError = presentError
    }

    func perform(_ action: MenuBarAction) async {
        guard !isBusy, menuBarController?.isQuitting != true else { return }
        let lifecycle = action == .restartServer || action == .uninstall
        if lifecycle { isBusy = true }
        defer { if lifecycle { isBusy = false } }
        switch action {
        case .showPairingInfo:
            menuBarController?.showPairingInfoWindow()
        case .showPermissions:
            menuBarController?.showPermissionsWindow()
        case .showDebugPairingInfo:
            await menuBarController?.showDebugPairingInfoWindow()
        case .viewLogs:
            menuBarController?.showLogsWindow()
        case .sendFeedback:
            await sendFeedback()
        case .quit:
            NSApp.terminate(nil)
        case .restartServer:
            await restartServer()
        case .uninstall:
            await confirmAndUninstall()
        }
    }

    // MARK: - Actions

    /// Requests a drain-aware Gateway restart. A registered-but-stopped job is
    /// started non-destructively; a running job uses the authenticated Gateway
    /// drain and is never force-kickstarted by this user-facing action.
    private func restartServer() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Restart blocked") else { return }
        applyBusy(.restarting)

        guard let serviceWasLoaded = await setup.launchAgentManager.isLoaded(label: setup.launchAgentLabel) else {
            await finishRestartFailure(title: "Restart blocked", message: "Could not inspect the LaunchAgent. No restart was requested.")
            return
        }
        if serviceWasLoaded {
            // A loaded launchd row can represent a registered, stopped job.
            // Missing metadata is an observation failure, not evidence that the
            // registration is absent, so refuse rather than mutating it.
            guard let runtime = await setup.launchAgentManager.runtimeInfo(label: setup.launchAgentLabel) else {
                await finishRestartFailure(title: "Restart blocked", message: "Could not inspect the loaded LaunchAgent. No restart was requested.")
                return
            }
            guard runtime.pid != nil else {
                let outcome = await setup.launchAgentManager.start(label: setup.launchAgentLabel)
                guard await finishLaunchAgentStart(outcome) else { return }
                await finishStartedRestart()
                return
            }
        } else {
            let outcome: LaunchAgentOutcome
            if await setup.launchAgentManager.isRegistered(label: setup.launchAgentLabel) {
                // A registered-but-stopped job is started with a non-destructive
                // kick. Never route it through load's bootout/re-register plan.
                outcome = await setup.launchAgentManager.start(label: setup.launchAgentLabel)
            } else {
                // An absent registration retains the existing ServiceManagement
                // load path, which performs its normal registration admission.
                outcome = await setup.launchAgentManager.load(
                    plistPath: setup.launchAgentPlistPath,
                    label: setup.launchAgentLabel
                )
            }
            guard await finishLaunchAgentStart(outcome) else { return }
            await finishStartedRestart()
            return
        }

        guard await setup.runtimeOwnershipHealthy() else {
            await finishRestartFailure(
                title: "Restart blocked",
                message: "The running LaunchAgent is not owned by this Gateway profile; repair it before restarting."
            )
            return
        }

        do {
            _ = try await setup.restartGateway()
            await finishServerStartAction(
                successTitle: "Tron restarted",
                successBody: "The Gateway drained accepted work and reconnected through launchd.",
                failureTitle: "Restart failed"
            )
        } catch let failure as GatewayRestartClient.Failure {
            await finishRestartFailure(title: "Restart failed", message: failure.userMessage)
        } catch {
            await finishRestartFailure(title: "Restart failed", message: "The Gateway restart request failed safely.")
        }
    }

    private func finishLaunchAgentStart(_ outcome: LaunchAgentOutcome) async -> Bool {
        switch outcome {
        case .ok, .alreadyLoaded:
            return true
        case .requiresApproval(let message):
            await finishRestartFailure(title: "Restart blocked", message: message, openLoginItems: true)
        case .launchdRefused(let message), .unknown(let message):
            await finishRestartFailure(title: "Restart failed", message: message)
        case .binaryMissing(let path):
            await finishRestartFailure(title: "Restart failed", message: "Binary missing: \(path)")
        }
        return false
    }

    private func finishStartedRestart() async {
        // Starting or loading is the restart intent for a stopped/absent job;
        // do not issue a second Gateway restart after launchd has been started.
        let health = await ServerHealthAwaiter.waitForHealthy(setup: setup)
        guard case .success = health else {
            await finishRestartFailure(title: "Restart failed", message: unhealthyStartMessage(result: health))
            return
        }
        guard await setup.runtimeOwnershipHealthy() else {
            await finishRestartFailure(
                title: "Restart blocked",
                message: "The running LaunchAgent is not owned by this Gateway profile; repair it before restarting."
            )
            return
        }
        await finishServerStartAction(
            successTitle: "Tron restarted",
            successBody: "The Gateway drained accepted work and reconnected through launchd.",
            failureTitle: "Restart failed",
            health: health
        )
    }

    private func finishRestartFailure(title: String, message: String, openLoginItems: Bool = false) async {
        await refreshStatus()
        if openLoginItems { LoginItemsSettingsOpener.open() }
        await postNotification(title, message)
        await presentError(title, message)
    }

    private func sendFeedback() async {
        let snapshot = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        await MenuBarFeedbackAction.present(
            snapshot: snapshot,
            setup: setup,
            token: setup.readBearerToken()
        )
    }

    private func confirmAndUninstall() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Uninstall blocked") else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall Tron?"
        alert.informativeText = """
        This unregisters the Tron Agent Login Item.

        Canonical Tron sessions and provider credentials are preserved. Legacy Tron files are also left untouched.
        """
        alert.alertStyle = .warning
        let resetOptionsStack = NSStackView()
        resetOptionsStack.orientation = .vertical
        resetOptionsStack.alignment = .leading
        resetOptionsStack.spacing = 6

        let resetSettingsCheckbox = NSButton(
            checkboxWithTitle: "Reset network cache",
            target: nil,
            action: nil
        )
        resetSettingsCheckbox.toolTip = "Also removes Tron's disposable network cache. Sessions and credentials are never removed."
        let resetCredentialsCheckbox = NSButton(
            checkboxWithTitle: "Reset Mac wrapper credential",
            target: nil,
            action: nil
        )
        resetCredentialsCheckbox.toolTip = "Also removes gateway/local-auth.json. Provider and device credentials are never removed."

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
            menuBarController?.completeUninstall()
        case .requiresApproval(let message), .launchdRefused(let message), .unknown(let message):
            if case .requiresApproval = outcome {
                LoginItemsSettingsOpener.open()
            }
            await presentError(
                "Uninstall failed",
                message
            )
        case .binaryMissing(let path):
            await presentError(
                "Uninstall failed",
                "Missing helper: \(path)"
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
        controller.refreshDebugGatewayState()
    }

    private func finishServerStartAction(
        successTitle: String,
        successBody: String,
        failureTitle: String,
        health: ServerPingResult? = nil
    ) async {
        let healthResult: ServerPingResult
        if let health {
            healthResult = health
        } else {
            healthResult = await ServerHealthAwaiter.waitForHealthy(setup: setup)
        }
        await refreshStatus()

        if case .success = healthResult {
            await postNotification(successTitle, successBody)
            return
        }

        let message = unhealthyStartMessage(result: healthResult)
        await postNotification(failureTitle, message)
        await presentError(failureTitle, message)
    }

    private func unhealthyStartMessage(result: ServerPingResult) -> String {
        switch result {
        case .success:
            return "Tron is running."
        case .unauthorized:
            return "The Tron Agent started but rejected the local bearer token. Re-pair or restart after updating /Applications/Tron.app."
        case .unreachable, .timeout, .malformedResponse:
            return "The Tron Agent was loaded by ServiceManagement, but /health never became reachable. Update or reinstall /Applications/Tron.app, then restart Tron."
        }
    }

    private func applyBusy(_ action: ServerBusyAction) {
        let current = menuBarController?.snapshot ?? ServerStatusSnapshot.checking
        menuBarController?.applySnapshot(ServerStatusSnapshot(
            state: .busy(action),
            tailscaleIP: current.tailscaleIP,
            processID: current.processID,
            uptime: current.uptime
        ))
    }

    func presentNonBlockingError(title: String, message: String) async {
        await presentError(title, message)
    }

    private static func defaultPresentNonBlockingError(title: String, message: String) async {
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
            let message = "This Xcode wrapper is a read-only companion. Use the installed Tron.app to install, pause, restart, or uninstall Stable."
            await postNotification(actionTitle, message)
            await presentError(actionTitle, message)
            return false
        }
        return true
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
