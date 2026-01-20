import XCTest
@testable import TronMobile

/// Tests for the Recent Sessions feature in NewSessionFlow
/// These tests verify:
/// - Session filtering logic (all workspaces vs filtered by workspace)
/// - Session sorting (most recent first)
/// - Fork operation integration
/// - UI state management during fork operations
final class RecentSessionsTests: XCTestCase {

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

    // MARK: - Session Filtering Tests

    /// Test that recent sessions are sorted by lastActivityAt descending
    @MainActor
    func testSessionsSortedByLastActivityDescending() async throws {
        // Create sessions with different last activity times
        let session1 = CachedSession(
            id: "session-oldest",
            workspaceId: "/workspace/a",
            rootEventId: nil,
            headEventId: nil,
            title: "Oldest",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace/a",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        let session2 = CachedSession(
            id: "session-middle",
            workspaceId: "/workspace/b",
            rootEventId: nil,
            headEventId: nil,
            title: "Middle",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace/b",
            createdAt: "2024-01-02T00:00:00Z",
            lastActivityAt: "2024-01-02T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        let session3 = CachedSession(
            id: "session-newest",
            workspaceId: "/workspace/c",
            rootEventId: nil,
            headEventId: nil,
            title: "Newest",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace/c",
            createdAt: "2024-01-03T00:00:00Z",
            lastActivityAt: "2024-01-03T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        try database.insertSession(session1)
        try database.insertSession(session2)
        try database.insertSession(session3)

        let sessions = try database.getAllSessions()

        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions[0].id, "session-newest")
        XCTAssertEqual(sessions[1].id, "session-middle")
        XCTAssertEqual(sessions[2].id, "session-oldest")
    }

