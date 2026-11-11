import Foundation

extension SessionPhase {
    package var isActive: Bool { self == .running || self == .compacting || self == .retrying }
}

extension SessionCreationOrigin {
    package var valid: Bool {
        let normalized = automationId.lowercased()
        let versionIndex = normalized.index(normalized.startIndex, offsetBy: 14, limitedBy: normalized.endIndex)
        let variantIndex = normalized.index(normalized.startIndex, offsetBy: 19, limitedBy: normalized.endIndex)
        guard let uuid = UUID(uuidString: automationId),
              uuid.uuidString.lowercased() == normalized,
              let versionIndex, "12345".contains(normalized[versionIndex]),
              let variantIndex, "89ab".contains(normalized[variantIndex]) else { return false }
        return true
    }
}

package enum SessionArchiveCapability {
    package static let name = "session-archive.v1"
}

package struct SessionArchiveState: Codable, Sendable {
    package let archived: Bool
    package let archivedAt: String?
}

extension SessionSummary {
    package var admitted: Bool {
        !id.isEmpty && completionRevision >= 0 && attentionRevision >= 0 && (creationOrigin?.valid ?? true)
    }


    package var isArchived: Bool { archivedAt != nil }

    package var hasOnlyActiveSubagents: Bool {
        phase.isActive && hasActiveSubagents && foregroundPhase == .idle
    }

    package var isFork: Bool { parentSessionId != nil }
    package var isAutomationCreated: Bool { creationOrigin?.kind == .automation }
    package var isHomeWorker: Bool { homeTaskId != nil }

    package var title: String {
        if let name, !name.isEmpty { return name }
        let first = firstMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return first.isEmpty ? "New session" : String(first.prefix(80))
    }

    package var workspaceName: String {
        URL(fileURLWithPath: cwd).lastPathComponent.isEmpty ? cwd : URL(fileURLWithPath: cwd).lastPathComponent
    }

}

extension SessionListPage {
    package static func validated(_ value: WireJSON, _ path: String) throws -> SessionListPage {
        guard case .object(let object) = value, case .array? = object.value("sessions") else {
            throw WireError(path: "\(path).sessions", message: "a session list page without its sessions")
        }
        let page = try decode(value, path)
        for (index, session) in page.sessions.enumerated() where !session.admitted {
            throw WireError(path: "\(path).sessions[\(index)]", message: "an empty id, a negative revision or an invalid creation Automation identity")
        }
        return page
    }
}

@dynamicMemberLookup
package struct CatalogSession: Hashable, Identifiable, Sendable {
    package let summary: SessionSummary
    package let gatewayProfileID: String?
    package let gatewayProfileLabel: String?

    package init(_ summary: SessionSummary, gatewayProfileID: String? = nil, gatewayProfileLabel: String? = nil) {
        self.summary = summary
        self.gatewayProfileID = gatewayProfileID
        self.gatewayProfileLabel = gatewayProfileLabel
    }

    package subscript<Value>(dynamicMember keyPath: KeyPath<SessionSummary, Value>) -> Value {
        summary[keyPath: keyPath]
    }

    package var id: String { summary.id }

    package func withGatewaySource(id profileID: String, label: String) -> CatalogSession {
        CatalogSession(summary, gatewayProfileID: profileID, gatewayProfileLabel: label)
    }

    package var dashboardID: String {
        gatewayProfileID.map { "\($0):\(id)" } ?? id
    }

    package static func dashboardSessions(_ sessions: [CatalogSession]) -> [CatalogSession] {
        sessions.filter { $0.kind == .user }
    }

    package static func orderedForDashboard(_ sessions: [CatalogSession]) -> [CatalogSession] {
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

extension SessionSummaryUpdate {
    package var admitted: Bool { !sessionId.isEmpty && completionRevision >= 0 && attentionRevision >= 0 }
}
