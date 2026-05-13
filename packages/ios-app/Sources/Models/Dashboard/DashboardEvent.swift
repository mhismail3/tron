import Foundation

/// Clean boundary between the event/plugin layer and the dashboard streaming layer.
/// EventStoreManager maps plugin results to this enum; DashboardStreamManager consumes it.
/// Neither layer imports the other's types.
enum DashboardEvent {
    case turnStart
    case textDelta(delta: String)
    case thinkingDelta
    case capabilityInvocationStarted(identity: CapabilityIdentity, invocationId: String?, arguments: [String: AnyCodable]?)
    case capabilityInvocationCompleted(identity: CapabilityIdentity, invocationId: String?, success: Bool, durationMs: Int?)
    case subagentSpawned(task: String, invocationId: String?, subagentSessionId: String, spawnType: String?)
    case subagentCompleted(turns: Int, durationMs: Int?, subagentSessionId: String, spawnType: String?)
    case subagentFailed(error: String, subagentSessionId: String, spawnType: String?)
    case turnFailed(error: String)
    case complete
    case error(message: String)
}
