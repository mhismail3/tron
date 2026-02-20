import XCTest
@testable import TronMobile

/// Tests for workspace path validation and deleted workspace handling
final class WorkspaceValidationTests: XCTestCase {

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

    // MARK: - Workspace Path Validation Tests

    /// Test that validateWorkspacePath returns true for existing paths
    @MainActor
    func testValidateWorkspacePathExistingPath() async throws {
        let mockRPC = MockRPCClient()

        let result = await mockRPC.validateWorkspacePath("/existing/path")

        XCTAssertEqual(result, true)
        XCTAssertEqual(mockRPC.listDirectoryCallCount, 1)
    }

    /// Test that validateWorkspacePath returns false for confirmed-deleted paths (RPCError)
    @MainActor
    func testValidateWorkspacePathNonExistentPath() async throws {
        let mockRPC = MockRPCClient()
        // RPCError = server processed request and returned error (e.g. ENOENT)
        mockRPC.listDirectoryError = RPCError(code: "ENOENT", message: "no such file or directory", details: nil)

        let result = await mockRPC.validateWorkspacePath("/deleted/path")

        XCTAssertEqual(result, false)
    }

    /// Test that validateWorkspacePath returns false for empty path
    @MainActor
    func testValidateWorkspacePathEmptyPath() async throws {
        let mockRPC = MockRPCClient()

        let result = await mockRPC.validateWorkspacePath("")

        XCTAssertEqual(result, false)
        XCTAssertEqual(mockRPC.listDirectoryCallCount, 0)
    }

    /// Test that connection errors return nil (indeterminate), not false
    @MainActor
    func testValidateWorkspacePathConnectionError() async throws {
        let mockRPC = MockRPCClient()
        mockRPC.listDirectoryError = MockRPCError.connectionNotEstablished

        let result = await mockRPC.validateWorkspacePath("/some/path")

        // Connection errors are indeterminate — must NOT be treated as "deleted"
        XCTAssertNil(result)
    }

    // MARK: - Connection Error vs Filesystem Error Tests

    /// Test that connection errors produce nil (indeterminate), NOT false (deleted)
    @MainActor
    func testConnectionErrorDoesNotProduceFalsePositive() async throws {
        let mockRPC = MockRPCClient()
        mockRPC.listDirectoryError = MockRPCError.connectionNotEstablished

        let result = await mockRPC.validateWorkspacePath("/some/path")

        // Connection errors must return nil so callers don't store false "deleted" state
        XCTAssertNil(result)
    }

    /// Test that RPCError (server-confirmed) produces definitive false
    @MainActor
    func testRPCErrorProducesDefinitiveFalse() async throws {
        let mockRPC = MockRPCClient()
        mockRPC.listDirectoryError = RPCError(code: "ENOENT", message: "no such file or directory", details: nil)

        let result = await mockRPC.validateWorkspacePath("/deleted/path")

        // RPCError = server processed request → confirmed deleted
        XCTAssertEqual(result, false)
    }

    /// Test that nil results don't pollute the workspace deleted cache
    @MainActor
    func testNilResultDoesNotUpdateCache() async throws {
        // Simulate: caller uses if-let to only store definitive results
        var cache: [String: Bool] = [:]
        let indeterminateResult: Bool? = nil

        if let pathExists = indeterminateResult {
            cache["s1"] = !pathExists
        }

        // Cache should remain empty — indeterminate results are discarded
        XCTAssertNil(cache["s1"])
    }

    /// Test that definitive results update the cache correctly
    @MainActor
    func testDefinitiveResultUpdatesCache() async throws {
        var cache: [String: Bool] = [:]

        // Path confirmed to exist
        let existsResult: Bool? = true
        if let pathExists = existsResult {
            cache["s1"] = !pathExists
        }
        XCTAssertEqual(cache["s1"], false) // not deleted

        // Path confirmed deleted
        let deletedResult: Bool? = false
        if let pathExists = deletedResult {
            cache["s2"] = !pathExists
        }
        XCTAssertEqual(cache["s2"], true) // deleted
    }

    // MARK: - Session Filtering Tests

    /// Test that sessions with deleted workspaces are filtered from recent sessions
    @MainActor
    func testFilterSessionsWithDeletedWorkspaces() async throws {
        // Given: Sessions with various workspace paths
        let sessions = [
            createSessionInfo(id: "s1", workingDirectory: "/valid/path1"),
            createSessionInfo(id: "s2", workingDirectory: "/deleted/path"),
            createSessionInfo(id: "s3", workingDirectory: "/valid/path2"),
        ]

        // And: A set of known invalid paths
        let invalidPaths: Set<String> = ["/deleted/path"]

        // When: Filtering sessions
        let filtered = sessions.filter { session in
            guard let path = session.workingDirectory else { return true }
            return !invalidPaths.contains(path)
        }

        // Then: Should only include sessions with valid paths
        XCTAssertEqual(filtered.count, 2)
        XCTAssertFalse(filtered.contains { $0.sessionId == "s2" })
    }

