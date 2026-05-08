import Foundation

// MARK: - AskUserQuestionContext Conformance

extension ChatViewModel: AskUserQuestionContext {}

// MARK: - AskUserQuestion Methods

extension ChatViewModel {

    // MARK: - Sheet Management

    func openAskUserQuestionSheet(for data: AskUserQuestionToolData) {
        askUserQuestionCoordinator.openSheet(for: data, context: self)
    }

    func dismissAskUserQuestionSheet() {
        askUserQuestionCoordinator.dismissSheet(context: self)
    }

    // MARK: - Answer Submission (Two-Phase)

    /// Phase 1: Prepare submission — updates chip and stores pending submission data.
    func prepareAskUserQuestionSubmission(_ answers: [AskUserQuestionAnswer]) {
        askUserQuestionCoordinator.prepareSubmission(answers, context: self)
    }

    /// Phase 2: Execute pending submission — sends via server engine protocol.
    func executePendingAskUserQuestionSubmission() {
        askUserQuestionCoordinator.executePendingSubmission(context: self)
    }

    // MARK: - State Management

    func markPendingQuestionsAsSuperseded() {
        askUserQuestionCoordinator.markPendingQuestionsAsSuperseded(context: self)
    }
}
