import Foundation

/// Client for settings.* RPC methods.
/// Reads and writes server-authoritative settings (compaction, model, workspace).
@MainActor
final class SettingsClient {
    private weak var transport: RPCTransport?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    // MARK: - Settings Methods

    func get() async throws -> ServerSettings {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        let result: ServerSettings = try await ws.send(
            method: "settings.get",
            params: EmptyParams()
        )

        return result
    }

    func update(_ settings: ServerSettingsUpdate) async throws {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        let ws = try transport.requireConnection()

        struct UpdateParams: Encodable {
            let settings: ServerSettingsUpdate
        }

        let _: SuccessResult = try await ws.send(
            method: "settings.update",
            params: UpdateParams(settings: settings)
        )
    }
}

/// Simple success result for settings.update
private struct SuccessResult: Decodable {
    let success: Bool
}
