import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MiscClient Tests")
struct MiscClientTests {

    @Test("getSystemInfo throws when webSocket is nil")
    func getSystemInfoNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MiscClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.getSystemInfo()
        }
    }
}
