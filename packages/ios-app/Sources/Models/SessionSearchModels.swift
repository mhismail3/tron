import Foundation
import TronMobileCore

struct SessionSearchAnchorRevision: Codable, Hashable, Sendable {
    let indexRevision: String
    let fileIdentity: String
    let branchDigest: String
    let leafEntryId: String?
    let entryOrdinal: Int
    let forkBoundary: SessionSearchForkBoundary?
}

struct SessionSearchForkBoundary: Codable, Hashable, Sendable {
    let kind: String
    let inheritedEntryId: String
    let gapOrdinal: Int
}

struct SessionSearchResult: Codable, Hashable, Sendable, Identifiable {
    let sessionId: String
    let gatewayProfileID: String?
    /// The owning Gateway's archive projection for this session, read from its
    /// archive store when the search response is built. It is never part of the
    /// index, so archiving changes no indexed text. A Gateway without
    /// `session-archive.v1` omits it, like every other additive row field.
    let archived: Bool
    let title: String
    let cwd: String
    let updatedAt: String
    let entryId: String
    let parentEntryId: String?
    let ordinal: Int
    let passageKind: String
    let snippet: String
    let lexicalScore: Double
    let semanticScore: Double?
    let jevScore: Double?
    let anchorRevision: SessionSearchAnchorRevision
    var id: String { "\(gatewayProfileID ?? "unknown"):\(sessionId):\(entryId)" }

    init(
        sessionId: String,
        gatewayProfileID: String?,
        archived: Bool = false,
        title: String,
        cwd: String,
        updatedAt: String,
        entryId: String,
        parentEntryId: String?,
        ordinal: Int,
        passageKind: String,
        snippet: String,
        lexicalScore: Double,
        semanticScore: Double?,
        jevScore: Double?,
        anchorRevision: SessionSearchAnchorRevision
    ) {
        self.sessionId = sessionId
        self.gatewayProfileID = gatewayProfileID
        self.archived = archived
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.entryId = entryId
        self.parentEntryId = parentEntryId
        self.ordinal = ordinal
        self.passageKind = passageKind
        self.snippet = snippet
        self.lexicalScore = lexicalScore
        self.semanticScore = semanticScore
        self.jevScore = jevScore
        self.anchorRevision = anchorRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        gatewayProfileID = try container.decodeIfPresent(String.self, forKey: .gatewayProfileID)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        entryId = try container.decode(String.self, forKey: .entryId)
        parentEntryId = try container.decodeIfPresent(String.self, forKey: .parentEntryId)
        ordinal = try container.decode(Int.self, forKey: .ordinal)
        passageKind = try container.decode(String.self, forKey: .passageKind)
        snippet = try container.decode(String.self, forKey: .snippet)
        lexicalScore = try container.decode(Double.self, forKey: .lexicalScore)
        semanticScore = try container.decodeIfPresent(Double.self, forKey: .semanticScore)
        jevScore = try container.decodeIfPresent(Double.self, forKey: .jevScore)
        anchorRevision = try container.decode(SessionSearchAnchorRevision.self, forKey: .anchorRevision)
    }
}

struct SessionSearchProfileTarget: Sendable, Hashable {
    let profileID: String
    let label: String
    let capabilities: Set<String>
    let isSelected: Bool

    init(profileID: String, label: String, capabilities: Set<String> = [], isSelected: Bool = false) {
        self.profileID = profileID
        self.label = label
        self.capabilities = capabilities
        self.isSelected = isSelected
    }
}

struct SessionSearchProfileStatus: Identifiable, Sendable {
    let profileID: String
    let label: String
    let state: String
    let response: SessionSearchResponse?
    let message: String?
    var id: String { profileID }
}

struct SessionSearchSessionGroup: Identifiable, Sendable {
    let profileID: String
    let profileLabel: String
    let sessionId: String
    let title: String
    let cwd: String
    let updatedAt: String
    let passages: [SessionSearchResult]
    let isLocalMatch: Bool
    var id: String { "\(profileID):\(sessionId)" }

    /// Every passage of a session carries the same Gateway archive projection,
    /// so the group label is the row's own state rather than a second read. A
    /// group assembled without passages cannot claim one.
    var isArchived: Bool { passages.contains(where: \.archived) }
}

struct SessionSearchAggregate: Sendable {
    let groups: [SessionSearchSessionGroup]
    let profiles: [SessionSearchProfileStatus]
}