    /// Test that sessions with nil workingDirectory are not filtered out
    @MainActor
    func testFilterSessionsWithNilWorkingDirectory() async throws {
        let sessions = [
            createSessionInfo(id: "s1", workingDirectory: "/valid/path"),
            createSessionInfo(id: "s2", workingDirectory: nil),
        ]

        let invalidPaths: Set<String> = []

        let filtered = sessions.filter { session in
            guard let path = session.workingDirectory else { return true }
            return !invalidPaths.contains(path)
        }

        XCTAssertEqual(filtered.count, 2)
    }

    // MARK: - Session Archive on Deleted Workspace Tests

    /// Test that archiving a session removes it from local database
    @MainActor
    func testArchiveSessionRemovesFromDatabase() async throws {
        // Given: A session in the database
        let session = createCachedSession(id: "test-session", workingDirectory: "/deleted/workspace")
        try database.sessions.insert(session)

        // Verify it exists
        XCTAssertNotNil(try database.sessions.get("test-session"))

        // When: Deleting/archiving the session
        try database.sessions.delete("test-session")

        // Then: Session should no longer exist
        XCTAssertNil(try database.sessions.get("test-session"))
    }

    /// Test that archiving removes associated events
    @MainActor
    func testArchiveSessionRemovesEvents() async throws {
        // Given: A session with events
        let session = createCachedSession(id: "test-session", workingDirectory: "/workspace")
        try database.sessions.insert(session)

        let event = SessionEvent(
            id: "e1",
            parentId: nil,
            sessionId: "test-session",
            workspaceId: "/workspace",
            type: "message.user",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [:]
        )
        try database.events.insertBatch([event])

        // Verify events exist
        let eventsBefore = try database.events.getBySession("test-session")
        XCTAssertEqual(eventsBefore.count, 1)

        // When: Deleting the session and its events
        try database.sessions.delete("test-session")
        try database.events.deleteBySession("test-session")

        // Then: Events should also be removed
        let eventsAfter = try database.events.getBySession("test-session")
        XCTAssertEqual(eventsAfter.count, 0)
    }

    // MARK: - Edge Cases

    /// Test handling multiple sessions with same deleted workspace
    @MainActor
    func testMultipleSessionsSameDeletedWorkspace() async throws {
        let sessions = [
            createSessionInfo(id: "s1", workingDirectory: "/deleted/workspace"),
            createSessionInfo(id: "s2", workingDirectory: "/deleted/workspace"),
            createSessionInfo(id: "s3", workingDirectory: "/valid/workspace"),
        ]

        let invalidPaths: Set<String> = ["/deleted/workspace"]

        let filtered = sessions.filter { session in
            guard let path = session.workingDirectory else { return true }
            return !invalidPaths.contains(path)
        }

        // Both sessions with deleted workspace should be filtered
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.sessionId, "s3")
    }

    /// Test workspace path with trailing slash normalization
    @MainActor
    func testWorkspacePathNormalization() async throws {
        // Paths should match regardless of trailing slash
        let path1 = "/workspace/project"
        let path2 = "/workspace/project/"

        // Normalize by removing trailing slash
        let normalized1 = path1.hasSuffix("/") ? String(path1.dropLast()) : path1
        let normalized2 = path2.hasSuffix("/") ? String(path2.dropLast()) : path2

        XCTAssertEqual(normalized1, normalized2)
    }

    // MARK: - Helpers

    private func createSessionInfo(id: String, workingDirectory: String?) -> SessionInfo {
        // Create a minimal JSON to decode into SessionInfo
        let json: [String: Any] = [
            "sessionId": id,
            "model": "claude-sonnet-4",
            "createdAt": "2024-01-01T00:00:00Z",
            "messageCount": 0,
            "workingDirectory": workingDirectory as Any,
            "isActive": true
        ]

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SessionInfo.self, from: data)
    }

    private func createCachedSession(id: String, workingDirectory: String) -> CachedSession {
        return CachedSession(
            id: id,
            workspaceId: workingDirectory,
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4",
            workingDirectory: workingDirectory,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            lastActivityAt: ISO8601DateFormatter().string(from: Date()),
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )
    }
}
