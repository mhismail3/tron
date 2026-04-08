import Foundation

/// Protocol defining the context required by AskUserQuestionCoordinator.
@MainActor
protocol AskUserQuestionContext: LoggingContext {
    /// AskUserQuestion state container
    var askUserQuestionState: AskUserQuestionState { get }

    /// Messages array for updating tool status
    var messages: [ChatMessage] { get set }

    /// RPC client for server communication
    var rpcClient: RPCClient { get }

    /// Append a message to the chat
    func appendMessage(_ message: ChatMessage)

    /// Increment turn counter
    var currentTurn: Int { get set }
}

/// Coordinates AskUserQuestion event handling and user interaction for ChatViewModel.
///
/// Responsibilities:
/// - Sheet management (open/dismiss for pending and answered questions)
/// - Answer submission and validation
/// - Submitting answers to the server via RPC (server constructs the agent prompt)
/// - Marking pending questions as superseded when user bypasses
@MainActor
final class AskUserQuestionCoordinator {

    init() {}

    // MARK: - Sheet Management

    func openSheet(for data: AskUserQuestionToolData, context: AskUserQuestionContext) {
        guard data.status == .pending || data.status == .answered else {
            context.logInfo("Not opening AskUserQuestion sheet - status is \(data.status)")
            return
        }

        context.askUserQuestionState.currentData = data
        context.askUserQuestionState.answers = data.answers
        context.askUserQuestionState.showSheet = true

        let mode = data.status == .answered ? "read-only" : "interactive"
        context.logInfo("Opened AskUserQuestion sheet (\(mode)) for \(data.params.questions.count) questions")
    }

    func dismissSheet(context: AskUserQuestionContext) {
        context.askUserQuestionState.showSheet = false
        context.logInfo("AskUserQuestion sheet dismissed without submitting")
    }

    // MARK: - Two-Phase Answer Submission
    //
    // Split into prepare + execute to avoid a SwiftUI rendering bug where concurrent
    // sheet dismiss animation + state mutations glitch the safeAreaInset layout.
    //
    // Phase 1 (prepareSubmission): Updates chip, stores structured submission data.
    // Phase 2 (executePendingSubmission): Sends via server RPC after sheet dismiss completes.

    /// Phase 1: Prepare submission — updates chip, stores structured data as pending.
    /// Called BEFORE sheet dismiss. Does NOT send to server.
    func prepareSubmission(_ answers: [AskUserQuestionAnswer], context: AskUserQuestionContext) {
        guard let data = context.askUserQuestionState.currentData else {
            context.logError("Cannot submit answers - no current question data")
            return
        }

        guard data.status == .pending else {
            context.logWarning("Cannot submit answers - question status is \(data.status)")
            context.showError("This question is no longer active")
            context.askUserQuestionState.showSheet = false
            context.askUserQuestionState.currentData = nil
            context.askUserQuestionState.answers = [:]
            return
        }

        let result = AskUserQuestionResult(
            answers: answers,
            complete: true,
            submittedAt: DateParser.now
        )

        context.logInfo("Preparing AskUserQuestion submission for toolCallId=\(data.toolCallId)")

        // Update the chip status to .answered immediately
        updateMessageToAnswered(
            toolCallId: data.toolCallId,
            result: result,
            answers: answers,
            context: context
        )

        // Build structured submission for server RPC
        var submissions: [AnswerSubmission] = []
        for question in data.params.questions {
            guard let answer = answers.first(where: { $0.questionId == question.id }) else { continue }
            submissions.append(AnswerSubmission(
                id: question.id,
                question: question.question,
                selectedValues: answer.selectedValues,
                otherValue: answer.otherValue
            ))
        }
        context.askUserQuestionState.pendingSubmission = submissions

        // Store question count for chip display
        context.askUserQuestionState.lastAnsweredQuestionCount = data.params.questions.count

        context.askUserQuestionState.showSheet = false
        context.askUserQuestionState.answers = [:]

        context.logInfo("AskUserQuestion submission prepared, awaiting sheet dismiss")
    }

    /// Phase 2: Execute pending submission — sends via server RPC.
    /// Called from ChatSheetModifier.onDismiss AFTER the sheet dismiss animation completes.
    func executePendingSubmission(context: AskUserQuestionContext) {
        guard let submissions = context.askUserQuestionState.pendingSubmission else { return }
        context.askUserQuestionState.pendingSubmission = nil
        context.askUserQuestionState.currentData = nil

        // Add answered questions chip to chat
        let questionCount = max(1, context.askUserQuestionState.lastAnsweredQuestionCount)
        let answerChip = ChatMessage(
            role: .user,
            content: .answeredQuestions(questionCount: questionCount)
        )
        context.appendMessage(answerChip)
        context.currentTurn += 1

        // Submit via server RPC (server constructs the agent prompt)
        Task {
            do {
                _ = try await context.rpcClient.agent.submitAnswers(questions: submissions)
                context.logInfo("AskUserQuestion answers submitted via RPC")
            } catch {
                context.logError("Failed to submit answers: \(error.localizedDescription)")
                context.showError("Failed to submit answers: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - State Management

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

    // MARK: - Private Helpers

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
