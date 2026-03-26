import Foundation

// MARK: - GetConfirmation Types

/// Risk level for a confirmation request
enum ConfirmationRiskLevel: String, Codable, Equatable {
    case low
    case medium
    case high
}

/// Parameters for the GetConfirmation tool call
struct GetConfirmationParams: Codable, Equatable {
    /// What the agent wants to do
    let action: String
    /// Why this action requires approval
    let reason: String
    /// Risk level of the action
    let riskLevel: ConfirmationRiskLevel
}

/// The user's decision on a confirmation request
enum ConfirmationDecision: String, Codable, Equatable {
    case approved = "Approved"
    case denied = "Denied"
}

/// Status for GetConfirmation in async mode
enum GetConfirmationStatus: Equatable {
    /// Tool arguments still streaming — chip shows spinner
    case generating
    /// Awaiting user response - the confirmation chip is actionable
    case pending
    /// User approved the action
    case approved
    /// User denied the action
    case denied
    /// User sent a different message - chip is disabled (skipped)
    case superseded
}

/// The complete result from the GetConfirmation tool
struct GetConfirmationResult: Codable, Equatable {
    /// The user's decision
    let decision: ConfirmationDecision
    /// Optional note from the user
    let note: String?
    /// ISO 8601 timestamp of when the result was submitted
    let submittedAt: String
}

/// Tool data for GetConfirmation tracking (in-chat state)
struct GetConfirmationToolData: Equatable {
    /// The tool call ID from the agent
    let toolCallId: String
    /// The confirmation parameters (set to placeholder during .generating, updated on tool_start)
    var params: GetConfirmationParams
    /// Current status
    var status: GetConfirmationStatus
    /// The user's decision (set when submitted)
    var decision: ConfirmationDecision?
    /// Optional note from the user
    var note: String?
    /// Final result (set when submitted)
    var result: GetConfirmationResult?
}
