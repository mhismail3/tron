import SwiftUI

/// Manages GetConfirmation tool state for ChatViewModel
@Observable
@MainActor
final class GetConfirmationState {
    /// Whether to show the GetConfirmation sheet
    var showSheet = false

    /// Current GetConfirmation tool data (when sheet is open)
    var currentData: GetConfirmationToolData?

    /// Whether GetConfirmation was called in the current turn (to suppress subsequent text)
    var calledInTurn = false

    /// Whether the last submitted confirmation was an approval (for MessagingCoordinator chip)
    var lastDecisionWasApproval = false

    init() {}

    /// Reset turn-specific state (called at turn start)
    func resetForNewTurn() {
        calledInTurn = false
    }

    /// Clear all GetConfirmation state
    func clearAll() {
        showSheet = false
        currentData = nil
        calledInTurn = false
    }
}
