import Foundation

/// Bundles the 4 common toolbar callback parameters passed from ContentView to every dashboard view.
struct DashboardToolbarActions {
    let onSettings: () -> Void
    let onNavigationModeChange: (NavigationMode) -> Void
    let notificationUnreadCount: Int
    let onNotificationBell: () -> Void
}
