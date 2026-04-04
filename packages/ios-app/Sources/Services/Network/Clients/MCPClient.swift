import Foundation

/// Client for mcp.* RPC methods.
/// Manages MCP server lifecycle: status, add, remove, enable, disable, restart, reload.
@MainActor
final class MCPClient {
    private weak var transport: (any RPCTransport)?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Access transport safely, throwing if deallocated during server change.
    private func requireTransport() throws -> any RPCTransport {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        return transport
    }

    // MARK: - Status

    func status() async throws -> [MCPServerStatus] {
        let ws = try requireTransport().requireConnection()
        let result: [MCPServerStatus] = try await ws.send(
            method: "mcp.status",
            params: EmptyParams()
        )
        return result
    }

    // MARK: - Server Management

    func addServer(_ params: MCPAddServerParams) async throws -> MCPAddServerResult {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "mcp.addServer",
            params: params
        )
    }

    func removeServer(name: String) async throws {
        let ws = try requireTransport().requireConnection()
        let _: MCPSuccessResult = try await ws.send(
            method: "mcp.removeServer",
            params: MCPServerNameParams(name: name)
        )
    }

    func enableServer(name: String) async throws {
        let ws = try requireTransport().requireConnection()
        let _: MCPSuccessResult = try await ws.send(
            method: "mcp.enableServer",
            params: MCPServerNameParams(name: name)
        )
    }

    func disableServer(name: String) async throws {
        let ws = try requireTransport().requireConnection()
        let _: MCPSuccessResult = try await ws.send(
            method: "mcp.disableServer",
            params: MCPServerNameParams(name: name)
        )
    }

    func restartServer(name: String) async throws -> MCPRestartServerResult {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "mcp.restartServer",
            params: MCPServerNameParams(name: name)
        )
    }

    // MARK: - Tool Listing

    func listTools(server: String? = nil) async throws -> [MCPToolInfo] {
        let ws = try requireTransport().requireConnection()

        struct ListToolsParams: Encodable {
            let server: String?
        }

        let result: [MCPToolInfo] = try await ws.send(
            method: "mcp.listTools",
            params: ListToolsParams(server: server)
        )
        return result
    }

    // MARK: - Reload

    func reload() async throws -> MCPReloadResult {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "mcp.reload",
            params: EmptyParams()
        )
    }
}
