import Foundation

// MARK: - Abort Session Error

/// Errors that can occur when aborting a session
enum AbortSessionError: LocalizedError, Equatable {
    case noActiveSession
    case abortFailed(message: String)

    static func == (lhs: AbortSessionError, rhs: AbortSessionError) -> Bool {
        switch (lhs, rhs) {
        case (.noActiveSession, .noActiveSession): return true
        case (.abortFailed(let lm), .abortFailed(let rm)): return lm == rm
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .noActiveSession:
            return "No active session to abort"
        case .abortFailed(let message):
            return "Failed to abort: \(message)"
        }
    }
}

// MARK: - Abort Session Use Case

/// Use case for aborting the current agent processing.
/// Sends an abort signal to stop the agent's current operation.
@MainActor
final class AbortSessionUseCase: VoidRequestUseCase {
    private let agentClient: AgentClientProtocol

    init(agentClient: AgentClientProtocol) {
        self.agentClient = agentClient
    }

    typealias Response = Void

    func execute() async throws {
        do {
            try await agentClient.abort()
        } catch {
            throw AbortSessionError.abortFailed(message: error.localizedDescription)
        }
    }
}
