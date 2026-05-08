import Foundation

/// Client for display stream engine capabilities.
/// Used to control display streams (e.g., stopping an active screen capture stream).
@MainActor
final class DisplayClient: EngineDomainClient {

    /// Stop an active display stream by stream ID.
    func stopStream(streamId: String, idempotencyKey: EngineIdempotencyKey) async throws -> StopStreamResult {
        _ = try requireTransport().requireConnection()

        struct StopStreamParams: Codable {
            let streamId: String
        }

        let params = StopStreamParams(streamId: streamId)
        return try await invokeWrite("display::stop_stream", params, idempotencyKey: idempotencyKey)
    }
}

// MARK: - Response Types

struct StopStreamResult: Codable {
    let streamId: String
    let stopped: Bool
}
