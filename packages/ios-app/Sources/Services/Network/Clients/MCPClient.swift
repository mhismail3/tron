import Foundation

/// Client for MCP engine capabilities.
/// Manages MCP server lifecycle: status, add, remove, enable, disable, restart, reload.
final class MCPClient: EngineDomainClient {

    // MARK: - Status

    func status() async throws -> [MCPServerStatus] {
        _ = try requireTransport().requireConnection()
        let result: [MCPServerStatus] = try await invokeRead(
            "mcp::status",
            EmptyParams()
        )
        return result
    }

    // MARK: - Server Management

    func addServer(_ params: MCPAddServerParams, idempotencyKey: EngineIdempotencyKey) async throws -> MCPAddServerResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "mcp::add_server",
            params,
            idempotencyKey: idempotencyKey
        )
    }

    func removeServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()
        let _: MCPSuccessResult = try await invokeWrite(
            "mcp::remove_server",
            MCPServerNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    func enableServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()
        let _: MCPSuccessResult = try await invokeWrite(
            "mcp::enable_server",
            MCPServerNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    func disableServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()
        let _: MCPSuccessResult = try await invokeWrite(
            "mcp::disable_server",
            MCPServerNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    func restartServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws -> MCPRestartServerResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "mcp::restart_server",
            MCPServerNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Tool Listing

    func listTools(server: String? = nil) async throws -> [MCPToolInfo] {
        _ = try requireTransport().requireConnection()

        struct ListToolsParams: Encodable {
            let server: String?
        }

        let result: [MCPToolInfo] = try await invokeRead(
            "mcp::list_tools",
            ListToolsParams(server: server)
        )
        return result
    }

    // MARK: - Reload

    func reload(idempotencyKey: EngineIdempotencyKey) async throws -> MCPReloadResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "mcp::reload",
            EmptyParams(),
            idempotencyKey: idempotencyKey
        )
    }
}
