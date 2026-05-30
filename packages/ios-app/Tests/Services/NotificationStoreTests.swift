import Foundation
import Testing
@testable import TronMobile

@MainActor
@Suite("NotificationStore")
struct NotificationStoreTests {

    @Test("markRead uses server unread count and flips only the acknowledged row")
    func markReadUsesServerUnreadCount() async throws {
        let client = StubNotificationStoreClient(
            listResult: NotificationListResult(
                notifications: [
                    Self.notification("notification:a", sessionId: "session-a", isRead: false),
                    Self.notification("notification:b", sessionId: "session-b", isRead: false)
                ],
                unreadCount: 12
            )
        )
        client.markReadResult = NotificationMarkReadResult(success: true, unreadCount: 11)
        let store = NotificationStore(client: client, toastCenter: ToastCenter(clock: MockAsyncClock()))

        await store.refresh()
        let success = await store.markRead(
            eventId: "notification:a",
            idempotencyKey: EngineIdempotencyKey(rawValue: "test-mark-read")
        )

        #expect(success == true)
        #expect(client.markReadCalls.map { $0.eventId } == ["notification:a"])
        #expect(client.markReadCalls.map { $0.sessionId } == ["session-a"])
        #expect(client.markReadCalls.map { $0.idempotencyKey } == [EngineIdempotencyKey(rawValue: "test-mark-read")])
        #expect(store.notifications.first(where: { $0.eventId == "notification:a" })?.isRead == true)
        #expect(store.notifications.first(where: { $0.eventId == "notification:b" })?.isRead == false)
        #expect(store.unreadCount == 11)
        #expect(store.lastActionError == nil)
    }

    @Test("markRead failure does not optimistically mutate local rows")
    func markReadFailureKeepsLocalStateAndSurfacesToast() async throws {
        let toastCenter = ToastCenter(clock: MockAsyncClock())
        let client = StubNotificationStoreClient(
            listResult: NotificationListResult(
                notifications: [Self.notification("notification:a", sessionId: "session-a", isRead: false)],
                unreadCount: 1
            )
        )
        client.markReadError = EngineConnectionError.notConnected
        let store = NotificationStore(client: client, toastCenter: toastCenter)

        await store.refresh()
        client.connectionState = .disconnected
        let success = await store.markRead(
            eventId: "notification:a",
            idempotencyKey: EngineIdempotencyKey(rawValue: "test-mark-read-fail")
        )

        #expect(success == false)
        #expect(store.notifications.first?.isRead == false)
        #expect(store.unreadCount == 1)
        #expect(store.lastActionError == "Could not mark notification read while Tron is disconnected.")
        #expect(toastCenter.toasts.map(\.message) == ["Could not mark notification read while Tron is disconnected."])
    }

    @Test("markAllRead scopes visible row updates and keeps server unread count")
    func markAllReadScopesVisibleRowsAndKeepsServerUnreadCount() async throws {
        var badgeClears = 0
        let client = StubNotificationStoreClient(
            listResult: NotificationListResult(
                notifications: [
                    Self.notification("notification:a1", sessionId: "session-a", isRead: false),
                    Self.notification("notification:a2", sessionId: "session-a", isRead: false),
                    Self.notification("notification:b1", sessionId: "session-b", isRead: false)
                ],
                unreadCount: 8
            )
        )
        client.markAllReadResult = NotificationMarkAllReadResult(marked: 2, unreadCount: 6)
        let store = NotificationStore(
            client: client,
            toastCenter: ToastCenter(clock: MockAsyncClock()),
            badgeClearer: { badgeClears += 1 }
        )

        await store.refresh()
        await store.markAllRead(
            sessionId: "session-a",
            idempotencyKey: EngineIdempotencyKey(rawValue: "test-mark-all-scoped")
        )

        #expect(client.markAllReadCalls.map { $0.sessionId } == ["session-a"])
        #expect(client.markAllReadCalls.map { $0.idempotencyKey } == [EngineIdempotencyKey(rawValue: "test-mark-all-scoped")])
        #expect(store.notifications.filter { $0.sessionId == "session-a" }.allSatisfy { $0.isRead })
        #expect(store.notifications.first(where: { $0.sessionId == "session-b" })?.isRead == false)
        #expect(store.unreadCount == 6)
        #expect(badgeClears == 0)
    }

    @Test("markAllRead clears badge only when server global unread count reaches zero")
    func markAllReadClearsBadgeOnlyAtServerZero() async throws {
        var badgeClears = 0
        let client = StubNotificationStoreClient(
            listResult: NotificationListResult(
                notifications: [
                    Self.notification("notification:a", sessionId: "session-a", isRead: false),
                    Self.notification("notification:b", sessionId: "session-b", isRead: false)
                ],
                unreadCount: 2
            )
        )
        client.markAllReadResult = NotificationMarkAllReadResult(marked: 2, unreadCount: 0)
        let store = NotificationStore(
            client: client,
            toastCenter: ToastCenter(clock: MockAsyncClock()),
            badgeClearer: { badgeClears += 1 }
        )

        await store.refresh()
        await store.markAllRead(idempotencyKey: EngineIdempotencyKey(rawValue: "test-mark-all-global"))

        #expect(store.notifications.allSatisfy { $0.isRead })
        #expect(store.unreadCount == 0)
        #expect(badgeClears == 1)
    }

    private static func notification(
        _ eventId: String,
        sessionId: String,
        isRead: Bool,
        timestamp: String = "2026-05-30T19:00:00Z"
    ) -> NotificationDTO {
        NotificationDTO(
            eventId: eventId,
            sessionId: sessionId,
            invocationId: nil,
            timestamp: timestamp,
            title: "Notification \(eventId)",
            body: "Body",
            sheetContent: nil,
            isRead: isRead,
            readAt: isRead ? timestamp : nil,
            sessionTitle: "Session \(sessionId)",
            isUserSession: true
        )
    }
}

@MainActor
private final class StubNotificationStoreClient: NotificationStoreClient {
    struct MarkReadCall: Equatable {
        let eventId: String
        let sessionId: String?
        let idempotencyKey: EngineIdempotencyKey
    }

    struct MarkAllReadCall: Equatable {
        let sessionId: String?
        let idempotencyKey: EngineIdempotencyKey
    }

    var connectionState: ConnectionState
    var listResult: NotificationListResult
    var markReadResult = NotificationMarkReadResult(success: true, unreadCount: 0)
    var markReadError: Error?
    var markAllReadResult = NotificationMarkAllReadResult(marked: 0, unreadCount: 0)
    var markAllReadError: Error?
    private(set) var markReadCalls: [MarkReadCall] = []
    private(set) var markAllReadCalls: [MarkAllReadCall] = []

    init(
        connectionState: ConnectionState = .connected,
        listResult: NotificationListResult
    ) {
        self.connectionState = connectionState
        self.listResult = listResult
    }

    func listNotifications(limit: Int) async throws -> NotificationListResult {
        listResult
    }

    func markRead(
        eventId: String,
        sessionId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationMarkReadResult {
        markReadCalls.append(.init(eventId: eventId, sessionId: sessionId, idempotencyKey: idempotencyKey))
        if let markReadError { throw markReadError }
        return markReadResult
    }

    func markAllRead(
        sessionId: String?,
        idempotencyKey: EngineIdempotencyKey
    ) async throws -> NotificationMarkAllReadResult {
        markAllReadCalls.append(.init(sessionId: sessionId, idempotencyKey: idempotencyKey))
        if let markAllReadError { throw markAllReadError }
        return markAllReadResult
    }
}
