import Foundation

/// Client for plugin source engine capabilities.
/// Manages plugin source server lifecycle: status, add, remove, enable, disable, restart, reload.
final class PluginSourceClient: EngineDomainClient {

    // MARK: - Status

    func status() async throws -> [PluginSourceStatus] {
        _ = try requireTransport().requireConnection()
        let result: [PluginSourceStatus] = try await invokeRead(
            "mcp::status",
            EmptyParams()
        )
        return result
    }

    // MARK: - Server Management

    func addServer(_ params: PluginSourceAddParams, idempotencyKey: EngineIdempotencyKey) async throws -> PluginSourceAddResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "mcp::add_server",
            params,
            idempotencyKey: idempotencyKey
        )
    }

    func removeServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()
        let _: PluginSourceSuccessResult = try await invokeWrite(
            "mcp::remove_server",
            PluginSourceNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    func enableServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()
        let _: PluginSourceSuccessResult = try await invokeWrite(
            "mcp::enable_server",
            PluginSourceNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    func disableServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()
        let _: PluginSourceSuccessResult = try await invokeWrite(
            "mcp::disable_server",
            PluginSourceNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    func restartServer(name: String, idempotencyKey: EngineIdempotencyKey) async throws -> PluginSourceRestartResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "mcp::restart_server",
            PluginSourceNameParams(name: name),
            idempotencyKey: idempotencyKey
        )
    }

    // MARK: - Tool Listing

    func listTools(server: String? = nil) async throws -> [PluginCapabilityInfo] {
        _ = try requireTransport().requireConnection()

        struct ListToolsParams: Encodable {
            let server: String?
        }

        let result: [PluginCapabilityInfo] = try await invokeRead(
            "mcp::list_tools",
            ListToolsParams(server: server)
        )
        return result
    }

    // MARK: - Reload

    func reload(idempotencyKey: EngineIdempotencyKey) async throws -> PluginSourceReloadResult {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "mcp::reload",
            EmptyParams(),
            idempotencyKey: idempotencyKey
        )
    }
}
