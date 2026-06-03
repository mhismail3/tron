import Foundation

struct CapabilityProgressStep: Equatable, Identifiable {
    enum State: String, Equatable {
        case pending
        case current
        case completed
        case attention
    }

    let title: String
    let detail: String
    let iconName: String
    let state: State

    var id: String { title }
}

extension CapabilityInvocationDisplayModel {
    static func progressSteps(
        primitive: String,
        data: CapabilityInvocationData,
        target: String?,
        capabilityName: String,
        payloadSummary: String?,
        details: [String: Any]
    ) -> [CapabilityProgressStep] {
        guard primitive == "execute" else {
            let finished = terminalState(data.status)
            return [
                CapabilityProgressStep(
                    title: "Request",
                    detail: capabilityName,
                    iconName: "paperplane",
                    state: finished == nil ? .current : .completed
                ),
                CapabilityProgressStep(
                    title: "Result",
                    detail: finished?.detail ?? "Waiting for response",
                    iconName: finished?.iconName ?? "hourglass",
                    state: finished?.state ?? .pending
                )
            ]
        }

        let orchestration = dictionary(details["orchestration"])
        let phaseDetails = dictionary(orchestration?["phaseDetails"])
        let selectedTarget = dictionary(phaseDetails?["selectedTarget"])
        let preparedRequest = dictionary(phaseDetails?["preparedRequest"])
        let childInvocations = stringArray(details["childInvocations"])
            ?? stringArray(orchestration?["childInvocationIds"])
            ?? []
        let resolvedTarget = target
            ?? string(selectedTarget?["contractId"])
            ?? string(selectedTarget?["functionId"])
            ?? directCapabilityTarget(from: data.identity)
        let targetLabel = resolvedTarget.map(CapabilityPresentation.humanizeCapabilityId)
        let hasResolution = targetLabel != nil
        let isTerminal = terminalState(data.status) != nil
        let hasPrepared = preparedRequest != nil
            || data.approvalState?.isEmpty == false
            || !childInvocations.isEmpty
            || isTerminal
        let runLabel = data.progressMessage?.nilIfEmpty
            ?? targetLabel.map { "Running \($0)" }
            ?? "Executing capability"
        let resultState = terminalState(data.status)

        return [
            CapabilityProgressStep(
                title: "Choose",
                detail: hasResolution ? "\(targetLabel ?? capabilityName) selected" : "Finding the right capability",
                iconName: "scope",
                state: hasResolution ? .completed : (isTerminal ? .attention : .current)
            ),
            CapabilityProgressStep(
                title: "Prepare",
                detail: preparationDetail(data: data, targetLabel: targetLabel, payloadSummary: payloadSummary),
                iconName: "checklist.checked",
                state: !hasResolution ? .pending : (hasPrepared ? .completed : .current)
            ),
            CapabilityProgressStep(
                title: "Run",
                detail: runLabel,
                iconName: "play.circle",
                state: runState(data.status, hasResolution: hasResolution, hasChild: !childInvocations.isEmpty)
            ),
            CapabilityProgressStep(
                title: "Finish",
                detail: resultState?.detail ?? "Waiting for output",
                iconName: resultState?.iconName ?? "hourglass",
                state: resultState?.state ?? .pending
            )
        ]
    }

    private static func directCapabilityTarget(from identity: CapabilityIdentity) -> String? {
        let wrapperIds = ["capability::execute", "capability::search", "capability::inspect"]
        if let functionId = identity.functionId, !wrapperIds.contains(functionId) {
            return functionId
        }
        if let contractId = identity.contractId, !wrapperIds.contains(contractId) {
            return contractId
        }
        return nil
    }

    private static func preparationDetail(
        data: CapabilityInvocationData,
        targetLabel: String?,
        payloadSummary: String?
    ) -> String {
        if data.status == .approvalRequired {
            return "Waiting for approval"
        }
        if data.status == .paused {
            return "Paused before execution"
        }
        let risk = humanizeToken(data.identity.riskLevel)
        let effect = humanizeToken(data.identity.effectClass)
        let safety = [risk, effect].compactMap { $0?.nilIfEmpty }.joined(separator: " · ")
        if !safety.isEmpty {
            return safety
        }
        return payloadSummary?.nilIfEmpty ?? targetLabel.map { "Checking \($0)" } ?? "Checking schema and safety"
    }

    private static func runState(
        _ status: CapabilityInvocationStatus,
        hasResolution: Bool,
        hasChild: Bool
    ) -> CapabilityProgressStep.State {
        guard hasResolution else { return .pending }
        switch status {
        case .success:
            return .completed
        case .error, .unavailable:
            return .attention
        case .running:
            return .current
        case .approvalRequired, .paused, .generating:
            return hasChild ? .current : .pending
        }
    }

    private static func terminalState(
        _ status: CapabilityInvocationStatus
    ) -> (detail: String, iconName: String, state: CapabilityProgressStep.State)? {
        switch status {
        case .success:
            return ("Completed", "checkmark.seal", .completed)
        case .error:
            return ("Needs attention", "exclamationmark.triangle", .attention)
        case .unavailable:
            return ("Unavailable", "exclamationmark.triangle", .attention)
        case .generating, .running, .paused, .approvalRequired:
            return nil
        }
    }
}
