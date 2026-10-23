import Foundation
@preconcurrency import UserNotifications

/// Disposable native delivery cut, not canonical inbox/read state. Removing only
/// captured IDs (and deliveries preceding visibility) leaves later pushes alone.
@MainActor
struct DeliveredNotificationRead {
    private struct Delivery {
        let identifier: String
        let sessionID: String
    }
    private let deliveries: [Delivery]

    static func capture(machineID: String, before visibility: Date) async -> Self {
        let notifications = await UNUserNotificationCenter.current().deliveredNotifications()
        return Self(deliveries: notifications.compactMap { notification in
            guard notification.date <= visibility,
                  let route = PushNotificationTap.admit(notification.request.content.userInfo).route,
                  route.machineID == machineID else { return nil }
            return Delivery(identifier: notification.request.identifier, sessionID: route.sessionID)
        })
    }

    func hasOtherSessions(than sessionID: String) -> Bool {
        deliveries.contains { $0.sessionID != sessionID }
    }

    func remove(sessionIDs: Set<String>) async {
        let identifiers = deliveries.filter { sessionIDs.contains($0.sessionID) }.map(\.identifier)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        await RetiredNotificationBadge.clear()
    }
}
