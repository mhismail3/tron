import CryptoKit
import UIKit
import UserNotifications

/// Process-level UIKit/UNUserNotificationCenter bridge. AppDelegate installs
/// this delegate before launch completion; the production dependency graph
/// attaches the coordinator later. Hosted tests never install or attach it.
@MainActor
final class NotificationLifecycleBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationLifecycleBridge()

    static let snoozeActionIdentifier = "TRON_REMINDER_SNOOZE"
    static let completeActionIdentifier = "TRON_REMINDER_COMPLETE"

    private weak var coordinator: NativeNotificationCoordinator?
    private var pendingResponses: [PendingResponse] = []

    private struct PendingResponse {
        let serverId: String
        let deliveryId: String
        let acknowledgement: NotificationAcknowledgement
        let continuation: CheckedContinuation<Void, Never>
    }

    func install() {
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionIdentifier,
            title: "Snooze",
            options: []
        )
        let complete = UNNotificationAction(
            identifier: Self.completeActionIdentifier,
            title: "Complete",
            options: []
        )
        let reminder = UNNotificationCategory(
            identifier: "TRON_REMINDER",
            actions: [snooze, complete],
            intentIdentifiers: [],
            options: []
        )
        let notification = UNNotificationCategory(
            identifier: "TRON_NOTIFICATION",
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([reminder, notification])
        center.delegate = self
    }

    func attach(_ coordinator: NativeNotificationCoordinator) {
        self.coordinator = coordinator
        guard !pendingResponses.isEmpty else { return }
        let responses = pendingResponses
        pendingResponses.removeAll()
        Task { @MainActor in
            for response in responses {
                await coordinator.handleNotificationResponse(
                    serverId: response.serverId,
                    deliveryId: response.deliveryId,
                    acknowledgement: response.acknowledgement
                )
                response.continuation.resume()
            }
        }
    }

    func didRegisterForRemoteNotifications(token: Data) {
        coordinator?.didReceiveDeviceToken(token)
    }

    func didFailToRegisterForRemoteNotifications(_ error: Error) {
        coordinator?.didFailRemoteRegistration(error)
    }

    func handleQuietRefresh(
        _ userInfo: [AnyHashable: Any],
        completion: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard Self.payloadKind(userInfo) == "notification_state_refresh",
              let coordinator
        else {
            completion(.noData)
            return
        }
        logger.info(
            "Received quiet notification refresh route=\(Self.evidenceRoute(userInfo))",
            category: .notification
        )
        Task {
            let changed = await coordinator.handleQuietRefresh(userInfo)
            completion(changed ? .newData : .noData)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let route = Self.evidenceRoute(notification.request.content.userInfo)
        logger.info(
            "Presenting foreground notification route=\(route)",
            category: .notification
        )
        return [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let acknowledgement: NotificationAcknowledgement
        switch response.actionIdentifier {
        case Self.snoozeActionIdentifier:
            acknowledgement = .snooze
        case Self.completeActionIdentifier:
            acknowledgement = .complete
        case UNNotificationDefaultActionIdentifier:
            acknowledgement = .opened
        default:
            // System dismissal and unsupported category actions do not mutate
            // the logical reminder occurrence.
            return
        }
        let payload = response.notification.request.content.userInfo
        guard let tron = payload["tron"] as? [String: Any],
              let serverId = tron["serverId"] as? String,
              let deliveryId = tron["deliveryId"] as? String
        else { return }
        logger.info(
            "Handling notification response action=\(acknowledgement.rawValue) route=\(Self.evidenceRoute(payload))",
            category: .notification
        )
        await admitNotificationResponse(
            serverId: serverId,
            deliveryId: deliveryId,
            acknowledgement: acknowledgement
        )
    }

    /// Keep the system response callback alive until the process-local
    /// coordinator has durably admitted the action. Cold launches may deliver
    /// the callback before dependency composition attaches the coordinator.
    func admitNotificationResponse(
        serverId: String,
        deliveryId: String,
        acknowledgement: NotificationAcknowledgement
    ) async {
        if let coordinator {
            await coordinator.handleNotificationResponse(
                serverId: serverId,
                deliveryId: deliveryId,
                acknowledgement: acknowledgement
            )
            return
        }
        await withCheckedContinuation { continuation in
            pendingResponses.append(
                PendingResponse(
                    serverId: serverId,
                    deliveryId: deliveryId,
                    acknowledgement: acknowledgement,
                    continuation: continuation
                )
            )
        }
    }

    static func payloadKind(_ payload: [AnyHashable: Any]) -> String? {
        (payload["tron"] as? [String: Any])?["kind"] as? String
    }

    /// Sanitized route evidence distinguishes APNs arrival/presentation from
    /// provider-only acceptance without retaining notification text, tokens,
    /// or raw identifiers.
    nonisolated static func evidenceRoute(_ payload: [AnyHashable: Any]) -> String {
        guard let tron = payload["tron"] as? [String: Any],
              let serverId = tron["serverId"] as? String,
              let deliveryId = tron["deliveryId"] as? String else {
            return "unavailable"
        }
        let digest = SHA256.hash(
            data: Data("\(serverId)\u{1f}\(deliveryId)".utf8)
        )
        return digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }
}
