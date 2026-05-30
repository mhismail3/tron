import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("NotificationClient Tests")
struct NotificationClientTests {

    @Test("listNotifications throws when engineConnection is nil")
    func listNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = NotificationClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.listNotifications(limit: 20) }
    }

    @Test("markRead throws when engineConnection is nil")
    func markReadNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = NotificationClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.markRead(eventId: "evt-1", idempotencyKey: .userAction("notifications.markRead.test"))
        }
    }

    @Test("markAllRead throws when engineConnection is nil")
    func markAllReadNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = NotificationClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.markAllRead(idempotencyKey: .userAction("notifications.markAllRead.test"))
        }
    }

    @Test("markRead invokes notifications mark_read with idempotency")
    func markReadInvokesCapabilityWithIdempotency() async throws {
        let transport = connectedTransport()
        let client = NotificationClient(transport: transport)
        let idempotencyKey = EngineIdempotencyKey(rawValue: "test-mark-read")
        transport.writeHandler = { functionId, payload, key, options in
            #expect(functionId.rawValue == "notifications::mark_read")
            #expect(key == idempotencyKey)
            #expect(options.context?.sessionId == "session-a")
            let fields = Dictionary(
                uniqueKeysWithValues: Mirror(reflecting: payload).children.compactMap { child in
                    child.label.map { ($0, child.value) }
                }
            )
            #expect(fields["eventId"] as? String == "notification:a")
            #expect(fields["sessionId"] as? String == "session-a")
            return NotificationMarkReadResult(success: true, unreadCount: 4)
        }

        let result = try await client.markRead(
            eventId: "notification:a",
            sessionId: "session-a",
            idempotencyKey: idempotencyKey
        )

        #expect(result.success == true)
        #expect(result.unreadCount == 4)
    }

    @Test("scoped markAllRead invokes notifications mark_all_read with session context")
    func scopedMarkAllReadInvokesCapabilityWithSessionContext() async throws {
        let transport = connectedTransport()
        let client = NotificationClient(transport: transport)
        let idempotencyKey = EngineIdempotencyKey(rawValue: "test-mark-all-scoped")
        transport.writeHandler = { functionId, payload, key, options in
            #expect(functionId.rawValue == "notifications::mark_all_read")
            #expect(key == idempotencyKey)
            #expect(options.context?.sessionId == "session-a")
            let fields = Dictionary(
                uniqueKeysWithValues: Mirror(reflecting: payload).children.compactMap { child in
                    child.label.map { ($0, child.value) }
                }
            )
            #expect(fields["sessionId"] as? String == "session-a")
            return NotificationMarkAllReadResult(marked: 2, unreadCount: 5)
        }

        let result = try await client.markAllRead(
            sessionId: "session-a",
            idempotencyKey: idempotencyKey
        )

        #expect(result.marked == 2)
        #expect(result.unreadCount == 5)
    }

    private func connectedTransport() -> MockEngineTransport {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        transport.connectionState = .connected
        return transport
    }
}
