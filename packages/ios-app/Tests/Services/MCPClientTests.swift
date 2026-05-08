import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MCPClient Tests")
struct MCPClientTests {

    @Test("status throws when engineConnection is nil")
    func statusNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.status() }
    }

    @Test("addServer throws when engineConnection is nil")
    func addServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.addServer(
                MCPAddServerParams(name: "test", command: "echo", args: nil, env: nil, url: nil, enabled: true),
                idempotencyKey: .userAction("mcp.addServer.test")
            )
        }
    }

    @Test("removeServer throws when engineConnection is nil")
    func removeServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.removeServer(name: "test", idempotencyKey: .userAction("mcp.removeServer.test"))
        }
    }

    @Test("enableServer throws when engineConnection is nil")
    func enableServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.enableServer(name: "test", idempotencyKey: .userAction("mcp.enableServer.test"))
        }
    }

    @Test("disableServer throws when engineConnection is nil")
    func disableServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            try await client.disableServer(name: "test", idempotencyKey: .userAction("mcp.disableServer.test"))
        }
    }

    @Test("restartServer throws when engineConnection is nil")
    func restartServerNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.restartServer(name: "test", idempotencyKey: .userAction("mcp.restartServer.test"))
        }
    }

    @Test("listTools throws when engineConnection is nil")
    func listToolsNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) { _ = try await client.listTools(server: nil) }
    }

    @Test("reload throws when engineConnection is nil")
    func reloadNoConnection() async {
        let transport = MockEngineTransport()
        transport.engineConnection = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: EngineClientError.self) {
            _ = try await client.reload(idempotencyKey: .userAction("mcp.reload.test"))
        }
    }
}
