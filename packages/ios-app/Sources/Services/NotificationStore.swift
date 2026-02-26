import Foundation

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

    private let rpcClient: RPCClient

    init(rpcClient: RPCClient) {
        self.rpcClient = rpcClient
    }

    /// Refresh the notification list from the server.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await rpcClient.notifications.listNotifications()
            notifications = result.notifications
            unreadCount = result.unreadCount
        } catch {
            TronLogger.shared.warning("Failed to refresh notifications: \(error)", category: .notification)
        }
    }

    /// Mark a single notification as read.
    /// Returns `true` if the server acknowledged the mark-read.
    @discardableResult
    func markRead(eventId: String) async -> Bool {
        do {
            _ = try await rpcClient.notifications.markRead(eventId: eventId)
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

    /// Mark all notifications as read.
    func markAllRead() async {
        do {
            _ = try await rpcClient.notifications.markAllRead()
            // Update local state
            let now = DateParser.toISO8601(Date())
            notifications = notifications.map { n in
                guard !n.isRead else { return n }
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
            unreadCount = 0
        } catch {
            TronLogger.shared.warning("Failed to mark all notifications as read: \(error)", category: .notification)
        }
    }
}
