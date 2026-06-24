import XCTest
@testable import TronMobile

/// Tests for EventStoreManager-related types and data structures
/// Note: EventStoreManager integration tests require actual instances since it uses concrete types.
/// These tests focus on the supporting data structures and types.
@MainActor
final class CachedSessionTests: XCTestCase {

    func testCachedSessionIdentifiable() {
        let session = createTestSession(id: "test-123")
        XCTAssertEqual(session.id, "test-123")
    }

    func testCachedSessionDisplayTitle() {
        // Session with title
        let sessionWithTitle = createTestSession(id: "s1", title: "My Project")
        XCTAssertEqual(sessionWithTitle.displayTitle, "My Project")

        // Session without title uses working directory
        let sessionNoTitle = createTestSession(id: "s2", title: nil, workingDirectory: "/tmp/tron-fixtures/test/project")
        XCTAssertEqual(sessionNoTitle.displayTitle, "project")
    }

    func testCachedSessionIsArchived() {
        // Non-archived session (no archivedAt)
        let activeSession = createTestSession(id: "s1", archivedAt: nil)
        XCTAssertFalse(activeSession.isArchived)

        // Archived session
        let archivedSession = createTestSession(id: "s2", archivedAt: "2024-01-01T00:00:00Z")
        XCTAssertTrue(archivedSession.isArchived)
    }

    func testCachedSessionTokenCounts() {
        let session = createTestSession(
            id: "s1",
            inputTokens: 1000,
            outputTokens: 500,
            cacheReadTokens: 200,
            cacheCreationTokens: 100
        )

        XCTAssertEqual(session.inputTokens, 1000)
        XCTAssertEqual(session.outputTokens, 500)
        XCTAssertEqual(session.cacheReadTokens, 200)
        XCTAssertEqual(session.cacheCreationTokens, 100)
    }

    func testLocalNewSessionCacheDoesNotPromoteWorkspaceNameToTitle() {
        let session = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "new-local-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: nil,
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(session.title)
        XCTAssertEqual(session.workingDirectory, "/tmp/tron-fixtures/Project")
        XCTAssertEqual(session.listTitle, "New Session")
    }

    func testChatLocalNewSessionCacheKeepsAcceptedChatTitle() {
        let session = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "chat-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: "chat",
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertEqual(session.title, "Chat")
        XCTAssertEqual(session.source, "chat")
        XCTAssertEqual(session.listTitle, "New Session")
    }

    func testLocalForkCacheDoesNotPromoteWorkspaceNameToTitle() {
        let untitledSource = createTestSession(
            id: "untitled-source-session",
            title: nil,
            workingDirectory: "/tmp/tron-fixtures/ForkWorkspace"
        )

        let untitledFork = EventStoreManager.makeLocalForkSessionCache(
            result: SessionForkResult(
                newSessionId: "untitled-forked-session",
                forkedFromEventId: "source-event",
                forkedFromSessionId: "untitled-source-session",
                rootEventId: "fork-root"
            ),
            sourceSession: untitledSource,
            now: "2026-06-23T12:05:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(untitledFork.title)
        XCTAssertEqual(untitledFork.workingDirectory, "/tmp/tron-fixtures/ForkWorkspace")
        XCTAssertEqual(untitledFork.listTitle, "New Session")

        var sourceWithPrompt = createTestSession(
            id: "source-session",
            title: nil,
            workingDirectory: "/tmp/tron-fixtures/ForkWorkspace"
        )
        sourceWithPrompt.lastUserPrompt = "Summarize the cache audit finding"
        sourceWithPrompt.lastAssistantResponse = "Working on it"
        sourceWithPrompt.source = nil
        sourceWithPrompt.profile = "default"

        let promptFallbackFork = EventStoreManager.makeLocalForkSessionCache(
            result: SessionForkResult(
                newSessionId: "forked-session",
                forkedFromEventId: "source-event",
                forkedFromSessionId: "source-session",
                rootEventId: "fork-root"
            ),
            sourceSession: sourceWithPrompt,
            now: "2026-06-23T12:05:00Z",
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(promptFallbackFork.title)
        XCTAssertEqual(promptFallbackFork.workingDirectory, "/tmp/tron-fixtures/ForkWorkspace")
        XCTAssertEqual(promptFallbackFork.lastUserPrompt, "Summarize the cache audit finding")
        XCTAssertEqual(promptFallbackFork.profile, "default")
        XCTAssertEqual(promptFallbackFork.listTitle, "Summarize the cache audit finding")
    }

    func testServerGeneratedTitleReplacesLocalFallbackDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(eventDB: database, engineClient: engineClient)
        let existing = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "new-local-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: nil,
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: "Fix session list title fallback",
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertEqual(merged.title, "Fix session list title fallback")
        XCTAssertEqual(merged.listTitle, "Fix session list title fallback")
    }

    func testServerGeneratedTitleReplacesPreFixWorkspaceFallbackDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(eventDB: database, engineClient: engineClient)
        let existing = createTestSession(
            id: "pre-fix-session",
            title: "Project",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: "Fix session list title fallback",
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertEqual(merged.title, "Fix session list title fallback")
        XCTAssertEqual(merged.listTitle, "Fix session list title fallback")
    }

    func testNilServerTitlePreservesLocalNewSessionFallbackDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(eventDB: database, engineClient: engineClient)
        let existing = EventStoreManager.makeLocalNewSessionCache(
            sessionId: "new-local-session",
            workspaceId: "/tmp/tron-fixtures/Project",
            model: "gpt-5",
            workingDirectory: "/tmp/tron-fixtures/Project",
            source: nil,
            profile: nil,
            now: "2026-06-23T12:00:00Z",
            serverOrigin: "localhost:8080"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.listTitle, "New Session")
    }

