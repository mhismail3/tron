import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("DisplayClient Tests")
struct DisplayClientTests {

    @Test("stopStream throws when webSocket is nil")
    func stopStreamNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = DisplayClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.stopStream(streamId: "stream-1") }
    }
}
