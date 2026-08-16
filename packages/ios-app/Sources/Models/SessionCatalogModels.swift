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
    let messageCount: Int
    let firstMessage: String
    let phase: SessionPhase
    let summaryRevision: Int?

    init(
        id: String, name: String?, cwd: String, kind: Kind = .user, parentSessionId: String?,
        createdAt: String, updatedAt: String, messageCount: Int,
        firstMessage: String, phase: SessionPhase, summaryRevision: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.kind = kind
        self.parentSessionId = parentSessionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.firstMessage = firstMessage
        self.phase = phase
        self.summaryRevision = summaryRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, cwd, kind, parentSessionId, createdAt, updatedAt, messageCount, firstMessage, phase, summaryRevision
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
        messageCount = try container.decode(Int.self, forKey: .messageCount)
        firstMessage = try container.decode(String.self, forKey: .firstMessage)
        phase = try container.decode(SessionPhase.self, forKey: .phase)
        summaryRevision = try container.decodeIfPresent(Int.self, forKey: .summaryRevision)
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
}

struct SessionSummaryUpdate: Codable, Hashable, Sendable {
    let sessionId: String
    let summaryRevision: Int
    let phase: SessionPhase
    let name: String?
    let updatedAt: String
    let messageCount: Int
    let firstMessage: String
}
