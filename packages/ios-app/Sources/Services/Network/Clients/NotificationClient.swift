import Foundation

/// Client for notification inbox RPC methods.
@MainActor
final class NotificationClient {
    private unowned let transport: RPCTransport

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// List recent notifications with read state.
    func listNotifications(limit: Int = 50) async throws -> NotificationListResult {
        let ws = try transport.requireConnection()
        let params = NotificationListParams(limit: limit)
        return try await ws.send(method: "notifications.list", params: params)
    }

    /// Mark a single notification as read.
    func markRead(eventId: String) async throws -> NotificationMarkReadResult {
        let ws = try transport.requireConnection()
        let params = NotificationMarkReadParams(eventId: eventId)
        return try await ws.send(method: "notifications.markRead", params: params)
    }

    /// Mark all unread notifications as read.
    func markAllRead() async throws -> NotificationMarkAllReadResult {
        let ws = try transport.requireConnection()
        return try await ws.send(method: "notifications.markAllRead", params: EmptyParams())
    }
}

// MARK: - Request DTOs

private struct NotificationListParams: Encodable {
    let limit: Int
}

private struct NotificationMarkReadParams: Encodable {
    let eventId: String
}

// MARK: - Response DTOs

struct NotificationDTO: Codable, Identifiable {
    let eventId: String
    let sessionId: String
    let toolCallId: String?
    let timestamp: String
    let title: String
    let body: String
    let sheetContent: String?
    let isRead: Bool
    let readAt: String?
    let sessionTitle: String?
    let isUserSession: Bool

    var id: String { eventId }
}

struct NotificationListResult: Codable {
    let notifications: [NotificationDTO]
    let unreadCount: Int
}

struct NotificationMarkReadResult: Codable {
    let success: Bool
}

struct NotificationMarkAllReadResult: Codable {
    let marked: Int
}
