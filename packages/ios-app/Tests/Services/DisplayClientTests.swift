import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("DisplayClient Tests")
struct DisplayClientTests {

    @Test("stopStream throws when engineConnection is nil")
    func stopStreamNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = DisplayClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.stopStream(streamId: "stream-1", idempotencyKey: .userAction("display.stopStream.test"))
        }
    }
}
