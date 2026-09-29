import Foundation

package enum SessionPhase: String, Codable, Hashable, Sendable {
    case idle, running, compacting, retrying, interrupted

    package var isActive: Bool { self == .running || self == .compacting || self == .retrying }
}

package struct SessionCreationOrigin: Codable, Hashable, Sendable {
    package enum Kind: String, Codable, Hashable, Sendable { case automation }

    package let kind: Kind
    package let automationId: String

    package init(kind: Kind, automationId: String) {
        self.kind = kind
        self.automationId = automationId
    }

    private enum CodingKeys: String, CodingKey { case kind, automationId }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(Kind.self, forKey: .kind)
        automationId = try container.decode(String.self, forKey: .automationId)
        let normalized = automationId.lowercased()
        let versionIndex = normalized.index(normalized.startIndex, offsetBy: 14, limitedBy: normalized.endIndex)
        let variantIndex = normalized.index(normalized.startIndex, offsetBy: 19, limitedBy: normalized.endIndex)
        guard let uuid = UUID(uuidString: automationId),
              uuid.uuidString.lowercased() == normalized,
              let versionIndex, "12345".contains(normalized[versionIndex]),
              let variantIndex, "89ab".contains(normalized[variantIndex]) else {
            throw DecodingError.dataCorruptedError(
                forKey: .automationId,
                in: container,
                debugDescription: "Session creation Automation identity is invalid"
            )
        }
    }
}

/// Gateway contract that owns archived-session display state. Archive controls
/// stay hidden for a profile that does not advertise it.
package enum SessionArchiveCapability {
    package static let name = "session-archive.v1"
}

/// Authoritative `session.archive.set` response. Archive membership is
/// Gateway-owned display state; iOS never derives it from a local row.
package struct SessionArchiveState: Codable, Sendable {
    package let archived: Bool
    package let archivedAt: String?
}

