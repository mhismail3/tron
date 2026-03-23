import Foundation

/// Plugin for handling auth.updated events broadcast by the server
/// when auth.json changes (via RPC or CLI `tron login`).
/// These are global events (no sessionId) broadcast to all WebSocket clients.
enum AuthUpdatedPlugin: DispatchableEventPlugin {
    static let eventType = "auth.updated"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let timestamp: String?

        /// Auth update events are global — no session scope.
        var sessionId: String? { nil }
    }

    // MARK: - Result

    struct Result: EventResult {}

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        nil
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result()
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        // Auth updates are handled at the transport level (RPCClient),
        // not via ChatViewModel dispatch. The RPCClient posts a notification
        // that DependencyContainer observes to increment authVersion.
    }
}
