import Foundation

/// Clean boundary between the event/plugin layer and the session activity streaming layer.
/// EventStoreManager maps plugin results to this enum; SessionActivityStreamManager consumes it.
/// Neither layer imports the other's types.
enum SessionActivityEvent {
    case turnStart
    case textDelta(delta: String)
    case thinkingDelta
    case capabilityInvocationStarted(identity: CapabilityIdentity, invocationId: String?, arguments: [String: AnyCodable]?)
    case capabilityInvocationCompleted(identity: CapabilityIdentity, invocationId: String?, success: Bool, durationMs: Int?)
    case turnFailed(error: String)
    case complete
    case error(message: String)
}
