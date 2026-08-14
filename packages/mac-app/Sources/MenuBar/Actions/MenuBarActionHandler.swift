import AppKit
import Foundation
import UserNotifications

enum MenuBarAction: Equatable, Sendable {
    case showPairingInfo
    case viewLogs
    case sendFeedback
    case pauseGateway
    case resumeGateway
    case restartGateway
    case uninstall
}

/// Main-actor bridge from menu commands to the one lifecycle coordinator.
@MainActor
final class MenuBarActionHandler {
    private let dependencies: GatewayDependencies
    private let coordinator: GatewayLifecycleCoordinator
    weak var menuBarController: MenuBarController?

    init(
        dependencies: GatewayDependencies,
        coordinator: GatewayLifecycleCoordinator
    ) {
        self.dependencies = dependencies
        self.coordinator = coordinator
    }

    func perform(_ action: MenuBarAction) async {
        switch action {
        case .showPairingInfo:
            menuBarController?.showPairingInfoWindow()
        case .viewLogs:
            menuBarController?.showLogsWindow()
        case .sendFeedback:
            await sendFeedback()
        case .pauseGateway:
            await run(.pause, successTitle: "Tron paused")
        case .resumeGateway:
            await run(.resume, successTitle: "Tron resumed")
        case .restartGateway:
            await run(.restart, successTitle: "Tron restarted")
        case .uninstall:
            await confirmAndUninstall()
        }
    }

    private func sendFeedback() async {
        let snapshot = await coordinator.currentSnapshot()
        await MenuBarFeedbackAction.present(
            snapshot: snapshot,
            dependencies: dependencies
        )
    }

    private func run(
        _ command: GatewayLifecycleCommand,
        successTitle: String
    ) async {
        let result = await coordinator.perform(command)
        switch result {
        case .succeeded:
            await MenuBarNotifier.post(
                title: successTitle,
                body: "The menu bar status is up to date."
            )
        case .failed(let failure):
            if failure == .approvalRequired { LoginItemsSettingsOpener.open() }
            await presentError(title: "Gateway operation failed", message: failure.userMessage)
        case .busy:
            await presentError(
                title: "Gateway is busy",
                message: "Wait for the current Gateway operation to finish, then try again."
            )
        case .needsOnboarding:
            await presentError(
                title: "Setup required",
                message: "Open Tron to complete Mac setup."
            )
        }
    }

    private func confirmAndUninstall() async {
        let alert = NSAlert()
        alert.messageText = "Uninstall Tron Gateway?"
        alert.informativeText = "This removes the Login Item and Mac setup record. Sessions and provider credentials are preserved."
        alert.alertStyle = .warning

        let removeAuthorization = NSButton(
            checkboxWithTitle: "Remove local Gateway authorization",
            target: nil,
            action: nil
        )
        removeAuthorization.toolTip = "Removes gateway/local-auth.json. Sessions, provider credentials, and iPhone enrollment are preserved."
        removeAuthorization.sizeToFit()
        alert.accessoryView = removeAuthorization
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let result = await coordinator.perform(.uninstall(
            removeLocalAuthorization: removeAuthorization.state == .on
        ))
        switch result {
        case .succeeded:
            NSApp.terminate(nil)
        case .failed(let failure):
            await presentError(title: "Uninstall failed", message: failure.userMessage)
        case .busy:
            await presentError(
                title: "Gateway is busy",
                message: "Wait for the current Gateway operation to finish, then try again."
            )
        case .needsOnboarding:
            await presentError(title: "Uninstall failed", message: GatewayLifecycleFailure.serviceFailed.userMessage)
        }
    }

    private func presentError(title: String, message: String) async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }
}

enum MenuBarNotifier {
    static func post(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                return
            }
        }
        guard settings.authorizationStatus != .denied else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: "tron-menu-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
        } catch {
            return
        }
    }
}
