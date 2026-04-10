import XCTest
import SQLite3
@testable import TronMobile

/// Tests for SessionRepository — SQLite CRUD for sessions table
final class SessionRepositoryTests: XCTestCase {

    var database: EventDatabase!

    @MainActor
    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try database.clearAll()
    }

    @MainActor
    override func tearDown() async throws {
        try? database.clearAll()
        database.close()
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
        messageCount: Int = 5,
        inputTokens: Int = 1000,
        outputTokens: Int = 500,
        lastTurnInputTokens: Int = 800,
        cacheReadTokens: Int = 200,
        cacheCreationTokens: Int = 100,
        cost: Double = 0.05,
        isFork: Bool? = false,
        serverOrigin: String? = nil,
        isChat: Bool = false,
        lastActivityLines: [ActivityLine]? = nil
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
            messageCount: messageCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            lastTurnInputTokens: lastTurnInputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cost: cost,
            isFork: isFork,
            serverOrigin: serverOrigin,
            isChat: isChat
        )
        session.lastActivityLines = lastActivityLines
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

    @MainActor
    func testInsertAndGetRoundTrip() throws {
        let session = makeSession()
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
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
        XCTAssertEqual(retrieved?.messageCount, 5)
        XCTAssertEqual(retrieved?.inputTokens, 1000)
        XCTAssertEqual(retrieved?.outputTokens, 500)
        XCTAssertEqual(retrieved?.lastTurnInputTokens, 800)
        XCTAssertEqual(retrieved?.cacheReadTokens, 200)
        XCTAssertEqual(retrieved?.cacheCreationTokens, 100)
        XCTAssertEqual(retrieved!.cost, 0.05, accuracy: 0.0001)
        XCTAssertEqual(retrieved?.isFork, false)
        XCTAssertNil(retrieved?.serverOrigin)
        XCTAssertEqual(retrieved?.isChat, false)
    }

    @MainActor
    func testInsertWithAllOptionalFieldsNil() throws {
        let session = makeSession(
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            archivedAt: nil,
            isFork: false,
            serverOrigin: nil,
            lastActivityLines: nil
        )
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertNotNil(retrieved)
        XCTAssertNil(retrieved?.rootEventId)
        XCTAssertNil(retrieved?.headEventId)
        XCTAssertNil(retrieved?.title)
        XCTAssertNil(retrieved?.archivedAt)
        XCTAssertNil(retrieved?.serverOrigin)
        XCTAssertNil(retrieved?.lastActivityLines)
    }

    @MainActor
    func testInsertWithArchivedSession() throws {
        let session = makeSession(archivedAt: "2026-04-02T00:00:00Z")
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.archivedAt, "2026-04-02T00:00:00Z")
        XCTAssertTrue(retrieved?.isArchived == true)
    }

    @MainActor
    func testInsertWithChatSession() throws {
        let session = makeSession(isChat: true)
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.isChat, true)
    }

    @MainActor
    func testInsertWithForkSession() throws {
        let session = makeSession(isFork: true)
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.isFork, true)
    }

    @MainActor
    func testGetNonExistent() throws {
        let result = try database.sessions.get("non-existent")
        XCTAssertNil(result)
    }

    // MARK: - Upsert Behavior

    @MainActor
    func testInsertOrReplaceUpdatesExisting() throws {
        let session1 = makeSession(title: "Original Title")
        try database.sessions.insert(session1)

        let session2 = makeSession(title: "Updated Title")
        try database.sessions.insert(session2)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.title, "Updated Title")

        // Should still be only 1 session
        let all = try database.sessions.getAll()
        XCTAssertEqual(all.count, 1)
    }

    // MARK: - GetAll Ordering

    @MainActor
    func testGetAllOrderedByLastActivityDescending() throws {
        try database.sessions.insert(makeSession(id: "old", lastActivityAt: "2026-04-01T00:00:00Z"))
        try database.sessions.insert(makeSession(id: "newest", lastActivityAt: "2026-04-03T00:00:00Z"))
        try database.sessions.insert(makeSession(id: "middle", lastActivityAt: "2026-04-02T00:00:00Z"))

        let all = try database.sessions.getAll()
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].id, "newest")
        XCTAssertEqual(all[1].id, "middle")
        XCTAssertEqual(all[2].id, "old")
    }

    @MainActor
    func testGetAllEmptyTable() throws {
        let all = try database.sessions.getAll()
        XCTAssertTrue(all.isEmpty)
    }

    // MARK: - Exists

    @MainActor
    func testExistsReturnsTrue() throws {
        try database.sessions.insert(makeSession())
        XCTAssertTrue(try database.sessions.exists("sess-1"))
    }

    @MainActor
    func testExistsReturnsFalse() throws {
        XCTAssertFalse(try database.sessions.exists("non-existent"))
    }

    // MARK: - Delete

    @MainActor
    func testDeleteRemovesSession() throws {
        try database.sessions.insert(makeSession())
        XCTAssertTrue(try database.sessions.exists("sess-1"))

        try database.sessions.delete("sess-1")
        XCTAssertFalse(try database.sessions.exists("sess-1"))
        XCTAssertNil(try database.sessions.get("sess-1"))
    }

    @MainActor
    func testDeleteNonExistentDoesNotThrow() throws {
        XCTAssertNoThrow(try database.sessions.delete("non-existent"))
    }

    // MARK: - Origin Filtering

    @MainActor
    func testGetByOriginNilReturnsAll() throws {
        try database.sessions.insert(makeSession(id: "s1", serverOrigin: "prod:8080"))
        try database.sessions.insert(makeSession(id: "s2", serverOrigin: "dev:8080"))
        try database.sessions.insert(makeSession(id: "s3", serverOrigin: nil))

        let all = try database.sessions.getByOrigin(nil)
        XCTAssertEqual(all.count, 3)
    }

    @MainActor
    func testGetByOriginStrictMatchReturnsOnlyMatching() throws {
        try database.sessions.insert(makeSession(id: "s1", serverOrigin: "prod:8080"))
        try database.sessions.insert(makeSession(id: "s2", serverOrigin: "dev:8080"))
        try database.sessions.insert(makeSession(id: "s3", serverOrigin: nil))

        let prod = try database.sessions.getByOrigin("prod:8080")
        XCTAssertEqual(prod.count, 1)
        XCTAssertEqual(prod[0].id, "s1")
    }

    @MainActor
    func testGetByOriginExcludesNullOrigins() throws {
        try database.sessions.insert(makeSession(id: "s1", serverOrigin: nil))
        try database.sessions.insert(makeSession(id: "s2", serverOrigin: nil))

        let filtered = try database.sessions.getByOrigin("prod:8080")
        XCTAssertTrue(filtered.isEmpty)
    }

    @MainActor
    func testGetByOriginNoMatchReturnsEmpty() throws {
        try database.sessions.insert(makeSession(id: "s1", serverOrigin: "dev:8080"))

        let filtered = try database.sessions.getByOrigin("prod:9090")
        XCTAssertTrue(filtered.isEmpty)
    }

    @MainActor
    func testGetByOriginOrderedByLastActivity() throws {
        try database.sessions.insert(makeSession(id: "s1", lastActivityAt: "2026-04-01T00:00:00Z", serverOrigin: "prod:8080"))
        try database.sessions.insert(makeSession(id: "s2", lastActivityAt: "2026-04-03T00:00:00Z", serverOrigin: "prod:8080"))

        let results = try database.sessions.getByOrigin("prod:8080")
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, "s2") // Most recent first
    }

    // MARK: - GetOrigin

    @MainActor
    func testGetOriginReturnsValue() throws {
        try database.sessions.insert(makeSession(serverOrigin: "prod:8080"))
        XCTAssertEqual(try database.sessions.getOrigin("sess-1"), "prod:8080")
    }

    @MainActor
    func testGetOriginReturnsNilForNullOrigin() throws {
        try database.sessions.insert(makeSession(serverOrigin: nil))
        XCTAssertNil(try database.sessions.getOrigin("sess-1"))
    }

    @MainActor
    func testGetOriginReturnsNilForNonExistentSession() throws {
        XCTAssertNil(try database.sessions.getOrigin("non-existent"))
    }

    // MARK: - Activity Lines JSON

    @MainActor
    func testActivityLinesRoundTrip() throws {
        let lines = [
            ActivityLine(kind: .text, text: "Hello world"),
            ActivityLine(kind: .toolStart, text: "Running test", toolName: "Bash", status: .running),
        ]
        let session = makeSession(lastActivityLines: lines)
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertNotNil(retrieved?.lastActivityLines)
        XCTAssertEqual(retrieved?.lastActivityLines?.count, 2)
        XCTAssertEqual(retrieved?.lastActivityLines?[0].kind, .text)
        XCTAssertEqual(retrieved?.lastActivityLines?[0].text, "Hello world")
        XCTAssertEqual(retrieved?.lastActivityLines?[1].kind, .toolStart)
        XCTAssertEqual(retrieved?.lastActivityLines?[1].toolName, "Bash")
    }

    @MainActor
    func testActivityLinesNilRoundTrip() throws {
        let session = makeSession(lastActivityLines: nil)
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertNil(retrieved?.lastActivityLines)
    }

    // MARK: - Special Characters

    @MainActor
    func testSpecialCharactersInFields() throws {
        let session = makeSession(
            title: "Test 日本語 🚀 \"quotes\" & <brackets>",
            workingDirectory: "/path/with spaces/and'quotes"
        )
        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("sess-1")
        XCTAssertEqual(retrieved?.title, "Test 日本語 🚀 \"quotes\" & <brackets>")
        XCTAssertEqual(retrieved?.workingDirectory, "/path/with spaces/and'quotes")
    }

    // MARK: - Fork Operations

    @MainActor
    func testGetForkedFromEvent() throws {
        // Insert a source session
        try database.sessions.insert(makeSession(id: "source-session"))

        // Insert a forked session
        try database.sessions.insert(makeSession(id: "forked-session", isFork: true))

        // Insert session.fork event linking them
        let forkPayload: [String: Any] = [
            "sourceSessionId": "source-session",
            "sourceEventId": "evt-fork-point"
        ]
        let forkEvent = makeEvent(id: "fork-evt-1", sessionId: "forked-session", type: "session.fork", payload: forkPayload)
        try database.events.insert(forkEvent)

        let forked = try database.sessions.getForked(fromEventId: "evt-fork-point")
        XCTAssertEqual(forked.count, 1)
        XCTAssertEqual(forked[0].id, "forked-session")
    }

    @MainActor
    func testGetForkedReturnsEmptyWhenNoForks() throws {
        let forked = try database.sessions.getForked(fromEventId: "non-existent-event")
        XCTAssertTrue(forked.isEmpty)
    }

    @MainActor
    func testGetForkedMultipleForks() throws {
        try database.sessions.insert(makeSession(id: "fork-a"))
        try database.sessions.insert(makeSession(id: "fork-b"))

        let payload: [String: Any] = [
            "sourceSessionId": "source",
            "sourceEventId": "evt-shared-fork"
        ]
        try database.events.insert(makeEvent(id: "fe1", sessionId: "fork-a", type: "session.fork", payload: payload))
        try database.events.insert(makeEvent(id: "fe2", sessionId: "fork-b", type: "session.fork", payload: payload, sequence: 2))

        let forked = try database.sessions.getForked(fromEventId: "evt-shared-fork")
        XCTAssertEqual(forked.count, 2)
        let ids = Set(forked.map(\.id))
        XCTAssertTrue(ids.contains("fork-a"))
        XCTAssertTrue(ids.contains("fork-b"))
    }

    @MainActor
    func testGetSiblingsExcludesCurrentSession() throws {
        try database.sessions.insert(makeSession(id: "fork-a"))
        try database.sessions.insert(makeSession(id: "fork-b"))

        let payload: [String: Any] = [
            "sourceSessionId": "source",
            "sourceEventId": "evt-fork"
        ]
        try database.events.insert(makeEvent(id: "fe1", sessionId: "fork-a", type: "session.fork", payload: payload))
        try database.events.insert(makeEvent(id: "fe2", sessionId: "fork-b", type: "session.fork", payload: payload, sequence: 2))

        let siblings = try database.sessions.getSiblings(forEventId: "evt-fork", excluding: "fork-a")
        XCTAssertEqual(siblings.count, 1)
        XCTAssertEqual(siblings[0].id, "fork-b")
    }

    @MainActor
    func testGetForkedWithUnparseablePayloadSkipsGracefully() throws {
        try database.sessions.insert(makeSession(id: "fork-a"))

        // Insert event with payload that won't produce a valid SessionForkPayload (missing required fields)
        let badPayload: [String: Any] = ["unrelated": "data"]
        try database.events.insert(makeEvent(id: "fe1", sessionId: "fork-a", type: "session.fork", payload: badPayload))

        let forked = try database.sessions.getForked(fromEventId: "evt-fork-point")
        XCTAssertTrue(forked.isEmpty)
    }

    // MARK: - Computed Properties

    @MainActor
    func testIsArchivedComputed() throws {
        let unarchived = makeSession(archivedAt: nil)
        XCTAssertFalse(unarchived.isArchived)

        let archived = makeSession(archivedAt: "2026-04-01T00:00:00Z")
        XCTAssertTrue(archived.isArchived)
    }

    @MainActor
    func testTotalInputTokensComputed() throws {
        let session = makeSession(inputTokens: 1000, cacheReadTokens: 500)
        XCTAssertEqual(session.totalInputTokens, 1500)
    }

    @MainActor
    func testTotalTokensComputed() throws {
        let session = makeSession(inputTokens: 1000, outputTokens: 500, cacheReadTokens: 200)
        XCTAssertEqual(session.totalTokens, 1700) // (1000 + 200) + 500
    }
}
