import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SystemClient Tests")
struct SystemClientTests {

    @Test("getSystemInfo throws when engineConnection is nil")
    func getSystemInfoNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SystemClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.getSystemInfo()
        }
    }

    @Test("ping invokes system ping")
    func pingInvokesSystemPing() async throws {
        let transport = MockEngineTransport()
        transport.engineConnection = EngineConnection(serverURL: URL(string: "ws://127.0.0.1:9847/engine")!)
        let client = SystemClient(transport: transport)

        transport.readHandler = { functionId, payload, _ in
            #expect(functionId.rawValue == "system::ping")
            #expect((payload as? SystemPingParams)?.protocolVersion == 1)
            return SystemPingResult(pong: true)
        }

        try await client.ping()
        #expect(transport.lastReadFunctionId?.rawValue == "system::ping")
    }

}
