import Foundation

/// Protocol defining the context required by UserInteractionCoordinator.
@MainActor
protocol UserInteractionContext: LoggingContext {
    /// UserInteraction state container
    var userInteractionState: UserInteractionState { get }

    /// Messages array for updating capability status
    var messages: [ChatMessage] { get set }

    /// engine client for server communication
    var engineClient: EngineClient { get }

    /// Append a message to the chat
    func appendMessage(_ message: ChatMessage)

    /// Increment turn counter
    var currentTurn: Int { get set }
}

/// Coordinates UserInteraction event handling and user interaction for ChatViewModel.
///
/// Responsibilities:
/// - Sheet management (open/dismiss for pending and answered questions)
/// - Answer submission and validation
/// - Submitting answers to the server via engine protocol (server constructs the agent prompt)
/// - Marking pending questions as superseded when user bypasses
@MainActor
final class UserInteractionCoordinator {

    init() {}

    // MARK: - Sheet Management

    func openSheet(for data: UserInteractionInvocationData, context: UserInteractionContext) {
        guard data.status == .pending || data.status == .answered else {
            context.logInfo("Not opening UserInteraction sheet - status is \(data.status)")
            return
        }

        context.userInteractionState.currentData = data
        context.userInteractionState.answers = data.answers
        context.userInteractionState.showSheet = true

        let mode = data.status == .answered ? "read-only" : "interactive"
        context.logInfo("Opened UserInteraction sheet (\(mode)) for \(data.params.questions.count) questions")
    }

    func dismissSheet(context: UserInteractionContext) {
        context.userInteractionState.showSheet = false
        context.logInfo("UserInteraction sheet dismissed without submitting")
    }

    // MARK: - Two-Phase Answer Submission
    //
    // Split into prepare + execute to avoid a SwiftUI rendering bug where concurrent
    // sheet dismiss animation + state mutations glitch the safeAreaInset layout.
    //
    // Phase 1 (prepareSubmission): Updates chip, stores structured submission data.
    // Phase 2 (executePendingSubmission): Sends via server engine protocol after sheet dismiss completes.

    /// Phase 1: Prepare submission — updates chip, stores structured data as pending.
    /// Called BEFORE sheet dismiss. Does NOT send to server.
    func prepareSubmission(_ answers: [UserInteractionAnswer], context: UserInteractionContext) {
        guard let data = context.userInteractionState.currentData else {
            context.logError("Cannot submit answers - no current question data")
            return
        }

        guard data.status == .pending else {
            context.logWarning("Cannot submit answers - question status is \(data.status)")
            context.showError("This question is no longer active")
            context.userInteractionState.showSheet = false
            context.userInteractionState.currentData = nil
            context.userInteractionState.answers = [:]
            return
        }

        let result = UserInteractionResult(
            answers: answers,
            complete: true,
            submittedAt: DateParser.now
        )

        context.logInfo("Preparing UserInteraction submission for invocationId=\(data.invocationId)")

        // Update the chip status to .answered immediately
        updateMessageToAnswered(
            invocationId: data.invocationId,
            result: result,
            answers: answers,
            context: context
        )

        // Build structured submission for server engine protocol
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
        context.userInteractionState.pendingSubmission = submissions

        // Store question count for chip display
        context.userInteractionState.lastAnsweredQuestionCount = data.params.questions.count

        context.userInteractionState.showSheet = false
        context.userInteractionState.answers = [:]

        context.logInfo("UserInteraction submission prepared, awaiting sheet dismiss")
    }

    /// Phase 2: Execute pending submission — sends via server engine protocol.
    /// Called from ChatSheetModifier.onDismiss AFTER the sheet dismiss animation completes.
    func executePendingSubmission(context: UserInteractionContext) {
        guard let submissions = context.userInteractionState.pendingSubmission else { return }
        context.userInteractionState.pendingSubmission = nil
        context.userInteractionState.currentData = nil

        // Add answered questions chip to chat
        let questionCount = max(1, context.userInteractionState.lastAnsweredQuestionCount)
        let answerChip = ChatMessage(
            role: .user,
            content: .answeredQuestions(questionCount: questionCount)
        )
        context.appendMessage(answerChip)
        context.currentTurn += 1

        // Submit via server engine protocol (server constructs the agent prompt)
        Task {
            do {
                _ = try await context.engineClient.agent.submitAnswers(questions: submissions, idempotencyKey: .userAction("agent.submitAnswers"))
                context.logInfo("UserInteraction answers submitted via engine protocol")
            } catch {
                context.logError("Failed to submit answers: \(error.localizedDescription)")
                context.showError("Failed to submit answers: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - State Management

    func markPendingQuestionsAsSuperseded(context: UserInteractionContext) {
        for i in context.messages.indices {
            if case .userInteraction(var data) = context.messages[i].content,
               data.status == .pending {
                data.status = .superseded
                context.messages[i].content = .userInteraction(data)
                context.logInfo("Marked UserInteraction \(data.invocationId) as superseded")
            }
        }
    }

    // MARK: - Private Helpers

    private func updateMessageToAnswered(
        invocationId: String,
        result: UserInteractionResult,
        answers: [UserInteractionAnswer],
        context: UserInteractionContext
    ) {
        if let index = MessageFinder.lastIndexOfUserInteraction(invocationId: invocationId, in: context.messages) {
            if case .userInteraction(var capabilityData) = context.messages[index].content {
                capabilityData.status = .answered
                capabilityData.result = result
                var answersDict: [String: UserInteractionAnswer] = [:]
                for answer in answers {
                    answersDict[answer.questionId] = answer
                }
                capabilityData.answers = answersDict
                context.messages[index].content = .userInteraction(capabilityData)
            }
        }
    }
}
