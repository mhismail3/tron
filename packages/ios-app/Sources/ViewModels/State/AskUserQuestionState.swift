import SwiftUI

/// Manages AskUserQuestion tool state for ChatViewModel
/// Extracted from ChatViewModel to reduce property sprawl
@Observable
@MainActor
final class AskUserQuestionState {
    /// Whether to show the AskUserQuestion sheet
    var showSheet = false

    /// Current AskUserQuestion tool data (when sheet is open)
    var currentData: AskUserQuestionToolData?

    /// Pending answers keyed by question ID
    var answers: [String: AskUserQuestionAnswer] = [:]

    /// Whether AskUserQuestion was called in the current turn (to suppress subsequent text)
    var calledInTurn = false

    /// Number of questions in the last submitted answer (set by AskUserQuestionCoordinator)
    var lastAnsweredQuestionCount: Int = 0

    init() {}

    /// Reset turn-specific state (called at turn start)
    func resetForNewTurn() {
        calledInTurn = false
    }

    /// Clear all AskUserQuestion state
    func clearAll() {
        showSheet = false
        currentData = nil
        answers = [:]
        calledInTurn = false
    }
}
