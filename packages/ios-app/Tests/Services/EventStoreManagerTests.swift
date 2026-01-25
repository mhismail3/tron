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

// MARK: - TurnContentCache Tests

@MainActor
final class TurnContentCacheTests: XCTestCase {

    func testCacheTurnContent_StoresMessages() {
        // Given
        let cache = TurnContentCache()
        let sessionId = "test-session-1"
        let messages: [[String: Any]] = [
            ["role": "user", "content": "Hello"],
            ["role": "assistant", "content": [["type": "text", "text": "Hi"]]]
        ]

        // When
        cache.store(sessionId: sessionId, turnNumber: 1, messages: messages)

        // Then
        let retrieved = cache.get(sessionId: sessionId)
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.count, 2)
    }

    func testGetCachedTurnContent_ReturnsNilForMissingSession() {
        // Given
        let cache = TurnContentCache()

        // When
        let result = cache.get(sessionId: "nonexistent")

        // Then
        XCTAssertNil(result)
    }

    func testClearCachedTurnContent_RemovesEntry() {
        // Given
        let cache = TurnContentCache()
        let sessionId = "test-session-1"
        cache.store(sessionId: sessionId, turnNumber: 1, messages: [["role": "user", "content": "test"]])

        // When
        cache.clear(sessionId: sessionId)

        // Then
        XCTAssertNil(cache.get(sessionId: sessionId))
    }

    func testCacheExpiry_RemovesExpiredEntries() {
        // Given
        let cache = TurnContentCache(expiry: 0.1) // 100ms expiry for testing
        let sessionId = "test-session-1"
        cache.store(sessionId: sessionId, turnNumber: 1, messages: [["role": "user", "content": "test"]])

        // When - wait for expiry
        let expectation = XCTestExpectation(description: "Cache expires")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)

        // Then
        XCTAssertNil(cache.get(sessionId: sessionId))
    }

    func testMaxCachedSessions_EvictsOldest() {
        // Given
        let cache = TurnContentCache(maxEntries: 2, expiry: 60)

        // When - add 3 sessions
        cache.store(sessionId: "session-1", turnNumber: 1, messages: [["role": "user", "content": "1"]])
        cache.store(sessionId: "session-2", turnNumber: 1, messages: [["role": "user", "content": "2"]])
        cache.store(sessionId: "session-3", turnNumber: 1, messages: [["role": "user", "content": "3"]])

        // Then - oldest should be evicted
        XCTAssertNil(cache.get(sessionId: "session-1"))
        XCTAssertNotNil(cache.get(sessionId: "session-2"))
        XCTAssertNotNil(cache.get(sessionId: "session-3"))
    }

    func testCheckForToolBlocks_DetectsToolUse() {
        // Given
        let cache = TurnContentCache()
        let payloadWithTools: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": "Hello"],
                ["type": "tool_use", "id": "tool_1", "name": "Bash"]
            ])
        ]
        let payloadWithoutTools: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": "Hello"]
            ])
        ]
        let payloadWithString: [String: AnyCodable] = [
            "content": AnyCodable("Just text")
        ]

        // Then
        XCTAssertTrue(cache.checkForToolBlocks(in: payloadWithTools))
        XCTAssertFalse(cache.checkForToolBlocks(in: payloadWithoutTools))
        XCTAssertFalse(cache.checkForToolBlocks(in: payloadWithString))
    }

    func testCheckForToolBlocks_DetectsToolResult() {
        // Given
        let cache = TurnContentCache()
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "tool_result", "tool_use_id": "tool_1", "content": "output"]
            ])
        ]

        // Then
        XCTAssertTrue(cache.checkForToolBlocks(in: payload))
    }
}

// MARK: - ContentExtractor Tests

@MainActor
final class ContentExtractorTests: XCTestCase {

    func testExtractText_FromString() {
        let text = ContentExtractor.extractText(from: "Hello world")
        XCTAssertEqual(text, "Hello world")
    }

