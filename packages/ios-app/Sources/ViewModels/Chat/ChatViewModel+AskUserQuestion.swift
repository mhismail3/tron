import Foundation

// MARK: - AskUserQuestionContext Conformance

extension ChatViewModel: AskUserQuestionContext {
    // showError is implemented in ChatViewModel.swift (shared with BrowserEventContext)

    func sendAnswerPrompt(_ text: String) {
        inputText = text
        sendMessage()
    }
}

// MARK: - AskUserQuestion Methods

extension ChatViewModel {

    // MARK: - Sheet Management

    /// Open the AskUserQuestion sheet for a tool call
    func openAskUserQuestionSheet(for data: AskUserQuestionToolData) {
        askUserQuestionCoordinator.openSheet(for: data, context: self)
    }

    /// Dismiss AskUserQuestion sheet without submitting
    func dismissAskUserQuestionSheet() {
        askUserQuestionCoordinator.dismissSheet(context: self)
    }

    // MARK: - Answer Submission (Two-Phase)

    /// Phase 1: Prepare submission — updates chip and stores pending prompt.
    /// Called synchronously from sheet's onSubmit BEFORE dismiss.
    func prepareAskUserQuestionSubmission(_ answers: [AskUserQuestionAnswer]) {
        askUserQuestionCoordinator.prepareSubmission(answers, context: self)
    }

    /// Phase 2: Execute pending submission — sends stored prompt.
    /// Called from ChatSheetModifier.onDismiss AFTER sheet dismiss animation completes.
    func executePendingAskUserQuestionSubmission() {
        askUserQuestionCoordinator.executePendingSubmission(context: self)
    }

    // MARK: - Question State Management

    /// Mark all pending AskUserQuestion chips as superseded
    /// Called before sending a new user message (when user bypasses answering)
    func markPendingQuestionsAsSuperseded() {
        askUserQuestionCoordinator.markPendingQuestionsAsSuperseded(context: self)
    }
}
