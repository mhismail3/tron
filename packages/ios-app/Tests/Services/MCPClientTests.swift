import Testing
import Foundation
@testable import TronMobile

@MainActor
@Suite("MCPClient Tests")
struct MCPClientTests {

    @Test("status throws when webSocket is nil")
    func statusNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.status() }
    }

    @Test("addServer throws when webSocket is nil")
    func addServerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.addServer(MCPAddServerParams(name: "test", command: "echo", args: nil, env: nil, url: nil, enabled: true)) }
    }

    @Test("removeServer throws when webSocket is nil")
    func removeServerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.removeServer(name: "test") }
    }

    @Test("enableServer throws when webSocket is nil")
    func enableServerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.enableServer(name: "test") }
    }

    @Test("disableServer throws when webSocket is nil")
    func disableServerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { try await client.disableServer(name: "test") }
    }

    @Test("restartServer throws when webSocket is nil")
    func restartServerNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.restartServer(name: "test") }
    }

    @Test("listTools throws when webSocket is nil")
    func listToolsNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.listTools(server: nil) }
    }

    @Test("reload throws when webSocket is nil")
    func reloadNoConnection() async {
        let transport = MockRPCTransport()
        transport.webSocket = nil
        let client = MCPClient(transport: transport)
        await #expect(throws: RPCClientError.self) { _ = try await client.reload() }
    }
}
