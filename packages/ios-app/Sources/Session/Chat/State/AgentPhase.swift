/// Lifecycle phases of the agent during a chat turn.
enum AgentPhase: Equatable, Sendable {
    case idle
    case processing

    var isIdle: Bool { self == .idle }
    var isActive: Bool { self != .idle }
    var isProcessing: Bool { self == .processing }
}
