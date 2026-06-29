import Foundation

/// Plugin for streamed capability argument deltas.
///
/// The server emits this event while a model is still assembling an invocation.
/// Deltas can contain partial raw arguments, so the iOS client parses only the
/// routing envelope and intentionally produces no UI result.
enum CapabilityInvocationArgumentsDeltaPlugin: EventPlugin {
    static let eventType = "capability.invocation.arguments_delta"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
