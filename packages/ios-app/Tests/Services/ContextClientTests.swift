import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("ContextClient Tests")
struct ContextClientTests {

    @Test("getSnapshot throws when engineConnection is nil")
    func getSnapshotNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = ContextClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getSnapshot(sessionId: "test-session")
        }
    }
}
