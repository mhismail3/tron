import Foundation

/// Admits only the latest asynchronous dashboard navigation intent.
struct DashboardNavigationOwner: Equatable {
    private var generation = 0

    mutating func begin() -> Int {
        generation &+= 1
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
    }

    mutating func admit(_ requestedGeneration: Int) -> Bool {
        guard requestedGeneration == generation else { return false }
        generation &+= 1
        return true
    }
}

enum SessionCatalogFreshness: Equatable, Sendable {
    case cached
    case stale
    case live
}

enum DashboardSessionActivity: Equatable, Sendable {
    case idle
    case active
    case resuming
    case interrupted
}

enum SessionCatalogRefreshOutcome: Equatable, Sendable {
    case published
    case retained
    case transportFailure
}

struct SessionCatalogLoadKey: Equatable, Sendable {
    let profileID: String
    let lifecycleGeneration: Int
    let connectionID: Int
}

/// Owns the bounded dashboard projection, revisioned global row overlays, and
/// exact admission for one catalog materialization. Gateway remains canonical.
struct SessionCatalogCoordinator: Equatable {
    struct LoadAdmission: Equatable, Sendable {
        fileprivate let generation: Int
        fileprivate let key: SessionCatalogLoadKey?
    }

    enum SummaryUpdateAdmission: Equatable, Sendable {
        case stale
        case unknownSession
        case updated
    }

    private(set) var sessions: [SessionSummary] = []
    private(set) var freshness: SessionCatalogFreshness = .stale
    private var indicesByID: [String: Int] = [:]
    private var liveUpdates: [String: SessionSummaryUpdate] = [:]
    private var liveSessionIDs: Set<String> = []
    private var loadGeneration = 0

    mutating func beginLoad(key: SessionCatalogLoadKey? = nil) -> LoadAdmission {
        loadGeneration &+= 1
        return LoadAdmission(generation: loadGeneration, key: key)
    }

    mutating func invalidateLoads() {
        loadGeneration &+= 1
    }

    func admits(_ admission: LoadAdmission, key: SessionCatalogLoadKey? = nil) -> Bool {
        admission.generation == loadGeneration
            && (key == nil || admission.key == key)
    }

    func activity(for sessionID: String) -> DashboardSessionActivity {
        guard let index = indicesByID[sessionID], sessions.indices.contains(index) else { return .idle }
        let phase = sessions[index].phase
        let isLive = freshness == .live || liveSessionIDs.contains(sessionID)
        guard isLive else {
            return phase == .idle ? .idle : .resuming
        }
        if phase.isActive { return .active }
        return phase == .interrupted ? .interrupted : .idle
    }

    @discardableResult
    mutating func publishAuthoritative(
        _ authoritative: [SessionSummary],
        admission: LoadAdmission
    ) -> Bool {
        guard admits(admission, key: admission.key) else { return false }
        let ids = Set(authoritative.map(\.id))
        liveUpdates = liveUpdates.filter { ids.contains($0.key) }
        sessions = authoritative.map { summary in
            guard let update = liveUpdates[summary.id],
                  update.summaryRevision > (summary.summaryRevision ?? 0) else { return summary }
            return applying(update, to: summary)
        }
        rebuildIndex()
        liveSessionIDs = ids
        freshness = .live
        return true
    }

    mutating func apply(_ update: SessionSummaryUpdate) -> SummaryUpdateAdmission {
        if let current = liveUpdates[update.sessionId],
           update.summaryRevision <= current.summaryRevision {
            return .stale
        }
        if let index = indicesByID[update.sessionId], sessions.indices.contains(index),
           update.summaryRevision <= (sessions[index].summaryRevision ?? 0) {
            return .stale
        }
        liveUpdates[update.sessionId] = update
        liveSessionIDs.insert(update.sessionId)
        guard let index = indicesByID[update.sessionId], sessions.indices.contains(index) else {
            return .unknownSession
        }
        sessions[index] = applying(update, to: sessions[index])
        return .updated
    }

    mutating func installCached(_ cached: [SessionSummary]) {
        invalidateLoads()
        liveUpdates.removeAll()
        liveSessionIDs.removeAll()
        sessions = cached
        rebuildIndex()
        freshness = .cached
    }

    mutating func markDisconnected() {
        invalidateLoads()
        liveUpdates.removeAll()
        liveSessionIDs.removeAll()
        freshness = .stale
    }

    mutating func remove(_ sessionID: String) {
        invalidateLoads()
        liveUpdates.removeValue(forKey: sessionID)
        liveSessionIDs.remove(sessionID)
        guard let index = indicesByID[sessionID], sessions.indices.contains(index) else { return }
        sessions.remove(at: index)
        rebuildIndex()
    }

    mutating func replaceForFacade(_ replacement: [SessionSummary]) {
        invalidateLoads()
        liveUpdates.removeAll()
        sessions = replacement
        rebuildIndex()
        liveSessionIDs = Set(replacement.map(\.id))
        freshness = .live
    }

    mutating func clear() {
        invalidateLoads()
        liveUpdates.removeAll()
        liveSessionIDs.removeAll()
        sessions.removeAll()
        indicesByID.removeAll()
        freshness = .stale
    }

    func hasConsistentIndex() -> Bool {
        indicesByID.count == sessions.count
            && sessions.enumerated().allSatisfy { indicesByID[$0.element.id] == $0.offset }
    }

    private mutating func rebuildIndex() {
        indicesByID = Dictionary(uniqueKeysWithValues: sessions.enumerated().map { ($0.element.id, $0.offset) })
    }

    private func applying(
        _ update: SessionSummaryUpdate,
        to summary: SessionSummary
    ) -> SessionSummary {
        SessionSummary(
            id: summary.id,
            name: update.name,
            cwd: summary.cwd,
            kind: summary.kind,
            parentSessionId: summary.parentSessionId,
            createdAt: summary.createdAt,
            updatedAt: update.updatedAt,
            messageCount: update.messageCount,
            firstMessage: update.firstMessage,
            phase: update.phase,
            summaryRevision: update.summaryRevision
        )
    }
}
