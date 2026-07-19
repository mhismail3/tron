import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("ModelClient Tests")
struct ModelClientTests {

    @Test("switchModel throws when engineConnection is nil")
    func switchModelNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = ModelClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.switchModel(
                "test-session",
                model: "claude-sonnet-4-20250514",
                idempotencyKey: .userAction("model.switch.test")
            )
        }
    }

    @Test("list throws when engineConnection is nil")
    func listNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = ModelClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.list()
        }
    }

}
