import UserNotifications

/// Clears badge state left behind by Tron's retired inbox implementation.
///
/// Current builds support narrow alert notifications but deliberately carry no
/// badge or unread-state contract. SpringBoard can nevertheless retain an older
/// badge under the unchanged production bundle identifier.
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
