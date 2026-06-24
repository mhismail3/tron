import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("EventSyncClient Tests")
struct EventSyncClientTests {

    @Test("getHistory throws when engineConnection is nil")
    func getHistoryNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = EventSyncClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getHistory(sessionId: "test-session")
        }
    }
}
