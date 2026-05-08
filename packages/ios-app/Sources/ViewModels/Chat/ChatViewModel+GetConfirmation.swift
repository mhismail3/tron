import Foundation

// MARK: - GetConfirmationContext Conformance

extension ChatViewModel: GetConfirmationContext {}

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

    // MARK: - Decision Submission (Two-Phase)

    /// Phase 1: Prepare submission — updates chip and stores pending submission data.
    /// Called synchronously from sheet's onSubmit BEFORE dismiss.
    func prepareGetConfirmationSubmission(_ decision: ConfirmationDecision, note: String?) {
        getConfirmationCoordinator.prepareSubmission(decision, note: note, context: self)
    }

    /// Phase 2: Execute pending submission — sends via server engine protocol.
    /// Called from ChatSheetModifier.onDismiss AFTER sheet dismiss animation completes.
    func executePendingGetConfirmationSubmission() {
        getConfirmationCoordinator.executePendingSubmission(context: self)
    }

    // MARK: - State Management

    /// Mark all pending GetConfirmation chips as superseded
    func markPendingConfirmationsAsSuperseded() {
        getConfirmationCoordinator.markPendingConfirmationsAsSuperseded(context: self)
    }
}
