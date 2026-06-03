import Foundation

enum ApprovalEventText {
    static func action(functionId: String, payload: [String: AnyCodable]?) -> String {
        action(functionId: functionId, payload: payload, workspaceId: nil, sessionId: nil)
    }

    static func action(
        functionId: String,
        payload: [String: AnyCodable]?,
        workspaceId: String?,
        sessionId: String?
    ) -> String {
        if let action = localCapabilityAction(
            functionId: functionId,
            payload: payload,
            workspaceId: workspaceId,
            sessionId: sessionId
        ) {
            return action
        }

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

    static func reason(approvalId: String, functionId: String, payload: [String: AnyCodable]?) -> String {
        reason(
            approvalId: approvalId,
            functionId: functionId,
            payload: payload,
            workspaceId: nil,
            sessionId: nil
        )
    }

    static func reason(
        approvalId: String,
        functionId: String,
        payload: [String: AnyCodable]?,
        workspaceId: String?,
        sessionId: String?
    ) -> String {
        if let reason = localCapabilityReason(
            functionId: functionId,
            payload: payload,
            workspaceId: workspaceId,
            sessionId: sessionId
        ) {
            return reason
        }
        return "The engine approval worker requires a user decision before running \(functionId). Approval id: \(approvalId)"
    }

    static func reason(approvalId: String, functionId: String) -> String {
        reason(approvalId: approvalId, functionId: functionId, payload: nil)
    }

    private static func localCapabilityAction(
        functionId: String,
        payload: [String: AnyCodable]?,
        workspaceId: String?,
        sessionId: String?
    ) -> String? {
        guard functionId == "self_extension::grant_workspace_autonomy" else { return nil }
        if isWorkspaceLocal(payload, workspaceId: workspaceId) {
            return "Allow local capability work in this workspace"
        }
        if isSessionLocal(payload, sessionId: sessionId) {
            return "Allow local capability work in this chat"
        }
        return "Allow local capability work"
    }

    private static func localCapabilityReason(
        functionId: String,
        payload: [String: AnyCodable]?,
        workspaceId: String?,
        sessionId: String?
    ) -> String? {
        guard functionId == "self_extension::grant_workspace_autonomy" else { return nil }
        if isWorkspaceLocal(payload, workspaceId: workspaceId) {
            return "Tron needs your approval before creating or updating a local capability in this workspace."
        }
        if isSessionLocal(payload, sessionId: sessionId) {
            return "Tron needs your approval before creating or updating a local capability in this chat."
        }
        return "Tron needs your approval before creating or updating a local capability."
    }

    private static func isWorkspaceLocal(_ payload: [String: AnyCodable]?, workspaceId: String?) -> Bool {
        payload?.string("visibility")?.lowercased() == "workspace"
            || payload?.string("workspaceId")?.nilIfEmpty != nil
            || workspaceId?.nilIfEmpty != nil
    }

    private static func isSessionLocal(_ payload: [String: AnyCodable]?, sessionId: String?) -> Bool {
        payload?.string("visibility")?.lowercased() == "session"
            || payload?.string("sessionId")?.nilIfEmpty != nil
            || sessionId?.nilIfEmpty != nil
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
            ApprovalEventText.action(
                functionId: approval.functionId,
                payload: approval.payload,
                workspaceId: approval.workspaceId,
                sessionId: approval.sessionId
            )
        }
        var reasonText: String {
            ApprovalEventText.reason(
                approvalId: approval.approvalId,
                functionId: approval.functionId,
                payload: approval.payload,
                workspaceId: approval.workspaceId,
                sessionId: approval.sessionId
            )
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
