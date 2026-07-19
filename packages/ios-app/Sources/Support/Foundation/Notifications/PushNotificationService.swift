import UserNotifications
import UIKit

@Observable
@MainActor
final class PushNotificationService {
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var deviceToken: String?
    private(set) var registrationError: String?

    init(notificationCenter: NotificationCenter = .default) {
        notificationCenter.addObserver(
            forName: .deviceTokenDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let token = notification.userInfo?["token"] as? String else { return }
            MainActor.assumeIsolated {
                self?.deviceToken = token
                self?.registrationError = nil
            }
        }
        notificationCenter.addObserver(
            forName: .deviceTokenRegistrationFailed,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.userInfo?["error"] as? Error)?.localizedDescription
                ?? "APNs registration failed"
            MainActor.assumeIsolated {
                self?.registrationError = message
            }
        }
    }

    func registerAfterPairing() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        TronLogger.shared.info(
            "Notification authorization status: \(settings.authorizationStatus.tronLabel)",
            category: .notification
        )
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            do {
                let granted = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                authorizationStatus = granted ? .authorized : .denied
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            } catch {
                registrationError = error.localizedDescription
                TronLogger.shared.error(
                    "Notification authorization failed: \(error.localizedDescription)",
                    category: .notification
                )
            }
        case .denied:
            registrationError = "Notifications are disabled in iOS Settings"
            TronLogger.shared.warning(
                "APNs registration skipped because notifications are disabled in iOS Settings",
                category: .notification
            )
        @unknown default:
            registrationError = "Notification authorization status is unsupported"
            TronLogger.shared.warning(
                "APNs registration skipped because notification authorization is unsupported",
                category: .notification
            )
        }
    }
}

private extension UNAuthorizationStatus {
    var tronLabel: String {
        switch self {
        case .notDetermined: "not_determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }
}
