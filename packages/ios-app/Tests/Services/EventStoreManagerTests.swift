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
        let sessionNoTitle = createTestSession(id: "s2", title: nil, workingDirectory: "/Users/test/project")
        XCTAssertEqual(sessionNoTitle.displayTitle, "project")
    }

    func testCachedSessionIsEnded() {
        // Active session (no endedAt)
        let activeSession = createTestSession(id: "s1", endedAt: nil)
        XCTAssertFalse(activeSession.isEnded)

        // Ended session
        let endedSession = createTestSession(id: "s2", endedAt: "2024-01-01T00:00:00Z")
        XCTAssertTrue(endedSession.isEnded)
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

    // MARK: - Helper

    private func createTestSession(
        id: String,
        title: String? = nil,
        workingDirectory: String = "/test/dir",
        endedAt: String? = nil,
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
            endedAt: endedAt,
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
            type: "tool.call",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [
                "toolName": AnyCodable("Bash"),
                "arguments": AnyCodable(["command": "ls -la"])
            ]
        )

        XCTAssertNotNil(event.payload["toolName"])
        XCTAssertNotNil(event.payload["arguments"])
    }
}

// MARK: - EventTreeNode Tests

@MainActor
final class EventTreeNodeTests: XCTestCase {

    func testEventTreeNodeCreation() {
        let node = EventTreeNode(
            id: "node-1",
            parentId: nil,
            type: "message.user",
            timestamp: "2024-01-01T00:00:00Z",
            summary: "User message",
            hasChildren: true,
            childCount: 2,
            depth: 0,
            isBranchPoint: false,
            isHead: false
        )

        XCTAssertEqual(node.id, "node-1")
        XCTAssertNil(node.parentId)
        XCTAssertEqual(node.type, "message.user")
        XCTAssertTrue(node.hasChildren)
        XCTAssertEqual(node.childCount, 2)
        XCTAssertEqual(node.depth, 0)
    }

    func testEventTreeNodeBranchPoint() {
        let branchNode = EventTreeNode(
            id: "branch-1",
            parentId: "parent-1",
            type: "message.assistant",
            timestamp: "2024-01-01T00:00:00Z",
            summary: "Branch point",
            hasChildren: true,
            childCount: 3,
            depth: 1,
            isBranchPoint: true,
            isHead: false
        )

        XCTAssertTrue(branchNode.isBranchPoint)
        XCTAssertEqual(branchNode.childCount, 3)
    }

    func testEventTreeNodeHead() {
        let headNode = EventTreeNode(
            id: "head-1",
            parentId: "parent-1",
            type: "message.assistant",
            timestamp: "2024-01-01T00:00:00Z",
            summary: "Head node",
            hasChildren: false,
            childCount: 0,
            depth: 5,
            isBranchPoint: false,
            isHead: true
        )

        XCTAssertTrue(headNode.isHead)
        XCTAssertFalse(headNode.hasChildren)
    }
}
