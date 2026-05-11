import Foundation

/// Protocol defining the context required by GetConfirmationCoordinator.
@MainActor
protocol GetConfirmationContext: LoggingContext {
    /// GetConfirmation state container
    var getConfirmationState: GetConfirmationState { get }

    /// Messages array for updating tool status
    var messages: [ChatMessage] { get set }

    /// engine client for server communication
    var engineClient: EngineClient { get }

    /// Append a message to the chat
    func appendMessage(_ message: ChatMessage)

    /// Increment turn counter
    var currentTurn: Int { get set }
}

/// Coordinates GetConfirmation event handling and user interaction for ChatViewModel.
///
/// Responsibilities:
/// - Sheet management (open/dismiss for pending and decided confirmations)
/// - Decision submission and validation
/// - Submitting decisions to the server via engine protocol (server constructs the agent prompt)
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

    // MARK: - Two-Phase Decision Submission
    //
    // Split into prepare + execute to avoid a SwiftUI rendering bug where concurrent
    // sheet dismiss animation + state mutations (isProcessing, inputText, keyboard resign)
    // glitches the safeAreaInset layout, making the InputBar disappear permanently.
    //
    // Phase 1 (prepareSubmission): Updates chip, stores structured submission data.
    // Phase 2 (executePendingSubmission): Sends via server engine protocol after sheet dismiss completes.

    /// Phase 1: Prepare submission — updates chip, stores structured data as pending.
    /// Called BEFORE sheet dismiss. Does NOT send to server.
    func prepareSubmission(
        _ decision: ConfirmationDecision,
        note: String?,
        context: GetConfirmationContext
    ) {
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

        context.logInfo("Preparing GetConfirmation decision=\(decision.rawValue) for toolCallId=\(data.toolCallId)")

        // Update the chip status immediately (visible while sheet animates away)
        updateMessageToDecided(
            toolCallId: data.toolCallId,
            decision: decision,
            note: note,
            result: result,
            context: context
        )

        // Store structured submission data for deferred send via engine protocol
        context.getConfirmationState.pendingSubmission = PendingGetConfirmationSubmission(
            action: data.params.action,
            decision: decision.rawValue,
            note: note,
            engineApprovalId: data.engineApprovalId,
            engineFunctionId: data.engineFunctionId
        )

        // Track decision for MessagingCoordinator chip
        context.getConfirmationState.lastDecisionWasApproval = (decision == .approved)

        // Keep currentData alive — the sheet reads it during its dismiss animation.
        context.getConfirmationState.showSheet = false

        context.logInfo("GetConfirmation submission prepared, awaiting sheet dismiss")
    }

    /// Phase 2: Execute pending submission — sends via server engine protocol.
    /// Called from ChatSheetModifier.onDismiss AFTER the sheet dismiss animation completes.
    func executePendingSubmission(context: GetConfirmationContext) {
        guard let submission = context.getConfirmationState.pendingSubmission else { return }
        context.getConfirmationState.pendingSubmission = nil
        context.getConfirmationState.currentData = nil

        // Add confirmed action chip to chat
        let approved = context.getConfirmationState.lastDecisionWasApproval
        let confirmChip = ChatMessage(
            role: .user,
            content: .confirmedAction(approved: approved)
        )
        context.appendMessage(confirmChip)
        context.currentTurn += 1

        // Submit via server engine protocol. Engine approval chips resolve the
        // approval primitive directly; model-level GetConfirmation chips still
        // submit a normal agent confirmation response.
        Task {
            do {
                if let approvalId = submission.engineApprovalId {
                    let decision = submission.decision == ConfirmationDecision.approved.rawValue
                        ? EngineApprovalDecision.approve
                        : EngineApprovalDecision.deny
                    _ = try await context.engineClient.approval.resolve(
                        approvalId: approvalId,
                        decision: decision,
                        idempotencyKey: EngineIdempotencyKey(
                            rawValue: "ios:approval.resolve:\(approvalId):\(decision.rawValue)"
                        )
                    )
                    context.logInfo(
                        "Engine approval \(approvalId) for \(submission.engineFunctionId ?? "unknown") resolved through approval::resolve"
                    )
                } else {
                    _ = try await context.engineClient.agent.submitConfirmation(
                        action: submission.action,
                        decision: submission.decision,
                        note: submission.note,
                        idempotencyKey: .userAction("agent.submitConfirmation")
                    )
                    context.logInfo("GetConfirmation decision submitted via agent::submit_confirmation")
                }
            } catch {
                context.logError("Failed to submit confirmation: \(error.localizedDescription)")
                context.showError("Failed to submit confirmation: \(error.localizedDescription)")
            }
        }
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
