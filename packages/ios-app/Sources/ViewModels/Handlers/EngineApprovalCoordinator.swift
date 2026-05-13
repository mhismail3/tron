import Foundation

/// Protocol defining the context required by EngineApprovalCoordinator.
@MainActor
protocol EngineApprovalContext: LoggingContext {
    /// EngineApproval state container
    var engineApprovalState: EngineApprovalState { get }

    /// Messages array for updating tool status
    var messages: [ChatMessage] { get set }

    /// engine client for server communication
    var engineClient: EngineClient { get }

}

/// Coordinates EngineApproval event handling and user interaction for ChatViewModel.
///
/// Responsibilities:
/// - Sheet management (open/dismiss for pending and decided approvals)
/// - Decision submission and validation
/// - Submitting decisions to the server via canonical `approval::resolve`
@MainActor
final class EngineApprovalCoordinator {

    init() {}

    // MARK: - Sheet Management

    /// Open the engine approval sheet.
    func openSheet(for data: EngineApprovalToolData, context: EngineApprovalContext) {
        // Allow opening for pending (to decide) or approved/denied (to view)
        guard data.status == .pending || data.status == .approved || data.status == .denied else {
            context.logInfo("Not opening EngineApproval sheet - status is \(data.status)")
            return
        }

        context.engineApprovalState.currentData = data
        context.engineApprovalState.showSheet = true

        let mode = (data.status == .approved || data.status == .denied) ? "read-only" : "interactive"
        context.logInfo("Opened EngineApproval sheet (\(mode)) for action: \(data.params.action.prefix(50))")
    }

    /// Dismiss EngineApproval sheet without submitting.
    func dismissSheet(context: EngineApprovalContext) {
        context.engineApprovalState.showSheet = false
        context.logInfo("EngineApproval sheet dismissed without submitting")
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
        _ decision: EngineApprovalUserDecision,
        note: String?,
        context: EngineApprovalContext
    ) {
        guard let data = context.engineApprovalState.currentData else {
            context.logError("Cannot submit decision - no current engine approval data")
            return
        }

        guard data.status == .pending else {
            context.logWarning("Cannot submit decision - engine approval status is \(data.status)")
            context.showError("This approval is no longer active")
            context.engineApprovalState.showSheet = false
            context.engineApprovalState.currentData = nil
            return
        }

        let result = EngineApprovalResult(
            decision: decision,
            note: note,
            submittedAt: DateParser.now
        )

        context.logInfo("Preparing EngineApproval decision=\(decision.rawValue) for invocationId=\(data.invocationId)")

        // Update the chip status immediately (visible while sheet animates away)
        updateMessageToDecided(
            invocationId: data.invocationId,
            decision: decision,
            note: note,
            result: result,
            context: context
        )

        // Store structured submission data for deferred send via engine protocol
        context.engineApprovalState.pendingSubmission = PendingEngineApprovalSubmission(
            action: data.params.action,
            decision: decision.rawValue,
            note: note,
            engineApprovalId: data.engineApprovalId,
            engineFunctionId: data.engineFunctionId
        )

        // Keep currentData alive — the sheet reads it during its dismiss animation.
        context.engineApprovalState.showSheet = false

        context.logInfo("EngineApproval submission prepared, awaiting sheet dismiss")
    }

    /// Phase 2: Execute pending submission — sends via server engine protocol.
    /// Called from ChatSheetModifier.onDismiss AFTER the sheet dismiss animation completes.
    func executePendingSubmission(context: EngineApprovalContext) {
        guard let submission = context.engineApprovalState.pendingSubmission else { return }
        context.engineApprovalState.pendingSubmission = nil
        context.engineApprovalState.currentData = nil

        // Submit via the canonical engine approval primitive. Approval chips
        // are server-owned records; there is no model-level confirmation path.
        Task {
            do {
                guard let approvalId = submission.engineApprovalId else {
                    context.logError("Approval chip is missing engineApprovalId; refusing non-engine confirmation path")
                    context.showError("Approval record is missing; reconnect and try again.")
                    return
                }
                let decision = submission.decision == EngineApprovalUserDecision.approved.rawValue
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
            } catch {
                context.logError("Failed to resolve engine approval: \(error.localizedDescription)")
                context.showError("Failed to resolve approval: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private Helpers

    private func updateMessageToDecided(
        invocationId: String,
        decision: EngineApprovalUserDecision,
        note: String?,
        result: EngineApprovalResult,
        context: EngineApprovalContext
    ) {
        if let index = MessageFinder.lastIndexOfEngineApproval(invocationId: invocationId, in: context.messages) {
            if case .engineApproval(var toolData) = context.messages[index].content {
                toolData.status = decision == .approved ? .approved : .denied
                toolData.decision = decision
                toolData.note = note
                toolData.result = result
                context.messages[index].content = .engineApproval(toolData)
            }
        }
    }
}
