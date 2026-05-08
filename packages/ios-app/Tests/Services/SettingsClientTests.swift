import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SettingsClient Tests")
struct SettingsClientTests {

    @Test("get throws when engineConnection is nil")
    func getNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SettingsClient(transport: transport)

        await #expect(throws: EngineClientError.self) {
            _ = try await client.get()
        }
    }

    @Test("update throws when engineConnection is nil")
    func updateNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = SettingsClient(transport: transport)

        let update = ServerSettingsUpdate()

        await #expect(throws: EngineClientError.self) {
            try await client.update(update, idempotencyKey: .userAction("settings.update.test"))
        }
    }

}