    func testExtractText_FromContentBlocks() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Hello "],
            ["type": "text", "text": "world"]
        ]
        let text = ContentExtractor.extractText(from: content)
        XCTAssertEqual(text, "Hello world")
    }

    func testExtractText_FromMixedBlocks() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Hello"],
            ["type": "tool_use", "id": "t1", "name": "Bash"],
            ["type": "text", "text": " world"]
        ]
        let text = ContentExtractor.extractText(from: content)
        XCTAssertEqual(text, "Hello world")
    }

    func testExtractText_FromNil() {
        let text = ContentExtractor.extractText(from: nil)
        XCTAssertEqual(text, "")
    }

    func testExtractToolCount_FromContentBlocks() {
        let content: [[String: Any]] = [
            ["type": "text", "text": "Hello"],
            ["type": "tool_use", "id": "t1", "name": "Bash"],
            ["type": "tool_use", "id": "t2", "name": "Read"]
        ]
        let count = ContentExtractor.extractToolCount(from: content)
        XCTAssertEqual(count, 2)
    }

    func testExtractToolCount_FromStringContent() {
        let count = ContentExtractor.extractToolCount(from: "Just text")
        XCTAssertEqual(count, 0)
    }

    func testExtractDashboardInfo_FromEvents() {
        let userEvent = SessionEvent(
            id: "e1",
            parentId: nil,
            sessionId: "s1",
            workspaceId: "/test",
            type: "message.user",
            timestamp: "2024-01-01T00:00:00Z",
            sequence: 1,
            payload: ["content": AnyCodable("What is 2+2?")]
        )
        let assistantEvent = SessionEvent(
            id: "e2",
            parentId: "e1",
            sessionId: "s1",
            workspaceId: "/test",
            type: "message.assistant",
            timestamp: "2024-01-01T00:00:01Z",
            sequence: 2,
            payload: ["content": AnyCodable([
                ["type": "text", "text": "The answer is 4"],
                ["type": "tool_use", "id": "t1", "name": "Calculator"]
            ])]
        )

        let info = ContentExtractor.extractDashboardInfo(from: [userEvent, assistantEvent])

        XCTAssertEqual(info.lastUserPrompt, "What is 2+2?")
        XCTAssertEqual(info.lastAssistantResponse, "The answer is 4")
        XCTAssertEqual(info.lastToolCount, 1)
    }

    // MARK: - Payload-Based Methods Tests

    func testHasToolBlocks_DetectsToolUse() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": "Hello"],
                ["type": "tool_use", "id": "tool_1", "name": "Bash"]
            ])
        ]

        XCTAssertTrue(ContentExtractor.hasToolBlocks(in: payload))
    }

    func testHasToolBlocks_DetectsToolResult() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "tool_result", "tool_use_id": "tool_1", "content": "output"]
            ])
        ]

        XCTAssertTrue(ContentExtractor.hasToolBlocks(in: payload))
    }

    func testHasToolBlocks_ReturnsFalseForTextOnly() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": "Hello world"]
            ])
        ]

        XCTAssertFalse(ContentExtractor.hasToolBlocks(in: payload))
    }

    func testHasToolBlocks_ReturnsFalseForStringContent() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable("Just a string")
        ]

        XCTAssertFalse(ContentExtractor.hasToolBlocks(in: payload))
    }

    func testHasToolBlocks_ReturnsFalseForEmptyPayload() {
        let payload: [String: AnyCodable] = [:]

        XCTAssertFalse(ContentExtractor.hasToolBlocks(in: payload))
    }

    func testExtractTextForMatching_FromContentBlocks() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "text", "text": "Hello "],
                ["type": "tool_use", "id": "t1", "name": "Bash"],
                ["type": "text", "text": "world"]
            ])
        ]

        let text = ContentExtractor.extractTextForMatching(from: payload)
        XCTAssertEqual(text, "Hello world")
    }

    func testExtractTextForMatching_FromStringContent() {
        let payload: [String: AnyCodable] = [
            "content": AnyCodable("Hello world")
        ]

        let text = ContentExtractor.extractTextForMatching(from: payload)
        XCTAssertEqual(text, "Hello world")
    }

    func testExtractTextForMatching_FromEmptyPayload() {
        let payload: [String: AnyCodable] = [:]

        let text = ContentExtractor.extractTextForMatching(from: payload)
        XCTAssertEqual(text, "")
    }
}

// MARK: - SessionStateChecker Tests

@MainActor
final class SessionStateCheckerTests: XCTestCase {

    func testProcessingStateTracking() {
        // Test that we can track processing state independently
        var processingIds: Set<String> = []

        // Add session
        processingIds.insert("session-1")
        XCTAssertTrue(processingIds.contains("session-1"))

        // Remove session
        processingIds.remove("session-1")
        XCTAssertFalse(processingIds.contains("session-1"))
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
