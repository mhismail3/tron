import Foundation

/// Plugin for the server's capability batch snapshot marker.
///
/// Individual capability invocation events remain the canonical UI update
/// stream. The batch marker is parsed for session/sequence ownership so it does
/// not become unknown global noise during live session filtering.
enum CapabilityInvocationBatchPlugin: EventPlugin {
    static let eventType = "capability.invocation.batch"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        nil
    }
}
