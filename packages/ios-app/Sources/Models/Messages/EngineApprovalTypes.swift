import Foundation

// MARK: - Engine Approval Types

/// Risk level for an engine-owned approval request.
enum EngineApprovalRiskLevel: String, Codable, Equatable {
    case low
    case medium
    case high
}

/// Renderable text for an engine-owned approval chip.
struct EngineApprovalParams: Codable, Equatable {
    /// What the agent wants to do
    let action: String
    /// Why this action requires approval
    let reason: String
    /// Risk level of the action
    let riskLevel: EngineApprovalRiskLevel
}

/// The user's decision on an engine-owned approval request.
enum EngineApprovalUserDecision: String, Codable, Equatable {
    case approved = "Approved"
    case denied = "Denied"
}

/// Render state for an engine approval chip.
enum EngineApprovalChipStatus: Equatable {
    /// Awaiting user response; the approval chip is actionable.
    case pending
    /// User approved the action.
    case approved
    /// User denied the action.
    case denied
    /// Engine attempted the approved action and recorded a failure.
    case failed
}

/// The complete local rendering result from a user approval decision.
struct EngineApprovalResult: Codable, Equatable {
    /// The user's decision
    let decision: EngineApprovalUserDecision
    /// Optional note from the user
    let note: String?
    /// ISO 8601 timestamp of when the result was submitted
    let submittedAt: String
}

/// Server-owned approval state rendered as an in-chat chip.
struct EngineApprovalToolData: Equatable {
    /// Stable UI identity derived from the engine approval id.
    let invocationId: String
    /// Engine approval id when this chip represents an approval primitive event.
    let engineApprovalId: String?
    /// Canonical engine function whose pending approval produced this chip.
    let engineFunctionId: String?
    var params: EngineApprovalParams
    /// Current status
    var status: EngineApprovalChipStatus
    /// The user's decision (set when submitted)
    var decision: EngineApprovalUserDecision?
    /// Optional note from the user
    var note: String?
    /// Final result (set when submitted)
    var result: EngineApprovalResult?

    init(
        invocationId: String,
        params: EngineApprovalParams,
        status: EngineApprovalChipStatus,
        decision: EngineApprovalUserDecision? = nil,
        note: String? = nil,
        result: EngineApprovalResult? = nil,
        engineApprovalId: String? = nil,
        engineFunctionId: String? = nil
    ) {
        self.invocationId = invocationId
        self.engineApprovalId = engineApprovalId
        self.engineFunctionId = engineFunctionId
        self.params = params
        self.status = status
        self.decision = decision
        self.note = note
        self.result = result
    }
}
