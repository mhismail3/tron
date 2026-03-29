import Foundation

/// Client for display.* RPC methods.
/// Used to control display streams (e.g., stopping an active screen capture stream).
@MainActor
final class DisplayClient {
    private unowned let transport: RPCTransport

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Stop an active display stream by stream ID.
    func stopStream(streamId: String) async throws -> StopStreamResult {
        let ws = try transport.requireConnection()

        struct StopStreamParams: Codable {
            let streamId: String
        }

        let params = StopStreamParams(streamId: streamId)
        return try await ws.send(method: "display.stopStream", params: params)
    }
}

// MARK: - Response Types

struct StopStreamResult: Codable {
    let streamId: String
    let stopped: Bool
}