enum SessionSearchNavigationAdmission {
    static func admits(
        result: SessionSearchResult,
        anchor: SessionSearchAnchorResponse,
        expectedProfileID: String,
        currentProfileID: String,
        expectedGeneration: Int,
        currentGeneration: Int,
        expectedRuntimeGeneration: String?,
        currentRuntimeGeneration: String?,
        expectedLeafEntryID: String?
    ) -> Bool {
        result.gatewayProfileID == expectedProfileID
            && expectedProfileID == currentProfileID
            && expectedGeneration == currentGeneration
            && (expectedRuntimeGeneration == nil || anchor.runtimeGeneration == expectedRuntimeGeneration)
            && (currentRuntimeGeneration == nil || anchor.runtimeGeneration == currentRuntimeGeneration)
            && anchor.sessionId == result.sessionId
            && anchor.entryId == result.entryId
            && anchor.items.contains(where: { $0.id == result.entryId })
            && (anchor.targetOrdinal == nil || (anchor.start..<anchor.end).contains(anchor.targetOrdinal!))
            && (expectedLeafEntryID == nil || anchor.leafEntryId == expectedLeafEntryID)
    }
}

enum SessionSearchGrouping {
    static func merge(local: [SessionSearchSessionGroup], remote: [SessionSearchSessionGroup]) -> [SessionSearchSessionGroup] {
        var merged = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for group in remote {
            if let existing = merged[group.id] {
                merged[group.id] = SessionSearchSessionGroup(profileID: group.profileID, profileLabel: group.profileLabel, sessionId: group.sessionId, title: group.title, cwd: group.cwd, updatedAt: group.updatedAt, passages: group.passages, isLocalMatch: existing.isLocalMatch)
            } else { merged[group.id] = group }
        }
        return merged.values.sorted { left, right in
            left.updatedAt != right.updatedAt ? left.updatedAt > right.updatedAt : (left.profileID, left.sessionId) < (right.profileID, right.sessionId)
        }
    }
}

struct SessionSearchResponse: Codable, Sendable {
    let query: String
    let queryRevision: String
    let corpusRevision: String
    let indexRevision: String
    let coverage: Coverage
    let semantic: Semantic
    let ranking: Ranking
    let results: [SessionSearchResult]

    struct Coverage: Codable, Sendable {
        let state: String
        let sessionsIndexed: Int
        let sessionsTotal: Int
        let passagesIndexed: Int
        let omittedSessions: Int
        let reason: String?
    }
    struct Semantic: Codable, Sendable {
        let state: String
        let modelRevision: String?
        let language: String?
        let dimension: Int?
        let vectorsIndexed: Int
        let vectorsTotal: Int
        let reason: String?
    }
    struct Ranking: Codable, Sendable {
        let state: String
        let jev: String?
    }
}

struct SessionSearchPolicy: Codable, Sendable {
    let enabled: Bool
    let perQueryMicroCents: Int
    let dailyMicroCents: Int
    let policyRevision: Int
}

struct SessionSearchRequest: Codable, Sendable {
    let query: String
    let scope: String
    let maxResults: Int?
    let remoteRanking: Bool
}

struct SessionSearchAnchorRequest: Codable, Sendable {
    let sessionId: String
    let entryId: String
    let anchorRevision: SessionSearchAnchorRevision
    let before: Int?
    let expectedRuntimeGeneration: String?
    let expectedLeafEntryId: String?
}

struct SessionSearchAnchorResponse: Codable, Sendable {
    let sessionId: String
    let entryId: String
    let start: Int
    let end: Int
    let total: Int
    let items: [TranscriptItem]
    let runtimeGeneration: String?
    let leafEntryId: String?
    let targetOrdinal: Int?
    let hasEarlier: Bool?
    let hasLater: Bool?

    init(sessionId: String, entryId: String, start: Int, end: Int, total: Int, items: [TranscriptItem], runtimeGeneration: String? = nil, leafEntryId: String? = nil, targetOrdinal: Int? = nil, hasEarlier: Bool? = nil, hasLater: Bool? = nil) {
        self.sessionId = sessionId; self.entryId = entryId; self.start = start; self.end = end; self.total = total; self.items = items
        self.runtimeGeneration = runtimeGeneration; self.leafEntryId = leafEntryId; self.targetOrdinal = targetOrdinal; self.hasEarlier = hasEarlier; self.hasLater = hasLater
    }
}