    func testNilServerTitleClearsPreFixWorkspaceFallbackDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(eventDB: database, engineClient: engineClient)
        let existing = createTestSession(
            id: "pre-fix-session",
            title: "Project",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.listTitle, "New Session")
    }

    func testNilServerTitleClearsPreFixWorkspaceFallbackAndUsesPromptFallbackDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(eventDB: database, engineClient: engineClient)
        let existing = createTestSession(
            id: "pre-fix-session",
            title: "Project",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory,
            lastUserPrompt: "Review cache title sync"
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertNil(merged.title)
        XCTAssertEqual(merged.lastUserPrompt, "Review cache title sync")
        XCTAssertEqual(merged.listTitle, "Review cache title sync")
    }

    func testNilServerTitlePreservesNonWorkspaceLocalTitleDuringMerge() {
        let database = EventDatabase(
            databasePath: NSTemporaryDirectory() + "tron-title-merge-\(UUID().uuidString).db"
        )
        let engineClient = EngineClient(serverURL: URL(string: "ws://localhost:8080/engine")!)
        let manager = EventStoreManager(eventDB: database, engineClient: engineClient)
        let existing = createTestSession(
            id: "local-title-session",
            title: "Accepted generated title",
            workingDirectory: "/tmp/tron-fixtures/Project"
        )
        let serverInfo = makeSessionInfo(
            sessionId: existing.id,
            title: nil,
            workingDirectory: existing.workingDirectory
        )

        let merged = manager.mergeSessionData(
            existing: existing,
            serverInfo: serverInfo,
            serverOrigin: "localhost:8080"
        )

        XCTAssertEqual(merged.title, "Accepted generated title")
        XCTAssertEqual(merged.listTitle, "Accepted generated title")
    }

    // MARK: - Helper

    private func createTestSession(
        id: String,
        title: String? = nil,
        workingDirectory: String = "/test/dir",
        archivedAt: String? = nil,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0
    ) -> CachedSession {
        return CachedSession(
            id: id,
            workspaceId: "/test/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: title,
            latestModel: "claude-sonnet-4-20250514",
            workingDirectory: workingDirectory,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            lastActivityAt: ISO8601DateFormatter().string(from: Date()),
            archivedAt: archivedAt,
            eventCount: 0,
            messageCount: 0,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            lastTurnInputTokens: 0,
            cacheReadTokens: cacheReadTokens,
            cacheCreationTokens: cacheCreationTokens,
            cost: 0.0,
            isProcessing: false,
            isFork: false
        )
    }

    private func makeSessionInfo(
        sessionId: String,
        title: String?,
        workingDirectory: String?,
        lastUserPrompt: String? = nil
    ) -> SessionInfo {
        SessionInfo(
            sessionId: sessionId,
            model: "gpt-5",
            createdAt: "2026-06-23T12:00:00Z",
            eventCount: 0,
            turnCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
            cost: 0,
            lastActivity: "2026-06-23T12:10:00Z",
            isActive: false,
            isArchived: false,
            workingDirectory: workingDirectory,
            parentSessionId: nil,
            title: title,
            lastUserPrompt: lastUserPrompt,
            lastAssistantResponse: nil,
            source: nil,
            profile: nil,
            isRunning: false,
            activityLines: nil
        )
    }
}

// MARK: - SyncState Tests

@MainActor
final class SyncStateTests: XCTestCase {

    func testSyncStateInitialization() {
        let state = SyncState(
            key: "session-123",
            lastSyncedEventId: "event-456",
            lastSyncTimestamp: "2024-01-01T00:00:00Z",
            pendingEventIds: ["e1", "e2"]
        )

        XCTAssertEqual(state.key, "session-123")
        XCTAssertEqual(state.lastSyncedEventId, "event-456")
        XCTAssertEqual(state.pendingEventIds.count, 2)
    }

    func testSyncStateWithNilValues() {
        let state = SyncState(
            key: "session-123",
            lastSyncedEventId: nil,
            lastSyncTimestamp: nil,
            pendingEventIds: []
        )

        XCTAssertNil(state.lastSyncedEventId)
        XCTAssertNil(state.lastSyncTimestamp)
        XCTAssertTrue(state.pendingEventIds.isEmpty)
    }
}

// MARK: - SessionEvent Tests

@MainActor
final class SessionEventTests: XCTestCase {

    func testSessionEventCreation() {
        let event = SessionEvent(
            id: "event-1",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "message.user",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: ["content": AnyCodable("Hello")]
        )

        XCTAssertEqual(event.id, "event-1")
        XCTAssertNil(event.parentId)
        XCTAssertEqual(event.sessionId, "session-1")
        XCTAssertEqual(event.type, "message.user")
        XCTAssertEqual(event.sequence, 1)
    }

    func testSessionEventWithParent() {
        let event = SessionEvent(
            id: "event-2",
            parentId: "event-1",
            sessionId: "session-1",
            workspaceId: "/test",
            type: "message.assistant",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 2,
            payload: [:]
        )

        XCTAssertEqual(event.parentId, "event-1")
    }

    func testSessionEventPayload() {
        let event = SessionEvent(
            id: "event-1",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "capability.invocation.started",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [
                "modelPrimitiveName": AnyCodable("execute"),
                "arguments": AnyCodable(["command": "ls -la"])
            ]
        )

        XCTAssertNotNil(event.payload["modelPrimitiveName"])
        XCTAssertNotNil(event.payload["arguments"])
    }
}
