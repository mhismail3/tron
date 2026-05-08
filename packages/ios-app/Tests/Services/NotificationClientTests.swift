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
}
