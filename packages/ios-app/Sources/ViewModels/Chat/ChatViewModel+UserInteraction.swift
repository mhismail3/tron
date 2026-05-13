import Foundation

// MARK: - UserInteractionContext Conformance

extension ChatViewModel: UserInteractionContext {}

// MARK: - UserInteraction Methods

extension ChatViewModel {

    // MARK: - Sheet Management

    func openUserInteractionSheet(for data: UserInteractionInvocationData) {
        userInteractionCoordinator.openSheet(for: data, context: self)
    }

    func dismissUserInteractionSheet() {
        userInteractionCoordinator.dismissSheet(context: self)
    }

    // MARK: - Answer Submission (Two-Phase)

    /// Phase 1: Prepare submission — updates chip and stores pending submission data.
    func prepareUserInteractionSubmission(_ answers: [UserInteractionAnswer]) {
        userInteractionCoordinator.prepareSubmission(answers, context: self)
    }

    /// Phase 2: Execute pending submission — sends via server engine protocol.
    func executePendingUserInteractionSubmission() {
        userInteractionCoordinator.executePendingSubmission(context: self)
    }

    // MARK: - State Management

    func markPendingQuestionsAsSuperseded() {
        userInteractionCoordinator.markPendingQuestionsAsSuperseded(context: self)
    }
}
