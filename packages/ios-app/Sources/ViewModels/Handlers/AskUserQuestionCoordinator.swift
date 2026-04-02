import Foundation

/// Protocol defining the context required by AskUserQuestionCoordinator.
///
/// This protocol allows AskUserQuestionCoordinator to be tested independently from ChatViewModel
/// by defining the minimum interface it needs to interact with state and dependencies.
///
/// Inherits from:
/// - LoggingContext: Logging and error display (showError)
@MainActor
protocol AskUserQuestionContext: LoggingContext {
    /// AskUserQuestion state container
    var askUserQuestionState: AskUserQuestionState { get }

    /// Messages array for updating tool status
    var messages: [ChatMessage] { get set }

    /// Send the formatted answer as a new prompt
    func sendAnswerPrompt(_ text: String)
}

/// Coordinates AskUserQuestion event handling and user interaction for ChatViewModel.
///
/// Responsibilities:
/// - Sheet management (open/dismiss for pending and answered questions)
/// - Answer submission and validation
/// - Formatting answers as prompts for the agent
/// - Marking pending questions as superseded when user bypasses
///
/// This coordinator extracts AskUserQuestion handling logic from ChatViewModel+AskUserQuestion.swift,
/// making it independently testable while maintaining the same behavior.
@MainActor
final class AskUserQuestionCoordinator {

    // MARK: - Initialization

    init() {}

    // MARK: - Sheet Management

    /// Open the AskUserQuestion sheet for a tool call.
    ///
    /// - Parameters:
    ///   - data: The AskUserQuestion tool data
    ///   - context: The context providing access to state and dependencies
    func openSheet(for data: AskUserQuestionToolData, context: AskUserQuestionContext) {
        // Allow opening for pending (to answer) or answered (to view)
        guard data.status == .pending || data.status == .answered else {
            context.logInfo("Not opening AskUserQuestion sheet - status is \(data.status)")
            return
        }

        context.askUserQuestionState.currentData = data
        // Initialize answers from data (in case of re-opening or viewing answered)
        context.askUserQuestionState.answers = data.answers
        context.askUserQuestionState.showSheet = true

        let mode = data.status == .answered ? "read-only" : "interactive"
        context.logInfo("Opened AskUserQuestion sheet (\(mode)) for \(data.params.questions.count) questions")
    }

    /// Dismiss AskUserQuestion sheet without submitting.
    ///
    /// - Parameter context: The context providing access to state
    func dismissSheet(context: AskUserQuestionContext) {
        context.askUserQuestionState.showSheet = false
        context.logInfo("AskUserQuestion sheet dismissed without submitting")
    }

    // MARK: - Two-Phase Answer Submission
    //
    // Submission is split into prepare + execute to avoid a SwiftUI rendering bug:
    // Calling sendAnswerPrompt() while the sheet dismiss animation is in flight causes
    // concurrent state mutations (isProcessing, inputText, keyboard resign) that glitch
    // the safeAreaInset layout, making the InputBar disappear permanently.
    //
    // Phase 1 (prepareSubmission): Updates chip, formats prompt, stores pending. Called
    //   BEFORE dismiss() so the chip updates while the sheet is still visible.
    // Phase 2 (executePendingSubmission): Sends the stored prompt. Called from the
    //   sheet's onDismiss callback AFTER the dismiss animation completes.