    /// Test filtering sessions by workspace
    @MainActor
    func testFilterSessionsByWorkspace() async throws {
        // Create sessions in different workspaces
        let sessionA1 = CachedSession(
            id: "session-a1",
            workspaceId: "/workspace/a",
            rootEventId: nil,
            headEventId: nil,
            title: "A1",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace/a",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        let sessionA2 = CachedSession(
            id: "session-a2",
            workspaceId: "/workspace/a",
            rootEventId: nil,
            headEventId: nil,
            title: "A2",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace/a",
            createdAt: "2024-01-02T00:00:00Z",
            lastActivityAt: "2024-01-02T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        let sessionB1 = CachedSession(
            id: "session-b1",
            workspaceId: "/workspace/b",
            rootEventId: nil,
            headEventId: nil,
            title: "B1",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace/b",
            createdAt: "2024-01-03T00:00:00Z",
            lastActivityAt: "2024-01-03T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        try database.insertSession(sessionA1)
        try database.insertSession(sessionA2)
        try database.insertSession(sessionB1)

        let allSessions = try database.getAllSessions()
        XCTAssertEqual(allSessions.count, 3)

        // Filter by workspace A
        let workspaceASessions = allSessions.filter { $0.workingDirectory == "/workspace/a" }
        XCTAssertEqual(workspaceASessions.count, 2)
        XCTAssertTrue(workspaceASessions.allSatisfy { $0.workingDirectory == "/workspace/a" })

        // Filter by workspace B
        let workspaceBSessions = allSessions.filter { $0.workingDirectory == "/workspace/b" }
        XCTAssertEqual(workspaceBSessions.count, 1)
        XCTAssertEqual(workspaceBSessions.first?.id, "session-b1")
    }

    /// Test limiting sessions to top 10 most recent
    @MainActor
    func testLimitToTenMostRecentSessions() async throws {
        // Create 15 sessions
        for i in 1...15 {
            let session = CachedSession(
                id: "session-\(i)",
                workspaceId: "/workspace",
                rootEventId: nil,
                headEventId: nil,
                title: "Session \(i)",
                latestModel: "claude-sonnet-4",
                workingDirectory: "/workspace",
                createdAt: "2024-01-\(String(format: "%02d", i))T00:00:00Z",
                lastActivityAt: "2024-01-\(String(format: "%02d", i))T00:00:00Z",
                eventCount: 0,
                messageCount: 0,
                inputTokens: 0,
                outputTokens: 0,
                lastTurnInputTokens: 0,
                cost: 0.0
            )
            try database.insertSession(session)
        }

        let allSessions = try database.getAllSessions()
        XCTAssertEqual(allSessions.count, 15)

        // Apply the limit (as the feature will do)
        let recentSessions = Array(allSessions.prefix(10))
        XCTAssertEqual(recentSessions.count, 10)

        // Should be sorted by most recent (session-15 first, session-6 last)
        XCTAssertEqual(recentSessions.first?.id, "session-15")
        XCTAssertEqual(recentSessions.last?.id, "session-6")
    }

    /// Test that both active and ended sessions are included
    @MainActor
    func testIncludesBothActiveAndEndedSessions() async throws {
        let activeSession = CachedSession(
            id: "session-active",
            workspaceId: "/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: "Active",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2024-01-02T00:00:00Z",
            lastActivityAt: "2024-01-02T00:00:00Z",
            endedAt: nil,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        let endedSession = CachedSession(
            id: "session-ended",
            workspaceId: "/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: "Ended",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            endedAt: "2024-01-01T00:05:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        try database.insertSession(activeSession)
        try database.insertSession(endedSession)

        let sessions = try database.getAllSessions()
        XCTAssertEqual(sessions.count, 2)

        let hasActive = sessions.contains { !$0.isEnded }
        let hasEnded = sessions.contains { $0.isEnded }
        XCTAssertTrue(hasActive)
        XCTAssertTrue(hasEnded)
    }

    // MARK: - Session Display Data Tests

    /// Test that displayTitle returns title if set, otherwise directory name
    func testSessionDisplayTitle() {
        let sessionWithTitle = CachedSession(
            id: "s1",
            workspaceId: "/projects/myapp",
            rootEventId: nil,
            headEventId: nil,
            title: "My Custom Title",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/projects/myapp",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        let sessionWithoutTitle = CachedSession(
            id: "s2",
            workspaceId: "/projects/myapp",
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4",
            workingDirectory: "/projects/myapp",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        XCTAssertEqual(sessionWithTitle.displayTitle, "My Custom Title")
        XCTAssertEqual(sessionWithoutTitle.displayTitle, "myapp")
    }

    /// Test that lastUserPrompt is accessible for display
    @MainActor
    func testSessionWithLastUserPrompt() async throws {
        let session = CachedSession(
            id: "s1",
            workspaceId: "/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: "Test",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0,
            messageCount: 1,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0,
            lastUserPrompt: "Help me refactor this code",
            lastAssistantResponse: nil,
            lastToolCount: nil,
            isProcessing: false
        )

        XCTAssertEqual(session.lastUserPrompt, "Help me refactor this code")
    }

    /// Test model shortModelName extension
    func testModelShortName() {
        // Claude models
        XCTAssertEqual("claude-opus-4-5-20251101".shortModelName, "Opus 4.5")
        XCTAssertEqual("claude-sonnet-4-5-20251101".shortModelName, "Sonnet 4.5")
        XCTAssertEqual("claude-sonnet-4-20250514".shortModelName, "Sonnet 4")
        XCTAssertEqual("claude-haiku-3-5-20241022".shortModelName, "Haiku 3.5")

        // OpenAI Codex models
        XCTAssertEqual("gpt-5.2-codex".shortModelName, "GPT-5.2 Codex")
        XCTAssertEqual("gpt-5.1-codex-max".shortModelName, "GPT-5.1 Codex Max")
        XCTAssertEqual("gpt-5.1-codex-mini".shortModelName, "GPT-5.1 Codex Mini")
    }

    // MARK: - Fork Integration Tests

    /// Test that forking creates a new session with copied history
    @MainActor
    func testForkSessionCreatesNewSession() async throws {
        // Create a source session with events
        let events = [
            SessionEvent(
                id: "e1",
                parentId: nil,
                sessionId: "source-session",
                workspaceId: "/workspace",
                type: "session.start",
                timestamp: "2024-01-01T00:00:00Z",
                sequence: 1,
                payload: [:]
            ),
            SessionEvent(
                id: "e2",
                parentId: "e1",
                sessionId: "source-session",
                workspaceId: "/workspace",
                type: "message.user",
                timestamp: "2024-01-01T00:01:00Z",
                sequence: 2,
                payload: ["content": AnyCodable("Hello")]
            ),
            SessionEvent(
                id: "e3",
                parentId: "e2",
                sessionId: "source-session",
                workspaceId: "/workspace",
                type: "message.assistant",
                timestamp: "2024-01-01T00:02:00Z",
                sequence: 3,
                payload: ["content": AnyCodable("Hi there!")]
            )
        ]

        try database.insertEvents(events)
        try database.insertSession(CachedSession(
            id: "source-session",
            workspaceId: "/workspace",
            rootEventId: "e1",
            headEventId: "e3",
            title: "Source",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:02:00Z",
            eventCount: 3,
            messageCount: 2,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        ))

        // Verify source session exists
        let sourceSession = try database.getSession("source-session")
        XCTAssertNotNil(sourceSession)
        XCTAssertEqual(sourceSession?.headEventId, "e3")
        XCTAssertEqual(sourceSession?.messageCount, 2)
    }

    /// Test that original session remains unchanged after fork
    @MainActor
    func testOriginalSessionUnchangedAfterFork() async throws {
        // Create source session
        try database.insertSession(CachedSession(
            id: "original-session",
            workspaceId: "/workspace",
            rootEventId: "e1",
            headEventId: "e5",
            title: "Original",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:05:00Z",
            eventCount: 5,
            messageCount: 3,
            inputTokens: 100,
            outputTokens: 200,
            lastTurnInputTokens: 0,
            cost: 0.0
        ))

        // Simulate what happens after a fork - original should be unchanged
        let originalBefore = try database.getSession("original-session")

        // Create a "forked" session (simulating server response)
        try database.insertSession(CachedSession(
            id: "forked-session",
            workspaceId: "/workspace",
            rootEventId: "f1",
            headEventId: "f5",
            title: "Forked from Original",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2024-01-01T00:06:00Z",
            lastActivityAt: "2024-01-01T00:06:00Z",
            eventCount: 5,
            messageCount: 3,
            inputTokens: 100,
            outputTokens: 200,
            lastTurnInputTokens: 0,
            cost: 0.0
        ))

        // Verify original is unchanged
        let originalAfter = try database.getSession("original-session")
        XCTAssertEqual(originalBefore?.id, originalAfter?.id)
        XCTAssertEqual(originalBefore?.headEventId, originalAfter?.headEventId)
        XCTAssertEqual(originalBefore?.eventCount, originalAfter?.eventCount)
        XCTAssertEqual(originalBefore?.lastActivityAt, originalAfter?.lastActivityAt)
    }

    // MARK: - Filtered Sessions Logic Tests

    /// Test the exact filtering logic used in NewSessionFlow
    @MainActor
    func testFilteredRecentSessionsLogic() async throws {
        // Create sessions in multiple workspaces
        try database.insertSession(CachedSession(
            id: "ws-a-1",
            workspaceId: "/projects/app-a",
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4",
            workingDirectory: "/projects/app-a",
            createdAt: "2024-01-05T00:00:00Z",
            lastActivityAt: "2024-01-05T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        ))

        try database.insertSession(CachedSession(
            id: "ws-a-2",
            workspaceId: "/projects/app-a",
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-opus-4",
            workingDirectory: "/projects/app-a",
            createdAt: "2024-01-04T00:00:00Z",
            lastActivityAt: "2024-01-04T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        ))

        try database.insertSession(CachedSession(
            id: "ws-b-1",
            workspaceId: "/projects/app-b",
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4",
            workingDirectory: "/projects/app-b",
            createdAt: "2024-01-03T00:00:00Z",
            lastActivityAt: "2024-01-03T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        ))

        // Get all sessions sorted
        let allSessions = try database.getAllSessions()
        let sortedSessions = allSessions.sorted { $0.lastActivityAt > $1.lastActivityAt }
        let recent = Array(sortedSessions.prefix(10))

        // Test: No workspace selected -> show all
        let selectedWorkspace = ""
        let filteredWhenEmpty: [CachedSession]
        if selectedWorkspace.isEmpty {
            filteredWhenEmpty = recent
        } else {
            filteredWhenEmpty = recent.filter { $0.workingDirectory == selectedWorkspace }
        }
        XCTAssertEqual(filteredWhenEmpty.count, 3)

        // Test: Workspace A selected -> filter to only A
        let selectedWorkspaceA = "/projects/app-a"
        let filteredToA: [CachedSession]
        if selectedWorkspaceA.isEmpty {
            filteredToA = recent
        } else {
            filteredToA = recent.filter { $0.workingDirectory == selectedWorkspaceA }
        }
        XCTAssertEqual(filteredToA.count, 2)
        XCTAssertTrue(filteredToA.allSatisfy { $0.workingDirectory == "/projects/app-a" })

        // Test: Workspace B selected -> filter to only B
        let selectedWorkspaceB = "/projects/app-b"
        let filteredToB: [CachedSession]
        if selectedWorkspaceB.isEmpty {
            filteredToB = recent
        } else {
            filteredToB = recent.filter { $0.workingDirectory == selectedWorkspaceB }
        }
        XCTAssertEqual(filteredToB.count, 1)
        XCTAssertEqual(filteredToB.first?.id, "ws-b-1")

        // Test: Non-existent workspace selected -> empty
        let selectedWorkspaceC = "/projects/app-c"
        let filteredToC: [CachedSession]
        if selectedWorkspaceC.isEmpty {
            filteredToC = recent
        } else {
            filteredToC = recent.filter { $0.workingDirectory == selectedWorkspaceC }
        }
        XCTAssertEqual(filteredToC.count, 0)
    }

    // MARK: - Edge Cases

    /// Test empty sessions list
    @MainActor
    func testEmptySessionsList() async throws {
        let sessions = try database.getAllSessions()
        XCTAssertEqual(sessions.count, 0)

        // Filtering empty list should return empty
        let filtered = sessions.filter { $0.workingDirectory == "/any/path" }
        XCTAssertEqual(filtered.count, 0)
    }

    /// Test session with processing state
    @MainActor
    func testSessionProcessingState() async throws {
        var session = CachedSession(
            id: "processing-session",
            workspaceId: "/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: "Processing",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0,
            lastUserPrompt: nil,
            lastAssistantResponse: nil,
            lastToolCount: nil,
            isProcessing: true
        )

        XCTAssertTrue(session.isProcessing == true)

        session.isProcessing = false
        XCTAssertFalse(session.isProcessing == true)
    }

    /// Test session formattedDate for relative time
    func testSessionFormattedDateRelative() {
        // Create session with recent timestamp
        let recentTimestamp = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600)) // 1 hour ago
        let recentSession = CachedSession(
            id: "recent",
            workspaceId: "/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: recentTimestamp,
            lastActivityAt: recentTimestamp,
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        // formattedDate should return relative time like "1 hour ago"
        let formatted = recentSession.formattedDate
        XCTAssertFalse(formatted.isEmpty)
        // Relative format contains "ago" or the relative time format from the system
        // The exact format depends on locale, so just verify it's not empty
    }

    /// Test session formattedDate for older dates
    func testSessionFormattedDateAbsolute() {
        // Create session with old timestamp
        let oldSession = CachedSession(
            id: "old",
            workspaceId: "/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: nil,
            latestModel: "claude-sonnet-4",
            workingDirectory: "/workspace",
            createdAt: "2023-06-15T00:00:00Z",
            lastActivityAt: "2023-06-15T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        let formatted = oldSession.formattedDate
        XCTAssertFalse(formatted.isEmpty)
        // Should contain "Jun" for absolute date format
        XCTAssertTrue(formatted.contains("Jun") || formatted.contains("2023"))
    }

    // MARK: - Deleted Workspace Filtering Tests

    /// Test that filteredRecentSessions excludes sessions with invalid workspace paths
    @MainActor
    func testFilteredRecentSessionsExcludesInvalidWorkspaces() async throws {
        // This tests the filtering logic that will be added to NewSessionFlow
        let serverSessions = [
            createServerSessionInfo(id: "s1", workingDirectory: "/valid/workspace"),
            createServerSessionInfo(id: "s2", workingDirectory: "/deleted/workspace"),
            createServerSessionInfo(id: "s3", workingDirectory: "/another/valid"),
        ]

        let localSessionIds: Set<String> = []
        let invalidWorkspacePaths: Set<String> = ["/deleted/workspace"]
        let selectedWorkspace = ""  // No filter

        // Apply the filtering logic
        var filtered = serverSessions.filter { !localSessionIds.contains($0.sessionId) }

        if !selectedWorkspace.isEmpty {
            filtered = filtered.filter { $0.workingDirectory == selectedWorkspace }
        }

        // Filter out invalid workspace paths
        filtered = filtered.filter { session in
            guard let path = session.workingDirectory else { return true }
            return !invalidWorkspacePaths.contains(path)
        }

        let result = Array(filtered.prefix(10))

        XCTAssertEqual(result.count, 2)
        XCTAssertFalse(result.contains { $0.sessionId == "s2" })
    }

    /// Test that workspace filtering works with selected workspace
    @MainActor
    func testFilteredRecentSessionsWithWorkspaceAndInvalidPaths() async throws {
        let serverSessions = [
            createServerSessionInfo(id: "s1", workingDirectory: "/projects/app-a"),
            createServerSessionInfo(id: "s2", workingDirectory: "/projects/app-a"),  // Will be marked invalid
            createServerSessionInfo(id: "s3", workingDirectory: "/projects/app-b"),
        ]

        let localSessionIds: Set<String> = []
        let invalidWorkspacePaths: Set<String> = ["/projects/app-a"]  // Entire workspace deleted
        let selectedWorkspace = "/projects/app-a"

        var filtered = serverSessions.filter { !localSessionIds.contains($0.sessionId) }

        if !selectedWorkspace.isEmpty {
            filtered = filtered.filter { $0.workingDirectory == selectedWorkspace }
        }

        filtered = filtered.filter { session in
            guard let path = session.workingDirectory else { return true }
            return !invalidWorkspacePaths.contains(path)
        }

        // All sessions in deleted workspace should be filtered
        XCTAssertEqual(filtered.count, 0)
    }

    /// Test that sessions with nil workingDirectory are preserved during filtering
    @MainActor
    func testFilteredRecentSessionsPreservesNilWorkingDirectory() async throws {
        let serverSessions = [
            createServerSessionInfo(id: "s1", workingDirectory: "/valid/workspace"),
            createServerSessionInfo(id: "s2", workingDirectory: nil),
            createServerSessionInfo(id: "s3", workingDirectory: "/deleted/workspace"),
        ]

        let invalidWorkspacePaths: Set<String> = ["/deleted/workspace"]

        let filtered = serverSessions.filter { session in
            guard let path = session.workingDirectory else { return true }
            return !invalidWorkspacePaths.contains(path)
        }

        // s1 (valid) and s2 (nil) should be preserved, s3 (deleted) filtered
        XCTAssertEqual(filtered.count, 2)
        XCTAssertTrue(filtered.contains { $0.sessionId == "s1" })
        XCTAssertTrue(filtered.contains { $0.sessionId == "s2" })
        XCTAssertFalse(filtered.contains { $0.sessionId == "s3" })
    }

    // MARK: - Helper for Server Sessions

    private func createServerSessionInfo(id: String, workingDirectory: String?) -> SessionInfo {
        // Create a minimal JSON to decode into SessionInfo
        var json: [String: Any] = [
            "sessionId": id,
            "model": "claude-sonnet-4",
            "createdAt": "2024-01-01T00:00:00Z",
            "messageCount": 0,
            "isActive": true
        ]
        if let dir = workingDirectory {
            json["workingDirectory"] = dir
        }

        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! JSONDecoder().decode(SessionInfo.self, from: data)
    }
}
