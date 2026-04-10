import Foundation

/// Clean boundary between the event/plugin layer and the dashboard streaming layer.
/// EventStoreManager maps plugin results to this enum; DashboardStreamManager consumes it.
/// Neither layer imports the other's types.
enum DashboardEvent {
    case turnStart
    case textDelta(delta: String)
    case thinkingDelta
    case toolStart(toolName: String, toolCallId: String?, arguments: [String: AnyCodable]?)
    case toolEnd(toolName: String?, toolCallId: String?, success: Bool, durationMs: Int?)
    case subagentSpawned(task: String, toolCallId: String?, subagentSessionId: String, spawnType: String?)
    case subagentCompleted(turns: Int, durationMs: Int?, subagentSessionId: String, spawnType: String?)
    case subagentFailed(error: String, subagentSessionId: String, spawnType: String?)
    case turnFailed(error: String)
    case complete
    case error(message: String)
}
