import Foundation

// MARK: - EngineApprovalContext Conformance

extension ChatViewModel: EngineApprovalContext {}

// MARK: - EngineApproval Methods

extension ChatViewModel {
    func engineApprovalToolData(from approval: EngineApprovalRecordDTO) -> EngineApprovalToolData {
        let action = ApprovalEventText.action(functionId: approval.functionId, payload: approval.payload)
        let reason = ApprovalEventText.reason(approvalId: approval.approvalId, functionId: approval.functionId)
        let status: EngineApprovalChipStatus
        let decision: EngineApprovalUserDecision?
        switch approval.status {
        case .pending:
            status = .pending
            decision = nil
        case .denied:
            status = .denied
            decision = .denied
        case .approved, .executed:
            status = .approved
            decision = .approved
        case .failed:
            status = .failed
            decision = .approved
        }
        let result: EngineApprovalResult? = decision.map {
            EngineApprovalResult(
                decision: $0,
                note: nil,
                submittedAt: approval.decidedAt ?? approval.updatedAt ?? DateParser.now
            )
        }
        return EngineApprovalToolData(
            toolCallId: "engine-approval:\(approval.approvalId)",
            params: EngineApprovalParams(
                action: action,
                reason: reason,
                riskLevel: .high
            ),
            status: status,
            decision: decision,
            note: nil,
            result: result,
            engineApprovalId: approval.approvalId,
            engineFunctionId: approval.functionId
        )
    }

    // MARK: - Sheet Management

    /// Open the engine approval sheet for a server-owned approval record.
    func openEngineApprovalSheet(for data: EngineApprovalToolData) {
        engineApprovalCoordinator.openSheet(for: data, context: self)
    }

    func handleApprovalPending(_ result: ApprovalPendingPlugin.Result) {
        let data = engineApprovalToolData(from: result.approval)

        if let index = MessageFinder.lastIndexOfEngineApproval(toolCallId: data.toolCallId, in: messages) {
            messages[index].content = .engineApproval(data)
            logInfo("Updated engine approval chip for \(result.functionId) approvalId=\(result.approvalId)")
        } else {
            appendToMessages(ChatMessage(role: .assistant, content: .engineApproval(data)))
            logInfo("Added engine approval chip for \(result.functionId) approvalId=\(result.approvalId)")
        }

        openEngineApprovalSheet(for: data)
    }

    func handleApprovalResolved(_ result: ApprovalResolvedPlugin.Result) {
        let data = engineApprovalToolData(from: result.approval)
        if let index = MessageFinder.lastIndexOfEngineApproval(toolCallId: result.toolCallId, in: messages) {
            messages[index].content = .engineApproval(data)
        } else {
            appendToMessages(ChatMessage(role: .assistant, content: .engineApproval(data)))
        }
        logInfo("Engine approval resolved approvalId=\(result.approvalId) status=\(result.approval.status.rawValue)")
    }

    /// Dismiss the engine approval sheet without submitting.
    func dismissEngineApprovalSheet() {
        engineApprovalCoordinator.dismissSheet(context: self)
    }

    // MARK: - Decision Submission (Two-Phase)

    /// Phase 1: Prepare submission — updates chip and stores pending submission data.
    /// Called synchronously from sheet's onSubmit BEFORE dismiss.
    func prepareEngineApprovalSubmission(_ decision: EngineApprovalUserDecision, note: String?) {
        engineApprovalCoordinator.prepareSubmission(decision, note: note, context: self)
    }

    /// Phase 2: Execute pending submission — sends via server engine protocol.
    /// Called from ChatSheetModifier.onDismiss AFTER sheet dismiss animation completes.
    func executePendingEngineApprovalSubmission() {
        engineApprovalCoordinator.executePendingSubmission(context: self)
    }

}
