/// Lifecycle phases of the agent during a chat turn.
enum AgentPhase: Equatable, Sendable {
    case idle
    case processing
    /// A Stop request is pending or matched an active run; terminal server
    /// events still own finalization and the transition back to idle.
    case stopping

    var isIdle: Bool { self == .idle }
    var isActive: Bool { self != .idle }
    var isProcessing: Bool { isActive }
}
