import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("SettingsClient Tests")
struct SettingsClientTests {

    @Test("get throws when transport is nil")
    func getNoTransport() async {
        let client: SettingsClient = {
            let transport = MockRPCTransport()
            return SettingsClient(transport: transport)
        }()

        await #expect(throws: RPCClientError.self) {
            _ = try await client.get()
        }
    }

    @Test("get throws when webSocket is nil")
    func getNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SettingsClient(transport: transport)

        await #expect(throws: RPCClientError.self) {
            _ = try await client.get()
        }
    }

    @Test("update throws when transport is nil")
    func updateNoTransport() async {
        let client: SettingsClient = {
            let transport = MockRPCTransport()
            return SettingsClient(transport: transport)
        }()

        let update = ServerSettingsUpdate()

        await #expect(throws: RPCClientError.self) {
            try await client.update(update)
        }
    }

    @Test("update throws when webSocket is nil")
    func updateNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = SettingsClient(transport: transport)

        let update = ServerSettingsUpdate()

        await #expect(throws: RPCClientError.self) {
            try await client.update(update)
        }
    }
}
