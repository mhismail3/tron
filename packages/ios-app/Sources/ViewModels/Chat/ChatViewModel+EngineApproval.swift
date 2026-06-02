import Foundation

// MARK: - EngineApprovalContext Conformance

extension ChatViewModel: EngineApprovalContext {}

// MARK: - EngineApproval Methods

extension ChatViewModel {
    func engineApprovalCapabilityData(from approval: EngineApprovalRecordDTO) -> EngineApprovalData {
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
        return EngineApprovalData(
            invocationId: "engine-approval:\(approval.approvalId)",
            params: EngineApprovalParams(
                action: action,
                reason: reason,
                riskLevel: EngineApprovalRiskLevel(serverValue: approval.targetMetadata?.riskLevel)
            ),
            status: status,
            decision: decision,
            note: nil,
            result: result,
            engineApprovalId: approval.approvalId,
            engineFunctionId: approval.functionId,
            authorityGrantId: approval.authorityGrantId,
            authorityScopes: approval.authorityScopes ?? [],
            idempotencyKey: approval.idempotencyKey,
            targetMetadata: approval.targetMetadata
        )
    }

    // MARK: - Sheet Management

    /// Open the engine approval sheet for a server-owned approval record.
    func openEngineApprovalSheet(for data: EngineApprovalData) {
        engineApprovalCoordinator.openSheet(for: data, context: self)
    }

    func handleApprovalPending(_ result: ApprovalPendingPlugin.Result) {
        guard result.approval.status == .pending else {
            handleApprovalResolved(ApprovalResolvedPlugin.Result(approval: result.approval, child: nil))
            return
        }
        let data = engineApprovalCapabilityData(from: result.approval)

        if let index = MessageFinder.lastIndexOfEngineApproval(invocationId: data.invocationId, in: messages) {
            messages[index].content = .engineApproval(data)
            logInfo("Updated engine approval chip for \(result.functionId) approvalId=\(result.approvalId)")
        } else {
            appendToMessages(ChatMessage(role: .assistant, content: .engineApproval(data)))
            logInfo("Added engine approval chip for \(result.functionId) approvalId=\(result.approvalId)")
        }

        openEngineApprovalSheet(for: data)
    }

    func handleApprovalResolved(_ result: ApprovalResolvedPlugin.Result) {
        let data = engineApprovalCapabilityData(from: result.approval)
        if let index = MessageFinder.lastIndexOfEngineApproval(invocationId: result.invocationId, in: messages) {
            messages[index].content = .engineApproval(data)
        } else {
            appendToMessages(ChatMessage(role: .assistant, content: .engineApproval(data)))
        }
        engineApprovalState.clearSheetIfShowingApproval(result.approvalId)
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
