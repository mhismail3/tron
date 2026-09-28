import Foundation
import TronMobileCore

package struct SessionSearchAnchorRevision: Codable, Hashable, Sendable {
    package let indexRevision: String
    package let fileIdentity: String
    package let branchDigest: String
    package let leafEntryId: String?
    package let entryOrdinal: Int
    package let forkBoundary: SessionSearchForkBoundary?
}

package struct SessionSearchForkBoundary: Codable, Hashable, Sendable {
    package let kind: String
    package let inheritedEntryId: String
    package let gapOrdinal: Int
}

package struct SessionSearchResult: Codable, Hashable, Sendable, Identifiable {
    package let sessionId: String
    package let gatewayProfileID: String?
    /// The owning Gateway's archive projection for this session, read from its
    /// archive store when the search response is built. It is never part of the
    /// index, so archiving changes no indexed text. A Gateway without
    /// `session-archive.v1` omits it, like every other additive row field.
    package let archived: Bool
    package let title: String
    package let cwd: String
    package let updatedAt: String
    package let entryId: String
    package let parentEntryId: String?
    package let ordinal: Int
    package let passageKind: String
    package let snippet: String
    package let lexicalScore: Double
    package let semanticScore: Double?
    package let jevScore: Double?
    package let anchorRevision: SessionSearchAnchorRevision
    package var id: String { "\(gatewayProfileID ?? "unknown"):\(sessionId):\(entryId)" }

    package init(
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

    package init(from decoder: Decoder) throws {
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

package struct SessionSearchProfileTarget: Sendable, Hashable {
    package let profileID: String
    package let label: String
    package let capabilities: Set<String>
    package let isSelected: Bool

    package init(profileID: String, label: String, capabilities: Set<String> = [], isSelected: Bool = false) {
        self.profileID = profileID
        self.label = label
        self.capabilities = capabilities
        self.isSelected = isSelected
    }
}

package struct SessionSearchProfileStatus: Identifiable, Sendable {
    package let profileID: String
    package let label: String
    package let state: String
    package let response: SessionSearchResponse?
    package let message: String?
    package var id: String { profileID }

    package init(profileID: String, label: String, state: String, response: SessionSearchResponse?, message: String?) {
        self.profileID = profileID
        self.label = label
        self.state = state
        self.response = response
        self.message = message
    }
}

package struct SessionSearchSessionGroup: Identifiable, Sendable {
    package let profileID: String
    package let profileLabel: String
    package let sessionId: String
    package let title: String
    package let cwd: String
    package let updatedAt: String
    package let passages: [SessionSearchResult]
    let isLocalMatch: Bool
    package var id: String { "\(profileID):\(sessionId)" }

    /// Every passage of a session carries the same Gateway archive projection,
    /// so the group label is the row's own state rather than a second read. A
    /// group assembled without passages cannot claim one.
    package var isArchived: Bool { passages.contains(where: \.archived) }

    package init(profileID: String, profileLabel: String, sessionId: String, title: String, cwd: String, updatedAt: String, passages: [SessionSearchResult], isLocalMatch: Bool) {
        self.profileID = profileID
        self.profileLabel = profileLabel
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.passages = passages
        self.isLocalMatch = isLocalMatch
    }
}

package struct SessionSearchAggregate: Sendable {
    package let groups: [SessionSearchSessionGroup]
    package let profiles: [SessionSearchProfileStatus]

    package init(groups: [SessionSearchSessionGroup], profiles: [SessionSearchProfileStatus]) {
        self.groups = groups
        self.profiles = profiles
    }
}

package enum SessionSearchNavigationAdmission {
    package static func admits(
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

package enum SessionSearchGrouping {
    package static func merge(local: [SessionSearchSessionGroup], remote: [SessionSearchSessionGroup]) -> [SessionSearchSessionGroup] {
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

package struct SessionSearchResponse: Codable, Sendable {
    package let query: String
    package let queryRevision: String
    package let corpusRevision: String
    package let indexRevision: String
    package let coverage: Coverage
    package let semantic: Semantic
    package let ranking: Ranking
    package let results: [SessionSearchResult]

    package struct Coverage: Codable, Sendable {
        package let state: String
        let sessionsIndexed: Int
        let sessionsTotal: Int
        let passagesIndexed: Int
        let omittedSessions: Int
        let reason: String?
    }
    package struct Semantic: Codable, Sendable {
        let state: String
        let modelRevision: String?
        let language: String?
        let dimension: Int?
        let vectorsIndexed: Int
        let vectorsTotal: Int
        let reason: String?
    }
    package struct Ranking: Codable, Sendable {
        package let state: String
        package let jev: String?
    }

    package init(query: String, queryRevision: String, corpusRevision: String, indexRevision: String, coverage: Coverage, semantic: Semantic, ranking: Ranking, results: [SessionSearchResult]) {
        self.query = query
        self.queryRevision = queryRevision
        self.corpusRevision = corpusRevision
        self.indexRevision = indexRevision
        self.coverage = coverage
        self.semantic = semantic
        self.ranking = ranking
        self.results = results
    }
}

package struct SessionSearchPolicy: Codable, Sendable {
    package let enabled: Bool
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

package struct SessionSearchAnchorResponse: Codable, Sendable {
    let sessionId: String
    package let entryId: String
    package let start: Int
    package let end: Int
    package let total: Int
    package let items: [TranscriptItem]
    package let runtimeGeneration: String?
    package let leafEntryId: String?
    package let targetOrdinal: Int?
    let hasEarlier: Bool?
    let hasLater: Bool?

    init(sessionId: String, entryId: String, start: Int, end: Int, total: Int, items: [TranscriptItem], runtimeGeneration: String? = nil, leafEntryId: String? = nil, targetOrdinal: Int? = nil, hasEarlier: Bool? = nil, hasLater: Bool? = nil) {
        self.sessionId = sessionId; self.entryId = entryId; self.start = start; self.end = end; self.total = total; self.items = items
        self.runtimeGeneration = runtimeGeneration; self.leafEntryId = leafEntryId; self.targetOrdinal = targetOrdinal; self.hasEarlier = hasEarlier; self.hasLater = hasLater
    }
}
