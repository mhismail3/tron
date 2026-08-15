import Observation
import Synchronization
import Testing
@testable import TronMobile

@Suite("Dashboard state ownership")
struct DashboardStateOwnerTests {
    @Test("a newer navigation intent rejects an older asynchronous completion")
    func navigationAdmission() {
        var owner = DashboardNavigationOwner()
        let importIntent = owner.begin()
        let newerIntent = owner.begin()

        let admittedImport = owner.admit(importIntent)
        let admittedNewer = owner.admit(newerIntent)
        let admittedDuplicate = owner.admit(newerIntent)
        #expect(!admittedImport)
        #expect(admittedNewer)
        #expect(!admittedDuplicate)
    }

    @Test("direct navigation invalidates pending asynchronous navigation")
    func navigationInvalidation() {
        var owner = DashboardNavigationOwner()
        let pending = owner.begin()
        owner.invalidate()
        let admitted = owner.admit(pending)
        #expect(!admitted)
    }

    @Test("only the latest catalog load may publish")
    func catalogAdmission() {
        var owner = SessionCatalogCoordinator()
        let first = owner.beginLoad()
        let second = owner.beginLoad()
        let firstPublished = owner.publishAuthoritative([summary(revision: 1)], admission: first)
        let secondPublished = owner.publishAuthoritative([summary(revision: 2)], admission: second)
        #expect(!firstPublished)
        #expect(secondPublished)
        #expect(owner.sessions.first?.summaryRevision == 2)
        owner.invalidateLoads()
        #expect(!owner.admits(second))
    }

    @Test("newer live summaries survive an older authoritative catalog page")
    func liveSummaryOverlay() {
        var owner = SessionCatalogCoordinator()
        let first = owner.beginLoad()
        let firstPublished = owner.publishAuthoritative([summary(revision: 1)], admission: first)
        let updated = owner.apply(update(revision: 3, phase: .running))
        let stale = owner.apply(update(revision: 2, phase: .idle))
        #expect(firstPublished)
        #expect(updated == .updated)
        #expect(stale == .stale)

        let refresh = owner.beginLoad()
        let refreshed = owner.publishAuthoritative([summary(revision: 2)], admission: refresh)
        #expect(refreshed)
        #expect(owner.sessions.first?.summaryRevision == 3)
        #expect(owner.sessions.first?.phase == .running)
    }

    @Test("unknown live summaries request discovery without fabricating a row")
    func unknownSummary() {
        var owner = SessionCatalogCoordinator()
        let unknown = owner.apply(update(revision: 1, phase: .running))
        #expect(unknown == .unknownSession)
        #expect(owner.sessions.isEmpty)

        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load)
        #expect(published)
        #expect(owner.sessions.first?.phase == .idle)
    }

    @Test("cached and disconnected phases retain provenance without fabricating interruption")
    func catalogFreshnessAndActivity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([
            summary(revision: 1, phase: .running),
        ], admission: load)
        #expect(published)
        #expect(owner.freshness == .live)
        #expect(owner.activity(for: "session") == .active)

        let pendingBeforeDisconnect = owner.beginLoad()
        owner.markDisconnected()
        #expect(owner.sessions.first?.phase == .running)
        #expect(owner.freshness == .stale)
        #expect(owner.activity(for: "session") == .resuming)
        let disconnectedPublish = owner.publishAuthoritative(
            [summary(revision: 2, phase: .running)],
            admission: pendingBeforeDisconnect
        )
        #expect(!disconnectedPublish)

        let pendingBeforeCache = owner.beginLoad()
        owner.installCached([summary(revision: 2, phase: .interrupted)])
        #expect(owner.sessions.first?.phase == .interrupted)
        #expect(owner.freshness == .cached)
        #expect(owner.activity(for: "session") == .resuming)
        let cachedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: pendingBeforeCache
        )
        #expect(!cachedPublish)

        let liveInterrupted = owner.apply(update(revision: 4, phase: .interrupted))
        #expect(liveInterrupted == .updated)
        #expect(owner.activity(for: "session") == .interrupted)
    }

    @Test("removal clears both the row and retained live revision")
    func removal() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load)
        let updated = owner.apply(update(revision: 2, phase: .running))
        #expect(published)
        #expect(updated == .updated)
        let pendingBeforeRemoval = owner.beginLoad()
        owner.remove("session")
        #expect(owner.sessions.isEmpty)
        let removedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: pendingBeforeRemoval
        )
        #expect(!removedPublish)
        let unknown = owner.apply(update(revision: 2, phase: .idle))
        #expect(unknown == .unknownSession)
    }

    @Test("facade replacement and clear invalidate pending loads")
    func replacementAndClearInvalidateLoads() {
        var owner = SessionCatalogCoordinator()
        let beforeReplacement = owner.beginLoad()
        owner.replaceForFacade([summary(revision: 1)])
        let replacedPublish = owner.publishAuthoritative(
            [summary(revision: 2)],
            admission: beforeReplacement
        )
        #expect(!replacedPublish)

        let beforeClear = owner.beginLoad()
        owner.clear()
        let clearedPublish = owner.publishAuthoritative(
            [summary(revision: 3)],
            admission: beforeClear
        )
        #expect(!clearedPublish)
        #expect(owner.sessions.isEmpty)
        #expect(owner.hasConsistentIndex())
    }

    @Test("catalog index stays exact across publication, update, removal, replacement, and clear")
    func catalogIndexIntegrity() {
        var owner = SessionCatalogCoordinator()
        let load = owner.beginLoad()
        let published = owner.publishAuthoritative([summary(revision: 1)], admission: load)
        #expect(published)
        #expect(owner.hasConsistentIndex())
        let updated = owner.apply(update(revision: 2, phase: .running))
        #expect(updated == .updated)
        #expect(owner.hasConsistentIndex())
        owner.remove("session")
        #expect(owner.hasConsistentIndex())
        owner.replaceForFacade([summary(revision: 3)])
        #expect(owner.hasConsistentIndex())
        owner.clear()
        #expect(owner.hasConsistentIndex())
    }

    @MainActor
    @Test("the AppModel sessions façade remains observable")
    func sessionsFacadeObservation() {
        let model = AppModel()
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.sessions
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.sessions = [summary(revision: 1)]
        #expect(changed.withLock { $0 })
        #expect(model.sessions.first?.id == "session")
    }

    private func summary(
        revision: Int,
        phase: SessionPhase = .idle
    ) -> SessionSummary {
        SessionSummary(
            id: "session",
            name: "Session",
            cwd: "/workspace",
            parentSessionId: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
            messageCount: 1,
            firstMessage: "Hello",
            phase: phase,
            summaryRevision: revision
        )
    }

    private func update(
        revision: Int,
        phase: SessionPhase
    ) -> SessionSummaryUpdate {
        SessionSummaryUpdate(
            sessionId: "session",
            summaryRevision: revision,
            phase: phase,
            name: "Updated",
            updatedAt: "2026-01-01T00:00:01Z",
            messageCount: revision,
            firstMessage: "Updated"
        )
    }
}
