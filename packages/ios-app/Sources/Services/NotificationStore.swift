import Foundation
import UserNotifications

@MainActor
protocol NotificationStoreClient: AnyObject {
    var connectionState: ConnectionState { get }

    func listNotifications(limit: Int) async throws -> NotificationListResult
    func markRead(
        eventId: String,
        sessionId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationMarkReadResult
    func markAllRead(sessionId: String?, idempotencyKey: EngineIdempotencyKey) async throws -> NotificationMarkAllReadResult
}

@MainActor
private final class EngineNotificationStoreClient: NotificationStoreClient {
    private let engineClient: EngineClient

    init(engineClient: EngineClient) {
        self.engineClient = engineClient
    }

    var connectionState: ConnectionState {
        engineClient.connectionState
    }

    func listNotifications(limit: Int) async throws -> NotificationListResult {
        try await engineClient.notifications.listNotifications(limit: limit)
    }

    func markRead(
        eventId: String,
        sessionId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationMarkReadResult {
        try await engineClient.notifications.markRead(
            eventId: eventId,
            sessionId: sessionId,
            idempotencyKey: idempotencyKey
        )
    }

    func markAllRead(
        sessionId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationMarkAllReadResult {
        try await engineClient.notifications.markAllRead(sessionId: sessionId, idempotencyKey: idempotencyKey)
    }
}

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
    private(set) var lastActionError: String?

    @ObservationIgnored
    private let client: NotificationStoreClient
    @ObservationIgnored
    private let toastCenter: ToastCenter
    @ObservationIgnored
    private let badgeClearer: () async throws -> Void

    init(engineClient: EngineClient) {
        self.client = EngineNotificationStoreClient(engineClient: engineClient)
        self.toastCenter = .shared
        self.badgeClearer = {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }

    init(
        client: NotificationStoreClient,
        toastCenter: ToastCenter = .shared,
        badgeClearer: @escaping () async throws -> Void = {
            try await UNUserNotificationCenter.current().setBadgeCount(0)
        }
    ) {
        self.client = client
        self.toastCenter = toastCenter
        self.badgeClearer = badgeClearer
    }

    /// Refresh the notification list from the server.
    func refresh() async {
        guard Self.shouldRefreshFromServer(connectionState: client.connectionState) else {
            TronLogger.shared.debug("Skipping notification refresh until the engine connection is established", category: .notification)
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await client.listNotifications(limit: 50)
            notifications = result.notifications
            unreadCount = result.unreadCount
        } catch {
            TronLogger.shared.warning("Failed to refresh notifications: \(error)", category: .notification)
        }
    }

    /// Mark a single notification as read.
    /// Returns `true` if the server acknowledged the mark-read.
    @discardableResult
    func markRead(
        eventId: String,
        sessionId: String? = nil,
        idempotencyKey: EngineIdempotencyKey
    ) async -> Bool {
        let scopedSessionId = sessionId ?? notifications.first(where: { $0.eventId == eventId })?.sessionId
        do {
            let result = try await client.markRead(
                eventId: eventId,
                sessionId: scopedSessionId,
                idempotencyKey: idempotencyKey
            )
            guard result.success else {
                presentActionFailure("Could not mark notification read.")
                return false
            }
            // Update local state only on success
            if let index = notifications.firstIndex(where: { $0.eventId == eventId }) {
                let n = notifications[index]
                if !n.isRead {
                    notifications[index] = NotificationDTO(
                        eventId: n.eventId,
                        sessionId: n.sessionId,
                        invocationId: n.invocationId,
                        timestamp: n.timestamp,
                        title: n.title,
                        body: n.body,
                        sheetContent: n.sheetContent,
                        isRead: true,
                        readAt: DateParser.toISO8601(Date()),
                        sessionTitle: n.sessionTitle,
                        isUserSession: n.isUserSession
                    )
                }
            }
            unreadCount = result.unreadCount
            lastActionError = nil
            if unreadCount == 0 {
                await clearBadge()
            }
            return true
        } catch {
            TronLogger.shared.warning("Failed to mark notification as read: \(error)", category: .notification)
            presentActionFailure(actionFailureMessage("Could not mark notification read"))
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
        guard Self.shouldRefreshFromServer(connectionState: client.connectionState) else {
            TronLogger.shared.debug("Skipping mark-all-read until the engine connection is established", category: .notification)
            presentActionFailure(actionFailureMessage("Could not mark notifications read"))
            return
        }

        do {
            let result = try await client.markAllRead(sessionId: sessionId, idempotencyKey: idempotencyKey)
            // Update local state — only flip `isRead` for rows matching
            // the scope (or all rows when unscoped).
            let now = DateParser.toISO8601(Date())
            notifications = notifications.map { n in
                guard !n.isRead else { return n }
                if let sessionId, n.sessionId != sessionId { return n }
                return NotificationDTO(
                    eventId: n.eventId,
                    sessionId: n.sessionId,
                    invocationId: n.invocationId,
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
            unreadCount = result.unreadCount
            lastActionError = nil
            if unreadCount == 0 {
                await clearBadge()
            }
        } catch {
            TronLogger.shared.warning("Failed to mark all notifications as read: \(error)", category: .notification)
            presentActionFailure(actionFailureMessage("Could not mark notifications read"))
        }
    }

    static func shouldRefreshFromServer(connectionState: ConnectionState) -> Bool {
        connectionState.isConnected
    }

    /// Clear the app badge count after server confirms no unread notifications.
    func clearBadge() async {
        do {
            try await badgeClearer()
        } catch {
            TronLogger.shared.debug("Failed to clear badge: \(error)", category: .notification)
        }
    }

    private func actionFailureMessage(_ prefix: String) -> String {
        if !client.connectionState.isConnected {
            return "\(prefix) while Tron is disconnected."
        }
        return "\(prefix)."
    }

    private func presentActionFailure(_ message: String) {
        lastActionError = message
        toastCenter.push(message, severity: .error, dedupKey: "notification-read-action")
    }
}
