import Foundation
import UserNotifications

/// Observable store for the notification inbox.
///
/// Maintains the list of recent notifications and unread count.
/// Refreshes on WebSocket connect and on dashboard `.task {}`.
@Observable
@MainActor
final class NotificationStore {
    private(set) var notifications: [NotificationDTO] = []
    private(set) var unreadCount: Int = 0
    private(set) var isLoading = false

    private let engineClient: EngineClient

    init(engineClient: EngineClient) {
        self.engineClient = engineClient
    }

    /// Refresh the notification list from the server.
    func refresh() async {
        guard Self.shouldRefreshFromServer(connectionState: engineClient.connectionState) else {
            TronLogger.shared.debug("Skipping notification refresh until the engine connection is established", category: .notification)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await engineClient.notifications.listNotifications()
            notifications = result.notifications
            unreadCount = result.unreadCount
        } catch {
            TronLogger.shared.warning("Failed to refresh notifications: \(error)", category: .notification)
        }
    }

    /// Mark a single notification as read.
    /// Returns `true` if the server acknowledged the mark-read.
    @discardableResult
    func markRead(eventId: String, idempotencyKey: EngineIdempotencyKey) async -> Bool {
        do {
            _ = try await engineClient.notifications.markRead(eventId: eventId, idempotencyKey: idempotencyKey)
            // Update local state only on success
            if let index = notifications.firstIndex(where: { $0.eventId == eventId }) {
                let n = notifications[index]
                if !n.isRead {
                    notifications[index] = NotificationDTO(
                        eventId: n.eventId,
                        sessionId: n.sessionId,
                        toolCallId: n.toolCallId,
                        timestamp: n.timestamp,
                        title: n.title,
                        body: n.body,
                        sheetContent: n.sheetContent,
                        isRead: true,
                        readAt: DateParser.toISO8601(Date()),
                        sessionTitle: n.sessionTitle,
                        isUserSession: n.isUserSession
                    )
                    unreadCount = max(0, unreadCount - 1)
                }
            }
            return true
        } catch {
            TronLogger.shared.warning("Failed to mark notification as read: \(error)", category: .notification)
            return false
        }
    }

    /// Mark notifications as read and update local state.
    ///
    /// Pass `sessionId` to scope the operation to a single session —
    /// used by the session-open flow so that opening one session from
    /// the sidebar doesn't silently clear unread badges for others.
    /// Pass `nil` (default) to mark every session's notifications read.
    ///
    /// The app badge is cleared only when the operation is unscoped
    /// AND the local unread count reaches zero — a scoped clear can
    /// leave notifications in other sessions unread, and the badge
    /// should reflect the total.
    func markAllRead(
        sessionId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async {
        do {
            _ = try await engineClient.notifications.markAllRead(sessionId: sessionId, idempotencyKey: idempotencyKey)
            // Update local state — only flip `isRead` for rows matching
            // the scope (or all rows when unscoped).
            let now = DateParser.toISO8601(Date())
            notifications = notifications.map { n in
                guard !n.isRead else { return n }
                if let sessionId, n.sessionId != sessionId { return n }
                return NotificationDTO(
                    eventId: n.eventId,
                    sessionId: n.sessionId,
                    toolCallId: n.toolCallId,
                    timestamp: n.timestamp,
                    title: n.title,
                    body: n.body,
                    sheetContent: n.sheetContent,
                    isRead: true,
                    readAt: now,
                    sessionTitle: n.sessionTitle,
                    isUserSession: n.isUserSession
                )
            }
            unreadCount = notifications.reduce(0) { $0 + ($1.isRead ? 0 : 1) }
            if unreadCount == 0 {
                await clearBadge()
            }
        } catch {
            TronLogger.shared.warning("Failed to mark all notifications as read: \(error)", category: .notification)
        }
    }

    static func shouldRefreshFromServer(connectionState: ConnectionState) -> Bool {
        connectionState.isConnected
    }

    /// Clear the app badge count after server confirms no unread notifications.
    func clearBadge() async {
        do {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
        } catch {
            TronLogger.shared.debug("Failed to clear badge: \(error)", category: .notification)
        }
    }
}
