import Foundation

enum SessionPhase: String, Codable, Hashable, Sendable {
    case idle, running, compacting, retrying, interrupted

    var isActive: Bool { self == .running || self == .compacting || self == .retrying }
}

struct SessionSummary: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable { case user, subagent }

    let id: String
    let name: String?
    let cwd: String
    let kind: Kind
    let parentSessionId: String?
    let createdAt: String
    let updatedAt: String
    /// Stable Gateway-observed start of the current active dashboard period.
    let activeSince: String?
    let messageCount: Int
    let firstMessage: String
    let phase: SessionPhase
    /// Narrow foreground phase. A settled value while `phase` remains active
    /// means detached subagents are the only remaining dashboard work.
    let foregroundPhase: SessionPhase?
    let hasActiveSubagents: Bool
    /// Gateway truth that a semantic interaction is awaiting a user response.
    let waitingForUser: Bool
    let summaryRevision: Int?
    let completionRevision: Int
    let attentionRevision: Int
    let isUnread: Bool
    /// Dashboard-only ownership metadata. Gateway payloads omit these fields.
    let gatewayProfileID: String?
    let gatewayProfileLabel: String?

    init(
        id: String, name: String?, cwd: String, kind: Kind = .user, parentSessionId: String?,
        createdAt: String, updatedAt: String, activeSince: String? = nil, messageCount: Int,
        firstMessage: String, phase: SessionPhase, foregroundPhase: SessionPhase? = nil,
        hasActiveSubagents: Bool = false, waitingForUser: Bool = false,
        summaryRevision: Int? = nil, completionRevision: Int = 0,
        attentionRevision: Int = 0, isUnread: Bool = false,
        gatewayProfileID: String? = nil, gatewayProfileLabel: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.parentSessionId = parentSessionId
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
        self.gatewayProfileID = gatewayProfileID
        self.gatewayProfileLabel = gatewayProfileLabel
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, kind, parentSessionId, createdAt, updatedAt, activeSince, messageCount, firstMessage, phase, foregroundPhase, hasActiveSubagents, waitingForUser, summaryRevision
        case completionRevision, attentionRevision, isUnread
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        cwd = try container.decode(String.self, forKey: .cwd)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .user
        parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
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
        gatewayProfileID = nil
        gatewayProfileLabel = nil
    }

    func withGatewaySource(id profileID: String, label: String) -> SessionSummary {
        SessionSummary(
            id: id,
            name: name,
            cwd: cwd,
            kind: kind,
            parentSessionId: parentSessionId,
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
            gatewayProfileID: profileID,
            gatewayProfileLabel: label
        )
    }

    var dashboardID: String {
        gatewayProfileID.map { "\($0):\(id)" } ?? id
    }

    var hasOnlyActiveSubagents: Bool {
        phase.isActive && hasActiveSubagents && foregroundPhase == .idle
    }

    var title: String {
        if let name, !name.isEmpty { return name }
        let first = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty ? "New session" : String(first.prefix(80))
    }

    var workspaceName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

    func relativeActivityDescription(relativeTo now: Date = .now) -> String {
        GatewayTimestamp.relativeDescription(updatedAt, relativeTo: now)
    }

    static func dashboardSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        sessions.filter { $0.kind == .user }
    }

    static func orderedForDashboard(_ sessions: [SessionSummary]) -> [SessionSummary] {
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

struct SessionAttentionProjection: Codable, Hashable, Sendable {
    let completionRevision: Int
    let attentionRevision: Int
    let isUnread: Bool

    init(completionRevision: Int, attentionRevision: Int, isUnread: Bool) {
        self.completionRevision = completionRevision
        self.attentionRevision = attentionRevision
        self.isUnread = isUnread
    }

    private enum CodingKeys: String, CodingKey {
        case completionRevision, attentionRevision, isUnread
    }

    init(from decoder: Decoder) throws {
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

struct SessionSummaryUpdate: Codable, Hashable, Sendable {
    let sessionId: String
    let summaryRevision: Int
    let phase: SessionPhase
    let foregroundPhase: SessionPhase?
    let hasActiveSubagents: Bool
    /// Gateway truth that a semantic interaction is awaiting a user response.
    let waitingForUser: Bool
    let name: String?
    let updatedAt: String
    let activeSince: String?
    let messageCount: Int
    let firstMessage: String
    let completionRevision: Int
    let attentionRevision: Int
    let isUnread: Bool

    init(
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

    init(from decoder: Decoder) throws {
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