package struct SessionSummary: Codable, Hashable, Identifiable, Sendable {
    package enum Kind: String, Codable, Hashable, Sendable { case user, subagent }

    package let id: String
    package let name: String?
    package let cwd: String
    package let kind: Kind
    package let parentSessionId: String?
    package let creationOrigin: SessionCreationOrigin?
    package let createdAt: String
    package let updatedAt: String
    /// Stable Gateway-observed start of the current active dashboard period.
    package let activeSince: String?
    package let messageCount: Int
    package let firstMessage: String
    package let phase: SessionPhase
    /// Narrow foreground phase. A settled value while `phase` remains active
    /// means detached subagents are the only remaining dashboard work.
    package let foregroundPhase: SessionPhase?
    package let hasActiveSubagents: Bool
    /// Gateway truth that a semantic interaction is awaiting a user response.
    package let waitingForUser: Bool
    package let summaryRevision: Int?
    package let completionRevision: Int
    package let attentionRevision: Int
    package let isUnread: Bool
    /// Set only on a row from the Gateway's `archived: "only"` projection. The
    /// dashboard's default list projection omits archived sessions entirely, so
    /// a row carrying this field can never come from the dashboard read.
    package let archivedAt: String?
    /// Dashboard-only ownership metadata. Gateway payloads omit these fields.
    package let gatewayProfileID: String?
    package let gatewayProfileLabel: String?

    package init(
        id: String, name: String?, cwd: String, kind: Kind = .user, parentSessionId: String?,
        creationOrigin: SessionCreationOrigin? = nil,
        createdAt: String, updatedAt: String, activeSince: String? = nil, messageCount: Int,
        firstMessage: String, phase: SessionPhase, foregroundPhase: SessionPhase? = nil,
        hasActiveSubagents: Bool = false, waitingForUser: Bool = false,
        summaryRevision: Int? = nil, completionRevision: Int = 0,
        attentionRevision: Int = 0, isUnread: Bool = false, archivedAt: String? = nil,
        gatewayProfileID: String? = nil, gatewayProfileLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.parentSessionId = parentSessionId
        self.creationOrigin = creationOrigin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.activeSince = activeSince
        self.messageCount = messageCount
        self.firstMessage = firstMessage
        self.phase = phase
        self.foregroundPhase = foregroundPhase
        self.hasActiveSubagents = hasActiveSubagents
        self.waitingForUser = waitingForUser
        self.summaryRevision = summaryRevision
        self.completionRevision = completionRevision
        self.attentionRevision = attentionRevision
        self.isUnread = isUnread
        self.archivedAt = archivedAt
        self.gatewayProfileID = gatewayProfileID
        self.gatewayProfileLabel = gatewayProfileLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, kind, parentSessionId, creationOrigin, createdAt, updatedAt, activeSince, messageCount, firstMessage, phase, foregroundPhase, hasActiveSubagents, waitingForUser, summaryRevision
        case completionRevision, attentionRevision, isUnread, archivedAt
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decode(String.self, forKey: .cwd)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .user
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
        creationOrigin = try container.decodeIfPresent(SessionCreationOrigin.self, forKey: .creationOrigin)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        activeSince = try container.decodeIfPresent(String.self, forKey: .activeSince)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        firstMessage = try container.decode(String.self, forKey: .firstMessage)
        phase = try container.decode(SessionPhase.self, forKey: .phase)
        foregroundPhase = try container.decodeIfPresent(SessionPhase.self, forKey: .foregroundPhase)
        hasActiveSubagents = try container.decodeIfPresent(Bool.self, forKey: .hasActiveSubagents) ?? false
        waitingForUser = try container.decodeIfPresent(Bool.self, forKey: .waitingForUser) ?? false
        summaryRevision = try container.decodeIfPresent(Int.self, forKey: .summaryRevision)
        let decodedCompletionRevision = try container.decodeIfPresent(Int.self, forKey: .completionRevision) ?? 0
        let decodedAttentionRevision = try container.decodeIfPresent(Int.self, forKey: .attentionRevision) ?? 0
        guard decodedCompletionRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .completionRevision, in: container, debugDescription: "Invalid completion revision")
        }
        guard decodedAttentionRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .attentionRevision, in: container, debugDescription: "Invalid attention revision")
        }
        completionRevision = decodedCompletionRevision
        attentionRevision = decodedAttentionRevision
        isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
        archivedAt = try container.decodeIfPresent(String.self, forKey: .archivedAt)
        gatewayProfileID = nil
        gatewayProfileLabel = nil
    }

    package func withGatewaySource(id profileID: String, label: String) -> SessionSummary {
        SessionSummary(
            id: id,
            name: name,
            cwd: cwd,
            kind: kind,
            parentSessionId: parentSessionId,
            creationOrigin: creationOrigin,
            createdAt: createdAt,
            updatedAt: updatedAt,
            activeSince: activeSince,
            messageCount: messageCount,
            firstMessage: firstMessage,
            phase: phase,
            foregroundPhase: foregroundPhase,
            hasActiveSubagents: hasActiveSubagents,
            waitingForUser: waitingForUser,
            summaryRevision: summaryRevision,
            completionRevision: completionRevision,
            attentionRevision: attentionRevision,
            isUnread: isUnread,
            archivedAt: archivedAt,
            gatewayProfileID: profileID,
            gatewayProfileLabel: label
        )
    }

    package var isArchived: Bool { archivedAt != nil }

    package var dashboardID: String {
        gatewayProfileID.map { "\($0):\(id)" } ?? id
    }

    package var hasOnlyActiveSubagents: Bool {
        phase.isActive && hasActiveSubagents && foregroundPhase == .idle
    }

    package var isFork: Bool { parentSessionId != nil }
    package var isAutomationCreated: Bool { creationOrigin?.kind == .automation }

    package var title: String {
        if let name, !name.isEmpty { return name }
        let first = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty ? "New session" : String(first.prefix(80))
    }

    package var workspaceName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    package static func dashboardSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.filter { $0.kind == .user }
    }

    package static func orderedForDashboard(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions
            .map { summary in
                let orderingTimestamp = summary.phase.isActive ? summary.activeSince : summary.updatedAt
                return (
                    summary: summary,
                    active: summary.phase.isActive,
                    instant: orderingTimestamp.flatMap(GatewayTimestamp.parse)
                )
            }
            .sorted { left, right in
                if left.active != right.active { return left.active }
                switch (left.instant, right.instant) {
                case let (leftDate?, rightDate?) where leftDate != rightDate:
                    return leftDate > rightDate
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    // Identity deterministically resolves equivalent or invalid
                    // instants. Older Gateways omit activeSince, so this also
                    // keeps their active rows stable as live updatedAt advances.
                    return left.summary.dashboardID < right.summary.dashboardID
                }
            }
            .map(\.summary)
    }
}

