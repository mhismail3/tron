import Foundation

/// Client for settings.* RPC methods.
/// Reads and writes server-authoritative settings (compaction, model, workspace).
final class SettingsClient: RPCDomainClient {

    // MARK: - Settings Methods

    func get() async throws -> ServerSettings {
        let ws = try requireTransport().requireConnection()

        let result: ServerSettings = try await ws.send(
            method: "settings.get",
            params: EmptyParams()
        )

        return result
    }

    func update(_ settings: ServerSettingsUpdate) async throws {
        let ws = try requireTransport().requireConnection()

        struct UpdateParams: Encodable {
            let settings: ServerSettingsUpdate
        }

        let _: SuccessResult = try await ws.send(
            method: "settings.update",
            params: UpdateParams(settings: settings)
        )
    }

    /// Reset all settings to server defaults and return the new values.
    func resetToDefaults() async throws -> ServerSettings {
        let ws = try requireTransport().requireConnection()
        return try await ws.send(
            method: "settings.resetToDefaults",
            params: EmptyParams()
        )
    }
}

/// Simple success result for settings.update
private struct SuccessResult: Decodable {
    let success: Bool
}
