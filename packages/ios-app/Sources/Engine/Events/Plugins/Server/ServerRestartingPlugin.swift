import Foundation

/// Plugin for handling server restart events during deployment.
/// These are global events (no sessionId) broadcast to all WebSocket clients
/// before the server shuts down for a deploy restart.
enum ServerRestartingPlugin: DispatchableEventPlugin {
    static let eventType = "server.restarting"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let timestamp: String?
        let data: DataPayload?

        /// Server restart events are global — no session scope.
        var sessionId: String? { nil }

        struct DataPayload: Decodable, Sendable {
            let reason: String?
            let commit: String?
            let restartExpectedMs: Int?
        }
    }

    // MARK: - Result

    struct Result: EventResult {
        let reason: String
        let commit: String
        let restartExpectedMs: Int
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        nil
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(
            reason: event.data?.reason ?? "deploy",
            commit: event.data?.commit ?? "unknown",
            restartExpectedMs: event.data?.restartExpectedMs ?? 5000
        )
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let result = result as? Result else { return }
        context.handleServerRestarting(result)
    }
}
