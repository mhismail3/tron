import Foundation

/// Plugin for handling pluginSources.status_changed events broadcast by the server
/// when plugin source servers are added, removed, enabled, disabled, restarted, or reloaded.
/// These are global events (no sessionId) broadcast to all WebSocket clients.
enum PluginSourceStatusChangedPlugin: EventPlugin {
    static let eventType = "pluginSources.status_changed"

    // MARK: - Event Data

    struct EventData: StandardEventData {
        let type: String
        let timestamp: String?
        let data: [PluginSourceStatus]?

        /// plugin source status events are global — no session scope.
        var sessionId: String? { nil }
    }

    // MARK: - Result

    struct Result: EventResult {
        let servers: [PluginSourceStatus]
    }

    // MARK: - Protocol Implementation

    static func sessionId(from event: EventData) -> String? {
        nil
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(servers: event.data ?? [])
    }
}
