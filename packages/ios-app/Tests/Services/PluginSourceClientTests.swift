import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("PluginSourceClient Tests")
struct PluginSourceClientTests {

    @Test("status throws when engineConnection is nil")
    func statusNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.status() }
    }

    @Test("addServer throws when engineConnection is nil")
    func addServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.addServer(
                PluginSourceAddParams(name: "test", command: "echo", args: nil, env: nil, url: nil, enabled: true),
                idempotencyKey: .userAction("pluginSources.addServer.test")
            )
        }
    }

    @Test("removeServer throws when engineConnection is nil")
    func removeServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.removeServer(name: "test", idempotencyKey: .userAction("pluginSources.removeServer.test"))
        }
    }

    @Test("enableServer throws when engineConnection is nil")
    func enableServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.enableServer(name: "test", idempotencyKey: .userAction("pluginSources.enableServer.test"))
        }
    }

    @Test("disableServer throws when engineConnection is nil")
    func disableServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.disableServer(name: "test", idempotencyKey: .userAction("pluginSources.disableServer.test"))
        }
    }

    @Test("restartServer throws when engineConnection is nil")
    func restartServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.restartServer(name: "test", idempotencyKey: .userAction("pluginSources.restartServer.test"))
        }
    }

    @Test("listCapabilities throws when engineConnection is nil")
    func listCapabilitiesNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.listCapabilities(server: nil) }
    }

    @Test("reload throws when engineConnection is nil")
    func reloadNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = PluginSourceClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.reload(idempotencyKey: .userAction("pluginSources.reload.test"))
        }
    }
}
