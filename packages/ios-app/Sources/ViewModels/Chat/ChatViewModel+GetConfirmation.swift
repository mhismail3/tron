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

    func handleApprovalPending(_ result: ApprovalPendingPlugin.Result) {
        let data = GetConfirmationToolData(
            toolCallId: result.toolCallId,
            params: GetConfirmationParams(
                action: result.actionText,
                reason: result.reasonText,
                riskLevel: .high
            ),
            status: .pending,
            engineApprovalId: result.approvalId,
            engineFunctionId: result.functionId
        )

        if let index = MessageFinder.lastIndexOfGetConfirmation(toolCallId: data.toolCallId, in: messages) {
            messages[index].content = .getConfirmation(data)
            logInfo("Updated engine approval chip for \(result.functionId) approvalId=\(result.approvalId)")
        } else {
            appendToMessages(ChatMessage(role: .assistant, content: .getConfirmation(data)))
            logInfo("Added engine approval chip for \(result.functionId) approvalId=\(result.approvalId)")
        }

        openGetConfirmationSheet(for: data)
    }

    func handleApprovalResolved(_ result: ApprovalResolvedPlugin.Result) {
        guard let index = MessageFinder.lastIndexOfGetConfirmation(toolCallId: result.toolCallId, in: messages),
              case .getConfirmation(var data) = messages[index].content else {
            logDebug("Approval resolved with no visible chip approvalId=\(result.approvalId)")
            return
        }

        let approved = result.approval.status != .denied
        let decision: ConfirmationDecision = approved ? .approved : .denied
        data.status = approved ? .approved : .denied
        data.decision = decision
        data.result = GetConfirmationResult(
            decision: decision,
            note: nil,
            submittedAt: result.approval.decidedAt ?? DateParser.now
        )
        messages[index].content = .getConfirmation(data)
        logInfo("Engine approval resolved approvalId=\(result.approvalId) status=\(result.approval.status.rawValue)")
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
