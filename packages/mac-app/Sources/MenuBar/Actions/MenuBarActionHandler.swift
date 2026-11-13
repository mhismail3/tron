import AppKit
import Foundation
import UserNotifications

enum MenuBarAction: Equatable, Sendable {
    case showPairingInfo
    case showPermissions
    case showDebugPairingInfo
    case viewLogs
    case sendFeedback
    case restartServer
    case updateGateway
    case uninstall
}

@MainActor
final class MenuBarActionHandler {
    private let setup: EnvironmentSetup

    weak var menuBarController: MenuBarController?

    init(setup: EnvironmentSetup) {
        self.setup = setup
    }

    func perform(_ action: MenuBarAction) async {
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
        case .restartServer:
            await restartServer()
        case .updateGateway:
            await rerunGatewayUpdate()
        case .uninstall:
            await confirmAndUninstall()
        }
    }

    private func restartServer() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Restart blocked") else { return }
        applyBusy(.restarting)

        guard let serviceWasLoaded = await setup.launchAgentManager.isLoaded(label: setup.launchAgentLabel) else {
            await finishRestartFailure(title: "Restart blocked", message: "Could not inspect the LaunchAgent. No restart was requested.")
            return
        }
        let needsRepair: Bool = {
            if case .needsRepair = menuBarController?.snapshot.state { return true }
            return false
        }()
        if needsRepair || !serviceWasLoaded {
            let outcome = await setup.launchAgentManager.load(
                plistPath: setup.launchAgentPlistPath,
                label: setup.launchAgentLabel
            )
            switch outcome {
            case .ok, .alreadyLoaded:
                break
            case .requiresApproval(let message):
                await finishRestartFailure(title: "Restart blocked", message: message, openLoginItems: true)
                return
            case .launchdRefused(let message), .unknown(let message):
                await finishRestartFailure(title: "Restart failed", message: message)
                return
            case .binaryMissing(let path):
                await finishRestartFailure(title: "Restart failed", message: "Binary missing: \(path)")
                return
            }

            let health = await ServerHealthAwaiter.waitForHealthy(setup: setup)
            guard case .success = health else {
                await finishRestartFailure(title: "Restart failed", message: unhealthyStartMessage(result: health))
                return
            }
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

    private func rerunGatewayUpdate() async {
        guard await ensureLaunchAgentManagementAllowed(actionTitle: "Update unavailable") else { return }
        guard case .updateIncomplete = menuBarController?.snapshot.state else { return }
        let commandID = "mac-update-\(UUID().uuidString.lowercased())"
        TronLog.shared.record(.info, event: "update.ui-state", source: "update", message: "Gateway update flow entered updating", commandId: commandID, new: "updating")
        applyBusy(.updating)
        do {
            let response = try await setup.updateGateway(commandID)
            await refreshStatus()
            let message = response.state == "ready"
                ? "Gateway update is ready as \(response.version ?? "the selected payload")."
                : "Gateway update was accepted and is still \(response.state). Restart remains available; check the selected and running identities before retrying."
            TronLog.shared.record(.info, event: "update.ui-state", source: "update", message: "Gateway update response received", commandId: commandID, old: "updating", new: response.state, outcome: "success")
            await MenuBarNotifier.post(title: response.state == "ready" ? "Tron updated" : "Update accepted", body: message)
        } catch {
            let outcome: String
            do {
                let receipt = try await setup.gatewayUpdateCommandStatus(commandID)
                outcome = receipt.status == "completed" ? "completed" : receipt.status
            } catch {
                outcome = "unknown"
            }
            await refreshStatus()
            TronLog.shared.record(.warning, event: "update.ui-state", source: "update", message: "Gateway update flow settled after request failure", commandId: commandID, old: "updating", new: outcome, outcome: "failed")
            await MenuBarNotifier.post(
                title: "Update \(outcome)",
                body: outcome == "missing"
                    ? "Gateway has no durable receipt for this update request. Check update status before starting another update."
                    : "The update request is \(outcome). Do not repeat it until Gateway status and running/selected identities are checked."
            )
        }
    }

    private func finishRestartFailure(title: String, message: String, openLoginItems: Bool = false) async {
        await refreshStatus()
        if openLoginItems { LoginItemsSettingsOpener.open() }
        await MenuBarNotifier.post(title: title, body: message)
        await presentNonBlockingError(title: title, message: message)
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
        resetCredentialsCheckbox.toolTip = "Also removes state/local-auth.json. Provider and device credentials are never removed."

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

        let result = await TronUninstaller.unregisterAndClean(
            setup: setup,
            options: TronUninstaller.Options(
                resetSettings: resetSettingsCheckbox.state == .on,
                resetCredentials: resetCredentialsCheckbox.state == .on
            )
        )
        let outcome = result.outcome
        switch outcome {
        case .ok, .alreadyLoaded:
            if !result.remainingPaths.isEmpty {
                await presentNonBlockingError(
                    title: "Uninstall incomplete",
                    message: "Tron was unregistered, but these files could not be removed:\n"
                        + result.remainingPaths.map(\.path).joined(separator: "\n")
                )
            }
            ApplicationTermination.request()
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

    private func refreshStatus() async {
        guard let controller = menuBarController else { return }
        let snapshot = await controller.explicitStatusSnapshot()
        controller.applySnapshot(snapshot)
        controller.refreshDebugGatewayState()
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

    private func presentNonBlockingError(title: String, message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func ensureLaunchAgentManagementAllowed(actionTitle: String) async -> Bool {
        guard setup.canManageLaunchAgent else {
            let message = "This Xcode wrapper is a read-only companion. Use the installed Tron.app to install, pause, restart, or uninstall Stable."
            await MenuBarNotifier.post(title: actionTitle, body: message)
            await presentNonBlockingError(title: actionTitle, message: message)
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
