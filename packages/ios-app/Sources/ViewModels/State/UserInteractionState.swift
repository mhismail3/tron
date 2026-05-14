import SwiftUI

/// Manages UserInteraction capability state for ChatViewModel
/// Extracted from ChatViewModel to reduce property sprawl
@Observable
@MainActor
final class UserInteractionState {
    /// Whether to show the UserInteraction sheet
    var showSheet = false

    /// Current UserInteraction capability data (when sheet is open)
    var currentData: UserInteractionInvocationData?

    /// Pending answers keyed by question ID
    var answers: [String: UserInteractionAnswer] = [:]

    /// Whether UserInteraction was called in the current turn (to suppress subsequent text)
    var calledInTurn = false

    /// Number of questions in the last submitted answer (set by UserInteractionCoordinator)
    var lastAnsweredQuestionCount: Int = 0

    /// Pending answer submission to send after sheet dismissal completes.
    /// Set during prepareSubmission(), consumed by executePendingSubmission().
    var pendingSubmission: [AnswerSubmission]?
    var pendingPauseId: String?
    var pendingInvocationId: String?

    init() {}

    /// Reset turn-specific state (called at turn start)
    func resetForNewTurn() {
        calledInTurn = false
    }

    /// Clear all UserInteraction state
    func clearAll() {
        showSheet = false
        currentData = nil
        answers = [:]
        calledInTurn = false
        pendingSubmission = nil
        pendingPauseId = nil
        pendingInvocationId = nil
    }
}
