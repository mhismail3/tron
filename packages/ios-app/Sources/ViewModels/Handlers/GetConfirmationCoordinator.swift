import Foundation

/// Protocol defining the context required by GetConfirmationCoordinator.
@MainActor
protocol GetConfirmationContext: LoggingContext {
    /// GetConfirmation state container
    var getConfirmationState: GetConfirmationState { get }

    /// Messages array for updating tool status
    var messages: [ChatMessage] { get set }

    /// Send the formatted decision as a new prompt
    func sendConfirmationPrompt(_ text: String)
}

/// Coordinates GetConfirmation event handling and user interaction for ChatViewModel.
///
/// Responsibilities:
/// - Sheet management (open/dismiss for pending and decided confirmations)
/// - Decision submission and validation
/// - Formatting decisions as prompts for the agent
/// - Marking pending confirmations as superseded when user bypasses
@MainActor
final class GetConfirmationCoordinator {

    init() {}

    // MARK: - Sheet Management

    /// Open the GetConfirmation sheet for a tool call.
    func openSheet(for data: GetConfirmationToolData, context: GetConfirmationContext) {
        // Allow opening for pending (to decide) or approved/denied (to view)
        guard data.status == .pending || data.status == .approved || data.status == .denied else {
            context.logInfo("Not opening GetConfirmation sheet - status is \(data.status)")
            return
        }

        context.getConfirmationState.currentData = data
        context.getConfirmationState.showSheet = true

        let mode = (data.status == .approved || data.status == .denied) ? "read-only" : "interactive"
        context.logInfo("Opened GetConfirmation sheet (\(mode)) for action: \(data.params.action.prefix(50))")
    }

    /// Dismiss GetConfirmation sheet without submitting.
    func dismissSheet(context: GetConfirmationContext) {
        context.getConfirmationState.showSheet = false
        context.logInfo("GetConfirmation sheet dismissed without submitting")
    }

    // MARK: - Decision Submission

    /// Handle GetConfirmation decision submission (sends as new prompt).
    func submitDecision(
        _ decision: ConfirmationDecision,
        note: String?,
        context: GetConfirmationContext
    ) async {
        guard let data = context.getConfirmationState.currentData else {
            context.logError("Cannot submit decision - no current confirmation data")
            return
        }

        guard data.status == .pending else {
            context.logWarning("Cannot submit decision - confirmation status is \(data.status)")
            context.showError("This confirmation is no longer active")
            context.getConfirmationState.showSheet = false
            context.getConfirmationState.currentData = nil
            return
        }

        let result = GetConfirmationResult(
            decision: decision,
            note: note,
            submittedAt: DateParser.now
        )

        context.logInfo("Submitting GetConfirmation decision=\(decision.rawValue) for toolCallId=\(data.toolCallId)")

        // Update the chip status BEFORE sending
        updateMessageToDecided(
            toolCallId: data.toolCallId,
            decision: decision,
            note: note,
            result: result,
            context: context
        )

        // Format decision as a user prompt
        let prompt = formatDecisionAsPrompt(data: data, decision: decision, note: note)

        // Track decision for MessagingCoordinator chip
        context.getConfirmationState.lastDecisionWasApproval = (decision == .approved)

        // Clear state before sending
        context.getConfirmationState.showSheet = false
        context.getConfirmationState.currentData = nil

        // Send as a new prompt (this triggers a new agent turn)
        context.sendConfirmationPrompt(prompt)

        context.logInfo("GetConfirmation decision submitted as prompt")
    }

    // MARK: - State Management

    /// Mark all pending GetConfirmation chips as superseded.
    /// Called before sending a new user message (when user bypasses confirmation).
    func markPendingConfirmationsAsSuperseded(context: GetConfirmationContext) {
        for i in context.messages.indices {
            if case .getConfirmation(var data) = context.messages[i].content,
               data.status == .pending {
                data.status = .superseded
                context.messages[i].content = .getConfirmation(data)
                context.logInfo("Marked GetConfirmation \(data.toolCallId) as superseded")
            }
        }
    }

    // MARK: - Formatting

    /// Format a decision into a user prompt for the agent.
    ///
    /// Format:
    /// ```
    /// [Confirmation response]
    ///
    /// Action: Install ffmpeg via brew
    /// Decision: Approved
    /// Note: Go ahead
    /// ```
    func formatDecisionAsPrompt(
        data: GetConfirmationToolData,
        decision: ConfirmationDecision,
        note: String?
    ) -> String {
        var lines: [String] = [AgentProtocol.confirmationAnswerPrefix, ""]
        lines.append("Action: \(data.params.action)")
        lines.append("Decision: \(decision.rawValue)")
        if let note = note, !note.isEmpty {
            lines.append("Note: \(note)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Private Helpers

    private func updateMessageToDecided(
        toolCallId: String,
        decision: ConfirmationDecision,
        note: String?,
        result: GetConfirmationResult,
        context: GetConfirmationContext
    ) {
        if let index = MessageFinder.lastIndexOfGetConfirmation(toolCallId: toolCallId, in: context.messages) {
            if case .getConfirmation(var toolData) = context.messages[index].content {
                toolData.status = decision == .approved ? .approved : .denied
                toolData.decision = decision
                toolData.note = note
                toolData.result = result
                context.messages[index].content = .getConfirmation(toolData)
            }
        }
    }
}
