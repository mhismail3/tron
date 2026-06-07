import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MiscClient Tests")
struct MiscClientTests {

    @Test("getSystemInfo throws when engineConnection is nil")
    func getSystemInfoNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MiscClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getSystemInfo()
        }
    }

}
