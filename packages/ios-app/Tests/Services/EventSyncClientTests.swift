import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("EventSyncClient Tests")
struct EventSyncClientTests {

    @Test("getHistory throws when transport is nil")
    func getHistoryNoTransport() async {
        let client: EventSyncClient = {
            let transport = MockRPCTransport()
            return EventSyncClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getHistory(sessionId: "test-session")
        }
    }

    @Test("getHistory throws when webSocket is nil")
    func getHistoryNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = EventSyncClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getHistory(sessionId: "test-session")
        }
    }

    @Test("getSince throws when transport is nil")
    func getSinceNoTransport() async {
        let client: EventSyncClient = {
            let transport = MockRPCTransport()
            return EventSyncClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getSince(sessionId: "test-session")
        }
    }

    @Test("getAll throws when transport is nil")
    func getAllNoTransport() async {
        let client: EventSyncClient = {
            let transport = MockRPCTransport()
            return EventSyncClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getAll(sessionId: "test-session")
        }
    }

    @Test("getAncestors throws when transport is nil")
    func getAncestorsNoTransport() async {
        let client: EventSyncClient = {
            let transport = MockRPCTransport()
            return EventSyncClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getAncestors("evt-123")
        }
    }
}
