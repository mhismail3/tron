import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("NotificationClient Tests")
struct NotificationClientTests {

    @Test("listNotifications throws when webSocket is nil")
    func listNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = NotificationClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.listNotifications(limit: 20) }
    }

    @Test("markRead throws when webSocket is nil")
    func markReadNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = NotificationClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.markRead(eventId: "evt-1") }
    }

    @Test("markAllRead throws when webSocket is nil")
    func markAllReadNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = NotificationClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.markAllRead() }
    }
}
