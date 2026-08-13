import UserNotifications

/// Clears badge state left behind by Tron's retired APNs implementation.
///
/// Current Tron builds do not register for notifications or derive a badge from
/// session state. SpringBoard can nevertheless retain the previous badge for the
/// production bundle identifier across an app replacement or reinstall.
enum RetiredNotificationBadge {
    @MainActor
    static func clear(
        setBadgeCount: @escaping @MainActor (Int) async throws -> Void = { count in
            try await UNUserNotificationCenter.current().setBadgeCount(count)
        }
    ) async {
        try? await setBadgeCount(0)
    }
}
