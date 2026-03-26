import Foundation

// MARK: - GetConfirmationContext Conformance

extension ChatViewModel: GetConfirmationContext {
    func sendConfirmationPrompt(_ text: String) {
        inputText = text
        sendMessage()
    }
}

// MARK: - GetConfirmation Methods

extension ChatViewModel {

    // MARK: - Sheet Management

    /// Open the GetConfirmation sheet for a tool call
    func openGetConfirmationSheet(for data: GetConfirmationToolData) {
        getConfirmationCoordinator.openSheet(for: data, context: self)
    }

    /// Dismiss GetConfirmation sheet without submitting
    func dismissGetConfirmationSheet() {
        getConfirmationCoordinator.dismissSheet(context: self)
    }

    // MARK: - Decision Submission

    /// Handle GetConfirmation decision submission (sends as new prompt)
    func submitGetConfirmationDecision(_ decision: ConfirmationDecision, note: String?) async {
        await getConfirmationCoordinator.submitDecision(decision, note: note, context: self)
    }

    // MARK: - State Management

    /// Mark all pending GetConfirmation chips as superseded
    func markPendingConfirmationsAsSuperseded() {
        getConfirmationCoordinator.markPendingConfirmationsAsSuperseded(context: self)
    }
}
