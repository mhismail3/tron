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

/// Owns the disposable session-catalog projection and its latest-load admission.
struct SessionCatalogCoordinator: Equatable {
    struct LoadAdmission: Equatable, Sendable {
        fileprivate let generation: Int
    }

    enum SummaryUpdateAdmission: Equatable, Sendable {
        case stale
        case unknownSession
        case updated
    }

    private(set) var sessions: [SessionSummary] = []
    private var liveUpdates: [String: SessionSummaryUpdate] = [:]
    private var loadGeneration = 0

    mutating func beginLoad() -> LoadAdmission {
        loadGeneration &+= 1
        return LoadAdmission(generation: loadGeneration)
    }

    mutating func invalidateLoads() {
        loadGeneration &+= 1
    }

    func admits(_ admission: LoadAdmission) -> Bool {
        admission.generation == loadGeneration
    }

    @discardableResult
    mutating func publishAuthoritative(
        _ authoritative: [SessionSummary],
        admission: LoadAdmission
    ) -> Bool {
        guard admits(admission) else { return false }
        let ids = Set(authoritative.map(\.id))
        liveUpdates = liveUpdates.filter { ids.contains($0.key) }
        sessions = authoritative.map { summary in
            guard let update = liveUpdates[summary.id],
                  update.summaryRevision > (summary.summaryRevision ?? 0) else { return summary }
            return applying(update, to: summary)
        }
        return true
    }

    mutating func apply(_ update: SessionSummaryUpdate) -> SummaryUpdateAdmission {
        if let current = liveUpdates[update.sessionId],
           update.summaryRevision <= current.summaryRevision {
            return .stale
        }
        if let summary = sessions.first(where: { $0.id == update.sessionId }),
           update.summaryRevision <= (summary.summaryRevision ?? 0) {
            return .stale
        }
        liveUpdates[update.sessionId] = update
        guard let index = sessions.firstIndex(where: { $0.id == update.sessionId }) else {
            return .unknownSession
        }
        sessions[index] = applying(update, to: sessions[index])
        return .updated
    }

    mutating func update(from snapshot: SessionSnapshot) {
        guard let index = sessions.firstIndex(where: { $0.id == snapshot.sessionId }) else { return }
        let current = sessions[index]
        sessions[index] = SessionSummary(
            id: current.id,
            name: snapshot.name,
            cwd: current.cwd,
            kind: current.kind,
            parentSessionId: current.parentSessionId,
            createdAt: current.createdAt,
            updatedAt: current.updatedAt,
            messageCount: current.messageCount,
            firstMessage: current.firstMessage,
            phase: snapshot.phase,
            summaryRevision: current.summaryRevision
        )
    }

    mutating func installCached(_ cached: [SessionSummary]) {
        invalidateLoads()
        liveUpdates.removeAll()
        sessions = cached.map(\.safeCachedProjection)
    }

    mutating func markDisconnected() {
        invalidateLoads()
        liveUpdates.removeAll()
        sessions = sessions.map(\.safeCachedProjection)
    }

    mutating func remove(_ sessionID: String) {
        invalidateLoads()
        liveUpdates.removeValue(forKey: sessionID)
        sessions.removeAll { $0.id == sessionID }
    }

    mutating func replaceForFacade(_ replacement: [SessionSummary]) {
        invalidateLoads()
        liveUpdates.removeAll()
        sessions = replacement
    }

    mutating func clear() {
        invalidateLoads()
        liveUpdates.removeAll()
        sessions.removeAll()
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
