import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("ContextClient Tests")
struct ContextClientTests {

    @Test("getSnapshot throws when webSocket is nil")
    func getSnapshotNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = ContextClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getSnapshot(sessionId: "test-session")
        }
    }
}
