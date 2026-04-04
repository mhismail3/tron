import Foundation

/// Client for display.* RPC methods.
/// Used to control display streams (e.g., stopping an active screen capture stream).
@MainActor
final class DisplayClient {
    private weak var transport: (any RPCTransport)?

    init(transport: RPCTransport) {
        self.transport = transport
    }

    /// Access transport safely, throwing if deallocated during server change.
    private func requireTransport() throws -> any RPCTransport {
        guard let transport else { throw RPCClientError.connectionNotEstablished }
        return transport
    }

    /// Stop an active display stream by stream ID.
    func stopStream(streamId: String) async throws -> StopStreamResult {
        let ws = try requireTransport().requireConnection()

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
