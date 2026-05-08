import Foundation

/// Client for settings engine capabilities.
/// Reads and writes server-authoritative settings (compaction, model, workspace).
final class SettingsClient: EngineDomainClient {

    // MARK: - Settings Methods

    func get() async throws -> ServerSettings {
        _ = try requireTransport().requireConnection()

        let result: ServerSettings = try await invokeRead(
            "settings::get",
            EmptyParams()
        )

        return result
    }

    func update(_ settings: ServerSettingsUpdate, idempotencyKey: EngineIdempotencyKey) async throws {
        _ = try requireTransport().requireConnection()

        struct UpdateParams: Encodable {
            let settings: ServerSettingsUpdate
        }

        let _: SuccessResult = try await invokeWrite(
            "settings::update",
            UpdateParams(settings: settings),
            idempotencyKey: idempotencyKey
        )
    }

    /// Reset all settings to server defaults and return the new values.
    func resetToDefaults(idempotencyKey: EngineIdempotencyKey) async throws -> ServerSettings {
        _ = try requireTransport().requireConnection()
        return try await invokeWrite(
            "settings::reset_to_defaults",
            EmptyParams(),
            idempotencyKey: idempotencyKey
        )
    }
}

/// Simple success result for settings.update
private struct SuccessResult: Decodable {
    let success: Bool
}
