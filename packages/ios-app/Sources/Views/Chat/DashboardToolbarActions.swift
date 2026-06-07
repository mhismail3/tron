import Foundation

/// Bundles common toolbar callbacks shared by the primitive session shell.
struct DashboardToolbarActions {
    let onSettings: () -> Void
    let notificationUnreadCount: Int
    let onNotificationBell: () -> Void
}
