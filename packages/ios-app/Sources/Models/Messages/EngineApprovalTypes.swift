import Foundation

// MARK: - Engine Approval Types

/// Risk level for an engine-owned approval request.
enum EngineApprovalRiskLevel: String, Codable, Equatable {
    case low
    case medium
    case high
    case critical

    init(serverValue: String?) {
        switch serverValue?.lowercased().filter(\.isLetter) {
        case "low": self = .low
        case "medium": self = .medium
        case "critical": self = .critical
        case "high": fallthrough
        default: self = .high
        }
    }
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
    /// User submitted a decision and the engine is resolving it.
    case resolving
    /// The engine accepted approval for the action.
    case approved
    /// The engine accepted denial for the action.
    case denied
    /// Engine attempted the approved action and recorded a failure.
    case failed

    var allowsDecision: Bool {
        self == .pending
    }

    var isReadOnly: Bool {
        self != .pending
    }

    var isViewable: Bool {
        self != .failed
    }
}

/// The complete rendering result from a server-accepted approval decision.
struct EngineApprovalResult: Codable, Equatable {
    /// The accepted decision.
    let decision: EngineApprovalUserDecision
    /// Optional note from the user.
    let note: String?
    /// ISO 8601 timestamp from the server-owned state transition.
    let submittedAt: String
}

struct EngineApprovalConsequenceRow: Equatable {
    let label: String
    let value: String
}

struct EngineApprovalConsequenceSection: Equatable {
    let title: String
    let rows: [EngineApprovalConsequenceRow]
}

/// Server-owned approval state rendered as an in-chat chip.
struct EngineApprovalData: Equatable {
    /// Stable UI identity derived from the engine approval id.
    let invocationId: String
    /// Engine approval id when this chip represents an approval primitive event.
    let engineApprovalId: String?
    /// Canonical engine function whose pending approval produced this chip.
    let engineFunctionId: String?
    /// Authority grant preserved by the server approval record.
    let authorityGrantId: String?
    /// Original authority scopes preserved by the server approval record.
    let authorityScopes: [String]
    /// Original idempotency key preserved by the server approval record.
    let idempotencyKey: String?
    /// Target contract metadata snapshotted by the server approval record.
    let targetMetadata: EngineApprovalTargetMetadataDTO?
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
        engineFunctionId: String? = nil,
        authorityGrantId: String? = nil,
        authorityScopes: [String] = [],
        idempotencyKey: String? = nil,
        targetMetadata: EngineApprovalTargetMetadataDTO? = nil
    ) {
        self.invocationId = invocationId
        self.engineApprovalId = engineApprovalId
        self.engineFunctionId = engineFunctionId
        self.authorityGrantId = authorityGrantId
        self.authorityScopes = authorityScopes
        self.idempotencyKey = idempotencyKey
        self.targetMetadata = targetMetadata
        self.params = params
        self.status = status
        self.decision = decision
        self.note = note
        self.result = result
    }
}

extension EngineApprovalData {
    var consequenceSections: [EngineApprovalConsequenceSection] {
        var sections: [EngineApprovalConsequenceSection] = []

        if let targetMetadata {
            sections.append(EngineApprovalConsequenceSection(
                title: "Consequence",
                rows: [
                    EngineApprovalConsequenceRow(label: "Effect", value: prettyEngineToken(targetMetadata.effectClass)),
                    EngineApprovalConsequenceRow(label: "Risk", value: prettyEngineToken(targetMetadata.riskLevel)),
                    EngineApprovalConsequenceRow(
                        label: "Approval",
                        value: targetMetadata.requiredAuthority.approvalRequired ? "Required" : "Not required"
                    )
                ]
            ))
        }

        let requiredScopes = targetMetadata?.requiredAuthority.scopes ?? []
        let authorityRows = [
            authorityGrantId.map { EngineApprovalConsequenceRow(label: "Grant", value: $0) },
            authorityScopes.nonEmptyJoined.map { EngineApprovalConsequenceRow(label: "Caller scopes", value: $0) },
            requiredScopes.nonEmptyJoined.map { EngineApprovalConsequenceRow(label: "Required scopes", value: $0) }
        ].compactMap { $0 }
        if !authorityRows.isEmpty {
            sections.append(EngineApprovalConsequenceSection(title: "Authority", rows: authorityRows))
        }

        let idempotencyRows = [
            idempotencyKey.map { EngineApprovalConsequenceRow(label: "Key", value: $0) },
            targetMetadata?.idempotency.map {
                EngineApprovalConsequenceRow(
                    label: "Contract",
                    value: [
                        prettyEngineToken($0.keySource),
                        prettyEngineToken($0.dedupeScope),
                        prettyEngineToken($0.replayBehavior),
                        prettyEngineToken($0.ledgerKind)
                    ].joined(separator: " / ")
                )
            }
        ].compactMap { $0 }
        if !idempotencyRows.isEmpty {
            sections.append(EngineApprovalConsequenceSection(title: "Idempotency", rows: idempotencyRows))
        }

        if let lease = targetMetadata?.resourceLease {
            sections.append(EngineApprovalConsequenceSection(
                title: "Lease",
                rows: [
                    EngineApprovalConsequenceRow(label: "Resource", value: "\(lease.resourceKind): \(lease.resourceIdTemplate)"),
                    EngineApprovalConsequenceRow(label: "TTL", value: "\(lease.ttlMs) ms"),
                    EngineApprovalConsequenceRow(label: "Failure", value: prettyEngineToken(lease.failureBehavior))
                ]
            ))
        }

        if let compensation = targetMetadata?.compensation {
            sections.append(EngineApprovalConsequenceSection(
                title: "Compensation",
                rows: [
                    EngineApprovalConsequenceRow(label: "Kind", value: prettyEngineToken(compensation.kind)),
                    EngineApprovalConsequenceRow(label: "Notes", value: compensation.notes)
                ]
            ))
        }

        return sections
    }
}

private extension Array where Element == String {
    var nonEmptyJoined: String? {
        let values = filter { !$0.isEmpty }
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }
}

private func prettyEngineToken(_ value: String) -> String {
    let spaced = value.reduce(into: "") { output, character in
        if character == "_" || character == "-" {
            output.append(" ")
        } else {
            if character.isUppercase, output.last?.isLetter == true {
                output.append(" ")
            }
            output.append(character)
        }
    }
    return spaced
        .split(separator: " ")
        .map { word in
            word.prefix(1).uppercased() + String(word.dropFirst())
        }
        .joined(separator: " ")
}