package struct SessionAttentionProjection: Codable, Hashable, Sendable {
    package let completionRevision: Int
    package let attentionRevision: Int
    package let isUnread: Bool

    package init(completionRevision: Int, attentionRevision: Int, isUnread: Bool) {
        self.completionRevision = completionRevision
        self.attentionRevision = attentionRevision
        self.isUnread = isUnread
    }

    private enum CodingKeys: String, CodingKey {
        case completionRevision, attentionRevision, isUnread
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let completion = try container.decode(Int.self, forKey: .completionRevision)
        let attention = try container.decode(Int.self, forKey: .attentionRevision)
        guard completion >= 0, attention >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: completion < 0 ? .completionRevision : .attentionRevision,
                in: container,
                debugDescription: "Invalid attention projection revision"
            )
        }
        completionRevision = completion
        attentionRevision = attention
        isUnread = try container.decode(Bool.self, forKey: .isUnread)
    }
}

package struct SessionSummaryUpdate: Codable, Hashable, Sendable {
    package let sessionId: String
    package let summaryRevision: Int
    package let phase: SessionPhase
    package let foregroundPhase: SessionPhase?
    package let hasActiveSubagents: Bool
    /// Gateway truth that a semantic interaction is awaiting a user response.
    package let waitingForUser: Bool
    package let name: String?
    package let updatedAt: String
    package let activeSince: String?
    package let messageCount: Int
    package let firstMessage: String
    package let completionRevision: Int
    package let attentionRevision: Int
    package let isUnread: Bool

    package init(
        sessionId: String, summaryRevision: Int, phase: SessionPhase,
        foregroundPhase: SessionPhase? = nil, hasActiveSubagents: Bool = false,
        waitingForUser: Bool = false, name: String?, updatedAt: String, activeSince: String? = nil,
        messageCount: Int, firstMessage: String,
        completionRevision: Int = 0, attentionRevision: Int = 0, isUnread: Bool = false
    ) {
        self.sessionId = sessionId
        self.summaryRevision = summaryRevision
        self.phase = phase
        self.foregroundPhase = foregroundPhase
        self.hasActiveSubagents = hasActiveSubagents
        self.waitingForUser = waitingForUser
        self.name = name
        self.updatedAt = updatedAt
        self.activeSince = activeSince
        self.messageCount = messageCount
        self.firstMessage = firstMessage
        self.completionRevision = completionRevision
        self.attentionRevision = attentionRevision
        self.isUnread = isUnread
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, summaryRevision, phase, foregroundPhase, hasActiveSubagents, waitingForUser, name, updatedAt, activeSince, messageCount, firstMessage
        case completionRevision, attentionRevision, isUnread
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        summaryRevision = try container.decode(Int.self, forKey: .summaryRevision)
        phase = try container.decode(SessionPhase.self, forKey: .phase)
        foregroundPhase = try container.decodeIfPresent(SessionPhase.self, forKey: .foregroundPhase)
        hasActiveSubagents = try container.decodeIfPresent(Bool.self, forKey: .hasActiveSubagents) ?? false
        waitingForUser = try container.decodeIfPresent(Bool.self, forKey: .waitingForUser) ?? false
        name = try container.decodeIfPresent(String.self, forKey: .name)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        activeSince = try container.decodeIfPresent(String.self, forKey: .activeSince)
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        firstMessage = try container.decode(String.self, forKey: .firstMessage)
        let decodedCompletionRevision = try container.decodeIfPresent(Int.self, forKey: .completionRevision) ?? 0
        let decodedAttentionRevision = try container.decodeIfPresent(Int.self, forKey: .attentionRevision) ?? 0
        guard decodedCompletionRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .completionRevision, in: container, debugDescription: "Invalid completion revision")
        }
        guard decodedAttentionRevision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .attentionRevision, in: container, debugDescription: "Invalid attention revision")
        }
        completionRevision = decodedCompletionRevision
        attentionRevision = decodedAttentionRevision
        isUnread = try container.decodeIfPresent(Bool.self, forKey: .isUnread) ?? false
    }
}
