import XCTest
import SQLite3
@testable import TronMobile

/// Tests for TreeRepository — event tree visualization builder
final class TreeRepositoryTests: XCTestCase {

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

    private func makeEvent(
        id: String,
        parentId: String? = nil,
        sessionId: String = "sess-1",
        type: String = "message.user",
        sequence: Int = 1,
        payload: [String: Any] = [:]
    ) -> SessionEvent {
        var codablePayload: [String: AnyCodable] = [:]
        for (key, value) in payload {
            codablePayload[key] = AnyCodable(value)
        }
        return SessionEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "ws-1",
            type: type,
            timestamp: "2026-04-01T00:00:00Z",
            sequence: sequence,
            payload: codablePayload
        )
    }

    private func makeSession(
        id: String = "sess-1",
        headEventId: String? = nil
    ) -> CachedSession {
        CachedSession(
            id: id,
            workspaceId: "ws-1",
            rootEventId: nil,
            headEventId: headEventId,
            title: "Test",
            latestModel: "claude-sonnet-4-6",
            workingDirectory: "/tmp",
            createdAt: "2026-04-01T00:00:00Z",
            lastActivityAt: "2026-04-01T00:00:00Z",
            archivedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0
        )
    }

    // MARK: - Empty Session

    @MainActor
    func testBuildEmptySessionReturnsEmpty() throws {
        // Session exists but has no events
        try database.sessions.insert(makeSession())
        let nodes = try database.tree.build("sess-1")
        XCTAssertTrue(nodes.isEmpty)
    }

    @MainActor
    func testBuildNonExistentSessionReturnsEmpty() throws {
        let nodes = try database.tree.build("no-such-session")
        XCTAssertTrue(nodes.isEmpty)
    }

    // MARK: - Single Event

    @MainActor
    func testBuildSingleEvent() throws {
        try database.sessions.insert(makeSession(headEventId: "evt-1"))
        try database.events.insert(makeEvent(id: "evt-1"))

        let nodes = try database.tree.build("sess-1")
        XCTAssertEqual(nodes.count, 1)
        XCTAssertEqual(nodes[0].id, "evt-1")
    }

    // MARK: - Linear Chain

    @MainActor
    func testBuildLinearChain() throws {
        try database.sessions.insert(makeSession(headEventId: "evt-3"))
        try database.events.insert(makeEvent(id: "evt-1", sequence: 1))
        try database.events.insert(makeEvent(id: "evt-2", parentId: "evt-1", sequence: 2))
        try database.events.insert(makeEvent(id: "evt-3", parentId: "evt-2", sequence: 3))

        let nodes = try database.tree.build("sess-1")
        XCTAssertEqual(nodes.count, 3)
    }

    // MARK: - Branching

    @MainActor
    func testBuildBranchingTree() throws {
        try database.sessions.insert(makeSession(headEventId: "evt-2"))
        // Root event
        try database.events.insert(makeEvent(id: "evt-1", sequence: 1))
        // Two children of the same parent (branch point)
        try database.events.insert(makeEvent(id: "evt-2", parentId: "evt-1", sequence: 2))
        try database.events.insert(makeEvent(id: "evt-3", parentId: "evt-1", sequence: 3))

        let nodes = try database.tree.build("sess-1")
        XCTAssertEqual(nodes.count, 3)

        // The parent should be marked as a branch point
        let branchPoints = nodes.filter(\.isBranchPoint)
        XCTAssertFalse(branchPoints.isEmpty, "Should have at least one branch point")
    }

    // MARK: - Head Event

    @MainActor
    func testHeadEventMarked() throws {
        try database.sessions.insert(makeSession(headEventId: "evt-2"))
        try database.events.insert(makeEvent(id: "evt-1", sequence: 1))
        try database.events.insert(makeEvent(id: "evt-2", parentId: "evt-1", sequence: 2))

        let nodes = try database.tree.build("sess-1")
        let headNodes = nodes.filter(\.isHead)
        XCTAssertEqual(headNodes.count, 1)
        XCTAssertEqual(headNodes[0].id, "evt-2")
    }

    @MainActor
    func testNilHeadEventIdBuildsTreeWithoutHead() throws {
        try database.sessions.insert(makeSession(headEventId: nil))
        try database.events.insert(makeEvent(id: "evt-1", sequence: 1))

        let nodes = try database.tree.build("sess-1")
        XCTAssertEqual(nodes.count, 1)
        // No node should be marked as head
        XCTAssertTrue(nodes.allSatisfy { !$0.isHead })
    }
}