    /// Phase 1: Prepare submission — updates chip, formats prompt, stores as pending.
    /// Called BEFORE sheet dismiss. Does NOT send the prompt.
    ///
    /// - Parameters:
    ///   - answers: The answers to submit
    ///   - context: The context providing access to state and dependencies
    func prepareSubmission(_ answers: [AskUserQuestionAnswer], context: AskUserQuestionContext) {
        guard let data = context.askUserQuestionState.currentData else {
            context.logError("Cannot submit answers - no current question data")
            return
        }

        // Verify the question is still pending (not superseded)
        guard data.status == .pending else {
            context.logWarning("Cannot submit answers - question status is \(data.status)")
            context.showError("This question is no longer active")
            context.askUserQuestionState.showSheet = false
            context.askUserQuestionState.currentData = nil
            context.askUserQuestionState.answers = [:]
            return
        }

        // Build the result
        let result = AskUserQuestionResult(
            answers: answers,
            complete: true,
            submittedAt: DateParser.now
        )

        context.logInfo("Preparing AskUserQuestion submission for toolCallId=\(data.toolCallId)")

        // Update the chip status to .answered immediately (visible while sheet animates away)
        updateMessageToAnswered(
            toolCallId: data.toolCallId,
            result: result,
            answers: answers,
            context: context
        )

        // Format answers as a user prompt and store for deferred send
        let answerPrompt = formatAnswersAsPrompt(data: data, answers: answers)
        context.askUserQuestionState.pendingAnswerPrompt = answerPrompt

        // Store question count so MessagingCoordinator doesn't need to re-parse
        context.askUserQuestionState.lastAnsweredQuestionCount = data.params.questions.count

        // Clear answers but keep currentData alive — the sheet reads it during
        // its dismiss animation. Setting currentData = nil here would switch the
        // sheet content to EmptyView(), causing a white flash. currentData is
        // cleared in executePendingSubmission after the animation completes.
        context.askUserQuestionState.showSheet = false
        context.askUserQuestionState.answers = [:]

        context.logInfo("AskUserQuestion submission prepared, awaiting sheet dismiss")
    }

    /// Phase 2: Execute pending submission — sends the stored prompt.
    /// Called from ChatSheetModifier.onDismiss AFTER the sheet dismiss animation completes.
    ///
    /// - Parameter context: The context providing access to state and dependencies
    func executePendingSubmission(context: AskUserQuestionContext) {
        guard let answerPrompt = context.askUserQuestionState.pendingAnswerPrompt else { return }
        context.askUserQuestionState.pendingAnswerPrompt = nil
        context.askUserQuestionState.currentData = nil
        context.sendAnswerPrompt(answerPrompt)
        context.logInfo("AskUserQuestion answers submitted as prompt")
    }

    // MARK: - State Management

    /// Mark all pending AskUserQuestion chips as superseded.
    /// Called before sending a new user message (when user bypasses answering).
    ///
    /// - Parameter context: The context providing access to state
    func markPendingQuestionsAsSuperseded(context: AskUserQuestionContext) {
        for i in context.messages.indices {
            if case .askUserQuestion(var data) = context.messages[i].content,
               data.status == .pending {
                data.status = .superseded
                context.messages[i].content = .askUserQuestion(data)
                context.logInfo("Marked AskUserQuestion \(data.toolCallId) as superseded")
            }
        }
    }

    // MARK: - Formatting

    /// Format answers into a user prompt for the agent.
    ///
    /// - Parameters:
    ///   - data: The original question data
    ///   - answers: The user's answers
    /// - Returns: Formatted prompt string
    func formatAnswersAsPrompt(data: AskUserQuestionToolData, answers: [AskUserQuestionAnswer]) -> String {
        var lines: [String] = [AgentProtocol.askUserAnswerPrefix, ""]

        for question in data.params.questions {
            guard let answer = answers.first(where: { $0.questionId == question.id }) else { continue }

            lines.append("**\(question.question)**")

            if let otherValue = answer.otherValue, !otherValue.isEmpty {
                lines.append("Answer: [Other] \(otherValue)")
            } else if !answer.selectedValues.isEmpty {
                let selected = answer.selectedValues.joined(separator: ", ")
                lines.append("Answer: \(selected)")
            } else {
                lines.append("Answer: (no selection)")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    /// Update the message content to answered status.
    private func updateMessageToAnswered(
        toolCallId: String,
        result: AskUserQuestionResult,
        answers: [AskUserQuestionAnswer],
        context: AskUserQuestionContext
    ) {
        if let index = MessageFinder.lastIndexOfAskUserQuestion(toolCallId: toolCallId, in: context.messages) {
            if case .askUserQuestion(var toolData) = context.messages[index].content {
                toolData.status = .answered
                toolData.result = result
                // Convert array to dictionary
                var answersDict: [String: AskUserQuestionAnswer] = [:]
                for answer in answers {
                    answersDict[answer.questionId] = answer
                }
                toolData.answers = answersDict
                context.messages[index].content = .askUserQuestion(toolData)
            }
        }
    }
}
