import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("EventSyncClient Tests")
struct EventSyncClientTests {

    @Test("getHistory throws when webSocket is nil")
    func getHistoryNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = EventSyncClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getHistory(sessionId: "test-session")
        }
    }
}
