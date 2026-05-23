import Foundation

enum ApprovalEventText {
    static func action(functionId: String, payload: [String: AnyCodable]?) -> String {
        let payloadSummary = payload?
            .sorted(by: { $0.key < $1.key })
            .prefix(4)
            .map { key, value in "\(key)=\(String(describing: value.value))" }
            .joined(separator: ", ")

        if let payloadSummary, !payloadSummary.isEmpty {
            return "Approve engine capability \(functionId) with \(payloadSummary)"
        }
        return "Approve engine capability \(functionId)"
    }

    static func reason(approvalId: String, functionId: String) -> String {
        "The engine approval worker requires a user decision before running \(functionId). Approval id: \(approvalId)"
    }
}

// MARK: - approval.pending

enum ApprovalPendingPlugin: DispatchableEventPlugin {
    static let eventType = "approval.pending"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let type: String
            let approval: EngineApprovalRecordDTO
        }
    }

    struct Result: EventResult {
        let approval: EngineApprovalRecordDTO

        var approvalId: String { approval.approvalId }
        var functionId: String { approval.functionId }
        var sessionId: String? { approval.sessionId }
        var workspaceId: String? { approval.workspaceId }
        var invocationId: String { "engine-approval:\(approval.approvalId)" }
        var actionText: String {
            ApprovalEventText.action(functionId: approval.functionId, payload: approval.payload)
        }
        var reasonText: String {
            ApprovalEventText.reason(approvalId: approval.approvalId, functionId: approval.functionId)
        }
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(approval: event.data.approval)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        if r.approval.status == .pending {
            context.handleApprovalPending(r)
        } else {
            context.handleApprovalResolved(ApprovalResolvedPlugin.Result(approval: r.approval, child: nil))
        }
    }
}

// MARK: - approval.resolved

enum ApprovalResolvedPlugin: DispatchableEventPlugin {
    static let eventType = "approval.resolved"

    struct EventData: StandardEventData {
        let type: String
        let sessionId: String?
        let timestamp: String?
        let data: DataPayload

        struct DataPayload: Decodable, Sendable {
            let type: String
            let approval: EngineApprovalRecordDTO
            let child: AnyCodable?
        }
    }

    struct Result: EventResult {
        let approval: EngineApprovalRecordDTO
        let child: AnyCodable?

        var approvalId: String { approval.approvalId }
        var functionId: String { approval.functionId }
        var sessionId: String? { approval.sessionId }
        var workspaceId: String? { approval.workspaceId }
        var invocationId: String { "engine-approval:\(approval.approvalId)" }
    }

    static func transform(_ event: EventData) -> (any EventResult)? {
        Result(approval: event.data.approval, child: event.data.child)
    }

    @MainActor
    static func dispatch(result: any EventResult, context: any EventDispatchTarget) {
        guard let r = result as? Result else { return }
        context.handleApprovalResolved(r)
    }
}
