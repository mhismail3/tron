import Foundation

/// Plugin for handling mcp.status_changed events broadcast by the server
/// when MCP servers are added, removed, enabled, disabled, restarted, or reloaded.
/// These are global events (no sessionId) broadcast to all WebSocket clients.
enum MCPStatusChangedPlugin: EventPlugin {
    static let eventType = "mcp.status_changed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let timestamp: String?
        let data: [MCPServerStatus]?

        /// MCP status events are global — no session scope.
        var sessionId: String? { nil }
    }

    // MARK: - Result

    struct Result: EventResult {
        let servers: [MCPServerStatus]
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        nil
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(servers: event.data ?? [])
    }
}
