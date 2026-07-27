import XCTest
import SQLite3
@testable import TronMobile

/// Tests for SessionRepository — SQLite CRUD for sessions table
@MainActor
final class SessionRepositoryTests: XCTestCase {

    var database: EventDatabase!
    var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "session-repository")
        testState.registerTeardown(with: self)
        database = testState.makeDatabase()
        try await database.initialize()
        try await database.clearAll()
    }

    override func tearDown() async throws {
        try? await database.clearAll()
        await testState.cleanup()
    }

    // MARK: - Helpers

    private func makeSession(
        id: String = "sess-1",
        workspaceId: String = "ws-1",
        rootEventId: String? = "evt-root",
        headEventId: String? = "evt-head",
        title: String? = "Test Session",
        latestModel: String = "claude-sonnet-4-6",
        workingDirectory: String = "/tmp/test",
        createdAt: String = "2026-04-01T00:00:00Z",
        lastActivityAt: String = "2026-04-01T12:00:00Z",
        archivedAt: String? = nil,
        eventCount: Int = 10,
        turnCount: Int = 4,
        messageCount: Int = 5,
        inputTokens: Int = 1000,
        outputTokens: Int = 500,
        lastTurnInputTokens: Int = 800,
        cacheReadTokens: Int = 200,
        cacheCreationTokens: Int = 100,
        cost: Double = 0.05,
        isFork: Bool? = false,
        serverOrigin: String? = nil,
        lastActivityLines: [ActivityLine]? = nil,
        labels: [String] = [],
        organizationGroup: String? = nil
    ) -> CachedSession {
        var session = CachedSession(
            id: id,
            workspaceId: workspaceId,
            rootEventId: rootEventId,
            headEventId: headEventId,
            title: title,
            latestModel: latestModel,
            workingDirectory: workingDirectory,
            createdAt: createdAt,
            lastActivityAt: lastActivityAt,
            archivedAt: archivedAt,
            eventCount: eventCount,
            turnCount: turnCount,
            messageCount: messageCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            lastTurnInputTokens: lastTurnInputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cost: cost
        )
        session.isFork = isFork
        session.serverOrigin = serverOrigin
        session.lastActivityLines = lastActivityLines
        session.labels = labels
        session.organizationGroup = organizationGroup
        return session
    }

    private func makeEvent(
        id: String,
        sessionId: String,
        type: String,
        payload: [String: Any] = [:],
        sequence: Int = 1
    ) -> SessionEvent {
        var codablePayload: [String: AnyCodable] = [:]
        for (key, value) in payload {
            codablePayload[key] = AnyCodable(value)
        }
        return SessionEvent(
            id: id,
            parentId: nil,
            sessionId: sessionId,
            workspaceId: "ws-1",
            type: type,
            timestamp: "2026-04-01T00:00:00Z",
            sequence: sequence,
            payload: codablePayload
        )
    }

    // MARK: - Insert + Get Round Trip

    func testInsertAndGetRoundTrip() async throws {
        let session = makeSession(
            labels: ["Work", "Follow Up"],
            organizationGroup: "Projects"
        )
        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "sess-1")
        XCTAssertEqual(retrieved?.workspaceId, "ws-1")
        XCTAssertEqual(retrieved?.rootEventId, "evt-root")
        XCTAssertEqual(retrieved?.headEventId, "evt-head")
        XCTAssertEqual(retrieved?.title, "Test Session")
        XCTAssertEqual(retrieved?.latestModel, "claude-sonnet-4-6")
        XCTAssertEqual(retrieved?.workingDirectory, "/tmp/test")
        XCTAssertEqual(retrieved?.createdAt, "2026-04-01T00:00:00Z")
        XCTAssertEqual(retrieved?.lastActivityAt, "2026-04-01T12:00:00Z")
        XCTAssertNil(retrieved?.archivedAt)
        XCTAssertEqual(retrieved?.eventCount, 10)
        XCTAssertEqual(retrieved?.turnCount, 4)
        XCTAssertEqual(retrieved?.messageCount, 5)
        XCTAssertEqual(retrieved?.inputTokens, 1000)
        XCTAssertEqual(retrieved?.outputTokens, 500)
        XCTAssertEqual(retrieved?.lastTurnInputTokens, 800)
        XCTAssertEqual(retrieved?.cacheReadTokens, 200)
        XCTAssertEqual(retrieved?.cacheCreationTokens, 100)
        XCTAssertEqual(retrieved!.cost, 0.05, accuracy: 0.0001)
        XCTAssertEqual(retrieved?.isFork, false)
        XCTAssertNil(retrieved?.serverOrigin)
        XCTAssertEqual(retrieved?.labels, ["Work", "Follow Up"])
        XCTAssertEqual(retrieved?.organizationGroup, "Projects")
    }

    func testInsertWithAllOptionalFieldsNil() async throws {
        let session = makeSession(
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            archivedAt: nil,
            isFork: false,
            serverOrigin: nil,
            lastActivityLines: nil
        )
        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.rootEventId)
        XCTAssertNil(retrieved?.headEventId)
        XCTAssertNil(retrieved?.title)
        XCTAssertNil(retrieved?.archivedAt)
        XCTAssertNil(retrieved?.serverOrigin)
        XCTAssertNil(retrieved?.lastActivityLines)
    }

    func testInsertWithArchivedSession() async throws {
        let session = makeSession(archivedAt: "2026-04-02T00:00:00Z")
        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.archivedAt, "2026-04-02T00:00:00Z")
        XCTAssertTrue(retrieved?.isArchived == true)
    }

    func testInsertWithForkSession() async throws {
        let session = makeSession(isFork: true)
        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.isFork, true)
    }

    func testGetNonExistent() async throws {
        let result = try await database.sessions.get("non-existent")
        XCTAssertNil(result)
    }

    // MARK: - Upsert Behavior

    func testInsertOrReplaceUpdatesExisting() async throws {
        let session1 = makeSession(title: "Original Title")
        try await database.sessions.insert(session1)

        let session2 = makeSession(title: "Updated Title")
        try await database.sessions.insert(session2)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.title, "Updated Title")

        // Should still be only 1 session
        let all = try await database.sessions.getAll()
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - GetAll Ordering

    func testGetAllOrderedByLastActivityDescending() async throws {
        try await database.sessions.insert(makeSession(id: "old", lastActivityAt: "2026-04-01T00:00:00Z"))
        try await database.sessions.insert(makeSession(id: "newest", lastActivityAt: "2026-04-03T00:00:00Z"))
        try await database.sessions.insert(makeSession(id: "middle", lastActivityAt: "2026-04-02T00:00:00Z"))

        let all = try await database.sessions.getAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].id, "newest")
        XCTAssertEqual(all[1].id, "middle")
        XCTAssertEqual(all[2].id, "old")
    }

    func testGetAllEmptyTable() async throws {
        let all = try await database.sessions.getAll()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Exists

    func testExistsReturnsTrue() async throws {
        try await database.sessions.insert(makeSession())
        let exists = try await database.sessions.exists("sess-1")
        XCTAssertTrue(exists)
    }

    func testExistsReturnsFalse() async throws {
        let exists = try await database.sessions.exists("non-existent")
        XCTAssertFalse(exists)
    }

    // MARK: - Delete

    func testDeleteRemovesSession() async throws {
        try await database.sessions.insert(makeSession())
        let existsBefore = try await database.sessions.exists("sess-1")
        XCTAssertTrue(existsBefore)

        try await database.sessions.delete("sess-1")
        let existsAfter = try await database.sessions.exists("sess-1")
        XCTAssertFalse(existsAfter)
        let session = try await database.sessions.get("sess-1")
        XCTAssertNil(session)
    }

    func testDeleteNonExistentDoesNotThrow() async throws {
        try await database.sessions.delete("non-existent")
    }

    func testLargeServerSnapshotReconcilesInOneBatchAndPreservesRetainedEvents() async throws {
        let origin = "prod:8080"
        let allSessions = (0..<2_000).map { index in
            makeSession(
                id: String(format: "session-%04d", index),
                title: "Session \(index)",
                serverOrigin: origin
            )
        }
        let allIds = Set(allSessions.map(\.id))

        let initialRemoved = try await database.sessions.reconcileServerSnapshot(
            upserting: allSessions,
            serverOrigin: origin,
            authoritativeSessionIds: allIds,
            snapshotAsOf: "2026-04-02T00:00:00Z"
        )
        XCTAssertEqual(initialRemoved, 0)
        let initialSessions = try await database.sessions.getByOrigin(origin)
        XCTAssertEqual(initialSessions.count, 2_000)

        try await database.events.insert(
            makeEvent(id: "retained-event", sessionId: "session-0000", type: "message.user")
        )
        try await database.events.insert(
            makeEvent(id: "stale-event", sessionId: "session-1999", type: "message.user")
        )
        var futureSession = makeSession(
            id: "session-future",
            createdAt: "2026-04-02T00:00:00.500Z",
            serverOrigin: origin
        )
        futureSession.title = "Created after snapshot"
        try await database.sessions.insert(futureSession)
        try await database.events.insert(
            makeEvent(id: "future-event", sessionId: futureSession.id, type: "message.user")
        )

        let retainedSessions = Array(allSessions.dropLast())
        let removed = try await database.sessions.reconcileServerSnapshot(
            upserting: retainedSessions,
            serverOrigin: origin,
            authoritativeSessionIds: Set(retainedSessions.map(\.id)),
            snapshotAsOf: "2026-04-02T00:00:00Z"
        )

        XCTAssertEqual(removed, 1)
        let staleSession = try await database.sessions.get("session-1999")
        let preservedFutureSession = try await database.sessions.get("session-future")
        let retainedEventExists = try await database.events.exists("retained-event")
        let staleEventExists = try await database.events.exists("stale-event")
        let futureEventExists = try await database.events.exists("future-event")
        XCTAssertNil(staleSession)
        XCTAssertNotNil(preservedFutureSession)
        XCTAssertTrue(retainedEventExists)
        XCTAssertFalse(staleEventExists)
        XCTAssertTrue(futureEventExists)
    }

    func testSnapshotReconciliationPreservesSessionCreatedNanosecondsAfterBoundary() async throws {
        let origin = "prod:8080"
        let stale = makeSession(
            id: "stale",
            createdAt: "2026-04-02T00:00:00.000100Z",
            serverOrigin: origin
        )
        let future = makeSession(
            id: "future",
            createdAt: "2026-04-02T00:00:00.000300Z",
            serverOrigin: origin
        )
        try await database.sessions.insert(stale)
        try await database.sessions.insert(future)
        try await database.events.insert(makeEvent(id: "stale-event-ns", sessionId: stale.id, type: "message.user"))
        try await database.events.insert(makeEvent(id: "future-event-ns", sessionId: future.id, type: "message.user"))

        let removed = try await database.sessions.reconcileServerSnapshot(
            upserting: [],
            serverOrigin: origin,
            authoritativeSessionIds: [],
            snapshotAsOf: "2026-04-02T00:00:00.000200Z"
        )

        XCTAssertEqual(removed, 1)
        let staleSession = try await database.sessions.get(stale.id)
        let futureSession = try await database.sessions.get(future.id)
        let staleEventExists = try await database.events.exists("stale-event-ns")
        let futureEventExists = try await database.events.exists("future-event-ns")
        XCTAssertNil(staleSession)
        XCTAssertNotNil(futureSession)
        XCTAssertFalse(staleEventExists)
        XCTAssertTrue(futureEventExists)
    }

    func testInvalidSnapshotTimestampRollsBackEarlierUpserts() async throws {
        let origin = "prod:8080"
        try await database.sessions.insert(makeSession(id: "existing", serverOrigin: origin))

        do {
            _ = try await database.sessions.reconcileServerSnapshot(
                upserting: [makeSession(id: "new-upsert", serverOrigin: origin)],
                serverOrigin: origin,
                authoritativeSessionIds: [],
                snapshotAsOf: "2026-04-02T00:00:00.Z"
            )
            XCTFail("Expected invalid snapshot timestamp")
        } catch {
            let newSession = try await database.sessions.get("new-upsert")
            let existingSession = try await database.sessions.get("existing")
            XCTAssertNil(newSession)
            XCTAssertNotNil(existingSession)
        }
    }

    func testInvalidCachedTimestampRollsBackUpsertsAndPreservesDeletionCandidates() async throws {
        let origin = "prod:8080"
        try await database.sessions.insert(
            makeSession(id: "stale-candidate", createdAt: "2026-04-01T00:00:00Z", serverOrigin: origin)
        )
        try await database.sessions.insert(
            makeSession(id: "malformed", createdAt: "2026-04-01T00:00:00.Z", serverOrigin: origin)
        )
        try await database.events.insert(
            makeEvent(id: "candidate-event", sessionId: "stale-candidate", type: "message.user")
        )

        do {
            _ = try await database.sessions.reconcileServerSnapshot(
                upserting: [makeSession(id: "new-upsert", serverOrigin: origin)],
                serverOrigin: origin,
                authoritativeSessionIds: [],
                snapshotAsOf: "2026-04-02T00:00:00Z"
            )
            XCTFail("Expected invalid cached timestamp")
        } catch {
            let newSession = try await database.sessions.get("new-upsert")
            let staleCandidate = try await database.sessions.get("stale-candidate")
            let candidateEventExists = try await database.events.exists("candidate-event")
            XCTAssertNil(newSession)
            XCTAssertNotNil(staleCandidate)
            XCTAssertTrue(candidateEventExists)
        }
    }

    func testPartialServerSnapshotNeverDeletesMissingSessions() async throws {
        let origin = "prod:8080"
        let existing = makeSession(id: "existing", serverOrigin: origin)
        try await database.sessions.insert(existing)

        let removed = try await database.sessions.reconcileServerSnapshot(
            upserting: [],
            serverOrigin: origin,
            authoritativeSessionIds: nil,
            snapshotAsOf: nil
        )

        XCTAssertEqual(removed, 0)
        let preserved = try await database.sessions.get(existing.id)
        XCTAssertNotNil(preserved)
    }

    // MARK: - Origin Filtering

    func testGetByOriginNilReturnsAll() async throws {
        try await database.sessions.insert(makeSession(id: "s1", serverOrigin: "prod:8080"))
        try await database.sessions.insert(makeSession(id: "s2", serverOrigin: "dev:8080"))
        try await database.sessions.insert(makeSession(id: "s3", serverOrigin: nil))

        let all = try await database.sessions.getByOrigin(nil)
        XCTAssertEqual(all.count, 3)
    }

    func testGetByOriginStrictMatchReturnsOnlyMatching() async throws {
        try await database.sessions.insert(makeSession(id: "s1", serverOrigin: "prod:8080"))
        try await database.sessions.insert(makeSession(id: "s2", serverOrigin: "dev:8080"))
        try await database.sessions.insert(makeSession(id: "s3", serverOrigin: nil))

        let prod = try await database.sessions.getByOrigin("prod:8080")
        XCTAssertEqual(prod.count, 1)
        XCTAssertEqual(prod[0].id, "s1")
    }

    func testGetByOriginExcludesNullOrigins() async throws {
        try await database.sessions.insert(makeSession(id: "s1", serverOrigin: nil))
        try await database.sessions.insert(makeSession(id: "s2", serverOrigin: nil))

        let filtered = try await database.sessions.getByOrigin("prod:8080")
        XCTAssertTrue(filtered.isEmpty)
    }

    func testGetByOriginNoMatchReturnsEmpty() async throws {
        try await database.sessions.insert(makeSession(id: "s1", serverOrigin: "dev:8080"))

        let filtered = try await database.sessions.getByOrigin("prod:9090")
        XCTAssertTrue(filtered.isEmpty)
    }

    func testGetByOriginOrderedByLastActivity() async throws {
        try await database.sessions.insert(makeSession(id: "s1", lastActivityAt: "2026-04-01T00:00:00Z", serverOrigin: "prod:8080"))
        try await database.sessions.insert(makeSession(id: "s2", lastActivityAt: "2026-04-03T00:00:00Z", serverOrigin: "prod:8080"))

        let results = try await database.sessions.getByOrigin("prod:8080")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, "s2") // Most recent first
    }

    // MARK: - GetOrigin

    func testGetOriginReturnsValue() async throws {
        try await database.sessions.insert(makeSession(serverOrigin: "prod:8080"))
        let origin = try await database.sessions.getOrigin("sess-1")
        XCTAssertEqual(origin, "prod:8080")
    }

    func testGetOriginReturnsNilForNullOrigin() async throws {
        try await database.sessions.insert(makeSession(serverOrigin: nil))
        let origin = try await database.sessions.getOrigin("sess-1")
        XCTAssertNil(origin)
    }

    func testGetOriginReturnsNilForNonExistentSession() async throws {
        let origin = try await database.sessions.getOrigin("non-existent")
        XCTAssertNil(origin)
    }

    // MARK: - Activity Lines JSON

    func testActivityLinesRoundTrip() async throws {
        let lines = [
            ActivityLine(kind: .text, text: "Hello world"),
            ActivityLine(kind: .toolInvocationStarted, text: "Running test", toolName: "process_run", status: .running),
        ]
        let session = makeSession(lastActivityLines: lines)
        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertNotNil(retrieved?.lastActivityLines)
        XCTAssertEqual(retrieved?.lastActivityLines?.count, 2)
        XCTAssertEqual(retrieved?.lastActivityLines?[0].kind, .text)
        XCTAssertEqual(retrieved?.lastActivityLines?[0].text, "Hello world")
        XCTAssertEqual(retrieved?.lastActivityLines?[1].kind, .toolInvocationStarted)
        XCTAssertEqual(retrieved?.lastActivityLines?[1].toolName, "process_run")
    }

    func testActivityLinesNilRoundTrip() async throws {
        let session = makeSession(lastActivityLines: nil)
        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertNil(retrieved?.lastActivityLines)
    }

    // MARK: - Special Characters

    func testSpecialCharactersInFields() async throws {
        let session = makeSession(
            title: "Test 日本語 🚀 \"quotes\" & <brackets>",
            workingDirectory: "/path/with spaces/and'quotes"
        )
        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.title, "Test 日本語 🚀 \"quotes\" & <brackets>")
        XCTAssertEqual(retrieved?.workingDirectory, "/path/with spaces/and'quotes")
    }

    // MARK: - Fork Operations

    func testGetForkedFromEvent() async throws {
        // Insert a source session
        try await database.sessions.insert(makeSession(id: "source-session"))

        // Insert a forked session
        try await database.sessions.insert(makeSession(id: "forked-session", isFork: true))

        // Insert session.fork event linking them
        let forkPayload: [String: Any] = [
            "sourceSessionId": "source-session",
            "sourceEventId": "evt-fork-point"
        ]
        let forkEvent = makeEvent(id: "fork-evt-1", sessionId: "forked-session", type: "session.fork", payload: forkPayload)
        try await database.events.insert(forkEvent)

        let forked = try await database.sessions.getForked(fromEventId: "evt-fork-point")
        XCTAssertEqual(forked.count, 1)
        XCTAssertEqual(forked[0].id, "forked-session")
    }

    func testGetForkedReturnsEmptyWhenNoForks() async throws {
        let forked = try await database.sessions.getForked(fromEventId: "non-existent-event")
        XCTAssertTrue(forked.isEmpty)
    }

    func testGetForkedMultipleForks() async throws {
        try await database.sessions.insert(makeSession(id: "fork-a"))
        try await database.sessions.insert(makeSession(id: "fork-b"))

        let payload: [String: Any] = [
            "sourceSessionId": "source",
            "sourceEventId": "evt-shared-fork"
        ]
        try await database.events.insert(makeEvent(id: "fe1", sessionId: "fork-a", type: "session.fork", payload: payload))
        try await database.events.insert(makeEvent(id: "fe2", sessionId: "fork-b", type: "session.fork", payload: payload, sequence: 2))

        let forked = try await database.sessions.getForked(fromEventId: "evt-shared-fork")
        XCTAssertEqual(forked.count, 2)
        let ids = Set(forked.map(\.id))
        XCTAssertTrue(ids.contains("fork-a"))
        XCTAssertTrue(ids.contains("fork-b"))
    }

    func testGetSiblingsExcludesCurrentSession() async throws {
        try await database.sessions.insert(makeSession(id: "fork-a"))
        try await database.sessions.insert(makeSession(id: "fork-b"))

        let payload: [String: Any] = [
            "sourceSessionId": "source",
            "sourceEventId": "evt-fork"
        ]
        try await database.events.insert(makeEvent(id: "fe1", sessionId: "fork-a", type: "session.fork", payload: payload))
        try await database.events.insert(makeEvent(id: "fe2", sessionId: "fork-b", type: "session.fork", payload: payload, sequence: 2))

        let siblings = try await database.sessions.getSiblings(forEventId: "evt-fork", excluding: "fork-a")
        XCTAssertEqual(siblings.count, 1)
        XCTAssertEqual(siblings[0].id, "fork-b")
    }

    func testGetForkedWithUnparseablePayloadSkipsGracefully() async throws {
        try await database.sessions.insert(makeSession(id: "fork-a"))

        // Insert event with payload that won't produce a valid SessionForkPayload (missing required fields)
        let badPayload: [String: Any] = ["unrelated": "data"]
        try await database.events.insert(makeEvent(id: "fe1", sessionId: "fork-a", type: "session.fork", payload: badPayload))

        let forked = try await database.sessions.getForked(fromEventId: "evt-fork-point")
        XCTAssertTrue(forked.isEmpty)
    }

    // MARK: - Computed Properties

    func testIsArchivedComputed() async throws {
        let unarchived = makeSession(archivedAt: nil)
        XCTAssertFalse(unarchived.isArchived)

        let archived = makeSession(archivedAt: "2026-04-01T00:00:00Z")
        XCTAssertTrue(archived.isArchived)
    }

    func testTotalInputTokensComputed() async throws {
        let session = makeSession(inputTokens: 1000, cacheReadTokens: 500)
        XCTAssertEqual(session.totalInputTokens, 1500)
    }

    func testTotalTokensComputed() async throws {
        let session = makeSession(inputTokens: 1000, outputTokens: 500, cacheReadTokens: 200)
        XCTAssertEqual(session.totalTokens, 1700) // (1000 + 200) + 500
    }
}
