import XCTest
import SQLite3
@testable import TronMobile

/// Tests for the EventDatabase SQLite store
@MainActor
final class EventDatabaseTests: XCTestCase {

    var database: EventDatabase!

    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try await database.clearAll()
    }

    override func tearDown() async throws {
        try? await database.clearAll()
        await database.close()
    }

    // MARK: - Helper

    /// Creates a tokenRecord payload for test events
    private func makeTokenRecord(
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        turn: Int = 1,
        provider: String = "anthropic",
        model: String = "claude-sonnet-4",
        cost: Double = 0
    ) -> [String: Any] {
        return [
            "source": [
                "provider": provider,
                "timestamp": "2024-01-01T00:00:00Z",
                "rawInputTokens": inputTokens,
                "rawOutputTokens": outputTokens,
                "rawCacheReadTokens": cacheReadTokens,
                "rawCachedInputTokens": cacheReadTokens,
                "rawCacheCreationTokens": cacheCreationTokens,
                "rawCacheCreation5mTokens": cacheCreationTokens,
                "rawCacheCreation1hTokens": 0,
                "rawReasoningOutputTokens": 0,
                "rawThoughtTokens": 0,
                "rawToolUsePromptTokens": 0,
                "rawTotalTokens": inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
            ],
            "computed": [
                "contextWindowTokens": inputTokens + cacheReadTokens + cacheCreationTokens,
                "newInputTokens": inputTokens,
                "previousContextBaseline": 0,
                "calculationMethod": "anthropic_cache_aware"
            ],
            "meta": [
                "turn": turn,
                "sessionId": "test-session",
                "model": model,
                "contextSegmentId": "test-session:\(provider):\(model)",
                "baselineResetReason": "none",
                "extractedAt": "2024-01-01T00:00:00Z",
                "normalizedAt": "2024-01-01T00:00:00Z"
            ],
            "pricing": [
                "available": true,
                "model": model,
                "reason": NSNull(),
                "cost": [
                    "baseInputTokens": inputTokens,
                    "outputTokens": outputTokens,
                    "cacheReadTokens": cacheReadTokens,
                    "cacheWriteTokens": cacheCreationTokens,
                    "cacheWrite5mTokens": cacheCreationTokens,
                    "cacheWrite1hTokens": 0,
                    "baseInputCost": cost,
                    "outputCost": 0,
                    "cacheReadCost": 0,
                    "cacheWriteCost": 0,
                    "totalCost": cost,
                    "currency": "USD"
                ]
            ]
        ]
    }

    // MARK: - Event Operations

    func testStorageModeDistinguishesPrimaryAndTemporaryCache() async throws {
        XCTAssertEqual(database.storageMode, .primaryDocuments)
        XCTAssertFalse(database.storageMode.isTemporaryCache)

        let temporaryCacheURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("events.db")
        let temporaryCache = EventDatabase(temporaryCachePath: temporaryCacheURL.path)
        XCTAssertEqual(temporaryCache.storageMode, .temporaryCache)
        XCTAssertTrue(temporaryCache.storageMode.isTemporaryCache)

        try await temporaryCache.initialize()
        await temporaryCache.close()
        try? FileManager.default.removeItem(at: temporaryCacheURL.deletingLastPathComponent())
    }

    func testInsertAndGetEvent() async throws {
        let event = SessionEvent(
            id: "event-1",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test/workspace",
            type: "session.start",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: ["model": AnyCodable("claude-sonnet-4")]
        )

        try await database.events.insert(event)

        let retrieved = try await database.events.get("event-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "event-1")
        XCTAssertEqual(retrieved?.type, "session.start")
        XCTAssertNil(retrieved?.parentId)
    }

    func testInsertMultipleEvents() async throws {
        let events = [
            SessionEvent(
                id: "event-1",
                parentId: nil,
                sessionId: "session-1",
                workspaceId: "/test",
                type: "session.start",
                timestamp: ISO8601DateFormatter().string(from: Date()),
                sequence: 1,
                payload: [:]
            ),
            SessionEvent(
                id: "event-2",
                parentId: "event-1",
                sessionId: "session-1",
                workspaceId: "/test",
                type: "message.user",
                timestamp: ISO8601DateFormatter().string(from: Date()),
                sequence: 2,
                payload: ["content": AnyCodable("Hello")]
            ),
            SessionEvent(
                id: "event-3",
                parentId: "event-2",
                sessionId: "session-1",
                workspaceId: "/test",
                type: "message.assistant",
                timestamp: ISO8601DateFormatter().string(from: Date()),
                sequence: 3,
                payload: ["content": AnyCodable("Hi there!")]
            )
        ]

        try await database.events.insertBatch(events)

        let sessionEvents = try await database.events.getBySession("session-1")
        XCTAssertEqual(sessionEvents.count, 3)
    }

    func testGetEventsBySession() async throws {
        // Insert events for two sessions
        try await database.events.insert(SessionEvent(
            id: "s1-e1",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "session.start",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [:]
        ))

        try await database.events.insert(SessionEvent(
            id: "s2-e1",
            parentId: nil,
            sessionId: "session-2",
            workspaceId: "/test",
            type: "session.start",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [:]
        ))

        let session1Events = try await database.events.getBySession("session-1")
        XCTAssertEqual(session1Events.count, 1)
        XCTAssertEqual(session1Events.first?.id, "s1-e1")

        let session2Events = try await database.events.getBySession("session-2")
        XCTAssertEqual(session2Events.count, 1)
        XCTAssertEqual(session2Events.first?.id, "s2-e1")
    }

    // MARK: - Ancestor Traversal

    func testGetAncestors() async throws {
        // Create a chain of events
        let events = [
            SessionEvent(id: "root", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "child1", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:]),
            SessionEvent(id: "child2", parentId: "child1", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [:]),
            SessionEvent(id: "child3", parentId: "child2", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:03:00Z", sequence: 4, payload: [:])
        ]

        try await database.events.insertBatch(events)

        let ancestors = try await database.events.getAncestors("child3")
        XCTAssertEqual(ancestors.count, 4)
        XCTAssertEqual(ancestors.map { $0.id }, ["root", "child1", "child2", "child3"])
    }

    func testGetAncestorsCrossSession() async throws {
        // Create parent session events
        let parentEvents = [
            SessionEvent(id: "p-root", parentId: nil, sessionId: "parent-session",
                         workspaceId: "/test", type: "session.start",
                         timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "p-user", parentId: "p-root", sessionId: "parent-session",
                         workspaceId: "/test", type: "message.user",
                         timestamp: "2024-01-01T00:01:00Z", sequence: 2,
                         payload: [
                            "content": AnyCodable("Hello from parent"),
                            "turn": AnyCodable(1)
                         ]),
            SessionEvent(id: "p-assistant", parentId: "p-user", sessionId: "parent-session",
                         workspaceId: "/test", type: "message.assistant",
                         timestamp: "2024-01-01T00:02:00Z", sequence: 3,
                         payload: [
                            "content": AnyCodable([["type": "text", "text": "Hi there!"] as [String: Any]]),
                            "turn": AnyCodable(1),
                            "model": AnyCodable("claude-sonnet-4"),
                            "stopReason": AnyCodable("end_turn")
                         ])
        ]
        try await database.events.insertBatch(parentEvents)

        // Create forked session with root linking to parent session
        let forkedEvents = [
            SessionEvent(id: "f-root", parentId: "p-assistant", sessionId: "forked-session",
                         workspaceId: "/test", type: "session.fork",
                         timestamp: "2024-01-01T00:03:00Z", sequence: 1, payload: [:])
        ]
        try await database.events.insertBatch(forkedEvents)

        // getAncestors should traverse across session boundary
        let ancestors = try await database.events.getAncestors("f-root")

        XCTAssertEqual(ancestors.count, 4) // p-root, p-user, p-assistant, f-root
        XCTAssertEqual(ancestors.map { $0.id }, ["p-root", "p-user", "p-assistant", "f-root"])

        // Verify messages can be transformed from cross-session ancestors
        let messages = UnifiedEventTransformer.transformPersistedEvents(ancestors)
        XCTAssertEqual(messages.count, 2) // user + assistant from parent
    }

    func testGetChildren() async throws {
        // Create a branching structure
        let events = [
            SessionEvent(id: "root", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "branch1", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:]),
            SessionEvent(id: "branch2", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "session.fork", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [:])
        ]

        try await database.events.insertBatch(events)

        let children = try await database.events.getChildren("root")
        XCTAssertEqual(children.count, 2)
    }

    func testDeleteEventsBySession() async throws {
        try await database.events.insertBatch([
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01", sequence: 2, payload: [:])
        ])

        var events = try await database.events.getBySession("s1")
        XCTAssertEqual(events.count, 2)

        try await database.events.deleteBySession("s1")

        events = try await database.events.getBySession("s1")
        XCTAssertEqual(events.count, 0)
    }

    func testInsertEventsIgnoringDuplicates() async throws {
        // Insert initial events
        let initialEvents = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:])
        ]
        try await database.events.insertBatch(initialEvents)

        // Verify initial state
        var allEvents = try await database.events.getBySession("s1")
        XCTAssertEqual(allEvents.count, 2)

        // Try to insert mix of duplicates and new events
        let mixedEvents = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]), // duplicate
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:]), // duplicate
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [:]) // new
        ]
        let insertedCount = try await database.events.insertIgnoringDuplicates(mixedEvents)

        // Should only insert the new event
        XCTAssertEqual(insertedCount, 1)

        // Verify total count
        allEvents = try await database.events.getBySession("s1")
        XCTAssertEqual(allEvents.count, 3)

        // Verify the new event exists
        let newEvent = try await database.events.get("e3")
        XCTAssertNotNil(newEvent)
        XCTAssertEqual(newEvent?.type, "message.assistant")
    }

    // MARK: - Session Operations

    func testInsertAndGetSession() async throws {
        let session = CachedSession(
            id: "session-1",
            workspaceId: "/test/workspace",
            rootEventId: "event-1",
            headEventId: "event-3",
            title: "Test Session",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/test/workspace",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            lastActivityAt: ISO8601DateFormatter().string(from: Date()),
            eventCount: 3,
            messageCount: 2,
            inputTokens: 100,
            outputTokens: 200,
            lastTurnInputTokens: 0,
            cost: 0.0
        )

        try await database.sessions.insert(session)

        let retrieved = try await database.sessions.get("session-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "session-1")
        XCTAssertEqual(retrieved?.title, "Test Session")
        XCTAssertEqual(retrieved?.inputTokens, 100)
        XCTAssertEqual(retrieved?.outputTokens, 200)
    }

    func testSessionPersistenceRoundTripsProcessingFlag() async throws {
        try await database.sessions.insert(CachedSession(
            id: "processing-session",
            workspaceId: "/test/workspace",
            rootEventId: nil,
            headEventId: nil,
            title: "Processing Session",
            latestModel: "gemma4:e4b",
            workingDirectory: "/test/workspace",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 1,
            messageCount: 1,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0,
            isProcessing: true
        ))

        let retrieved = try await database.sessions.get("processing-session")
        XCTAssertEqual(retrieved?.isProcessing, true)
    }

    func testGetAllSessions() async throws {
        try await database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Session 1", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01T00:00:00Z", lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0, messageCount: 0, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        try await database.sessions.insert(CachedSession(
            id: "s2", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Session 2", latestModel: "claude-opus-4",
            workingDirectory: "/test",
            createdAt: "2024-01-02T00:00:00Z", lastActivityAt: "2024-01-02T00:00:00Z",
            eventCount: 0, messageCount: 0, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        let sessions = try await database.sessions.getAll()
        XCTAssertEqual(sessions.count, 2)
        // Should be sorted by lastActivityAt desc
        XCTAssertEqual(sessions.first?.id, "s2")
    }

    func testDeleteSession() async throws {
        try await database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 0, messageCount: 0, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        var session = try await database.sessions.get("s1")
        XCTAssertNotNil(session)

        try await database.sessions.delete("s1")

        session = try await database.sessions.get("s1")
        XCTAssertNil(session)
    }

    // MARK: - State Reconstruction (Unified Transformer)

    func testTransformEventsToMessages() async throws {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [
                "content": AnyCodable("Hello"),
                "turn": AnyCodable(1)
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [
                "content": AnyCodable([["type": "text", "text": "Hi there!"] as [String: Any]]),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "stopReason": AnyCodable("end_turn")
            ])
        ]

        try await database.events.insertBatch(events)

        // Use unified transformer to get messages
        let ancestors = try await database.events.getAncestors("e3")
        let messages = UnifiedEventTransformer.transformPersistedEvents(ancestors)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
    }

    func testReconstructSessionState() async throws {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [
                "content": AnyCodable("Hello"),
                "turn": AnyCodable(1)
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [
                "content": AnyCodable([["type": "text", "text": "Hi there!"] as [String: Any]]),
                "tokenRecord": AnyCodable(makeTokenRecord(inputTokens: 10, outputTokens: 50, turn: 1)),
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "stopReason": AnyCodable("end_turn")
            ])
        ]

        try await database.events.insertBatch(events)
        try await database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: "e1", headEventId: "e3",
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 3, messageCount: 2, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        // Use unified transformer to reconstruct state
        let ancestors = try await database.events.getAncestors("e3")
        let state = UnifiedEventTransformer.reconstructSessionState(from: ancestors)

        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.currentTurn, 1)
    }

    // MARK: - Sync State

    func testSyncState() async throws {
        let syncState = SyncState(
            key: "session-1",
            lastSyncedEventId: "event-5",
            lastSyncTimestamp: "2024-01-01T00:00:00Z",
            pendingEventIds: ["event-6", "event-7"]
        )

        try await database.sync.update(syncState)

        let retrieved = try await database.sync.getState("session-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.key, "session-1")
        XCTAssertEqual(retrieved?.lastSyncedEventId, "event-5")
        XCTAssertEqual(retrieved?.pendingEventIds.count, 2)
    }

    // MARK: - Phase 1: Enriched Message Metadata

    func testEnrichedAssistantMessageMetadata() async throws {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [
                "content": AnyCodable("Hello"),
                "turn": AnyCodable(1)
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [
                "content": AnyCodable([["type": "text", "text": "Hi there!"] as [String: Any]]),
                "model": AnyCodable("claude-sonnet-4-20250514"),
                "latency": AnyCodable(1234),
                "turn": AnyCodable(1),
                "hasThinking": AnyCodable(true),
                "stopReason": AnyCodable("end_turn"),
                "tokenRecord": AnyCodable(makeTokenRecord(inputTokens: 100, outputTokens: 200, turn: 1))
            ])
        ]

        try await database.events.insertBatch(events)
        try await database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: "e1", headEventId: "e3",
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 3, messageCount: 2, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        // Use unified transformer to reconstruct state
        let ancestors = try await database.events.getAncestors("e3")
        let state = UnifiedEventTransformer.reconstructSessionState(from: ancestors)

        XCTAssertEqual(state.messages.count, 2)

        let assistantMessage = state.messages[1]
        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertEqual(assistantMessage.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(assistantMessage.latencyMs, 1234)
        XCTAssertEqual(assistantMessage.turnNumber, 1)
        XCTAssertEqual(assistantMessage.stopReason, "end_turn")
    }

    // MARK: - Phase 3: Event Summary Tests

    func testEventTypeSummaries() {
        // Test message.user summary
        let userEvent = SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [
            "content": AnyCodable("Hello world")
        ])
        XCTAssertTrue(userEvent.summary.contains("Hello world"))

        // Test message.assistant summary with content (note: model is not shown in summary)
        let assistantEvent = SessionEvent(id: "e2", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:00:00Z", sequence: 2, payload: [
            "content": AnyCodable("Response text"),
            "model": AnyCodable("claude-sonnet-4-20250514")
        ])
        XCTAssertTrue(assistantEvent.summary.contains("Response text"))

        // Test capability-backed capability.invocation.started transport summary
        let capabilityEvent = SessionEvent(id: "e3", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "capability.invocation.started", timestamp: "2024-01-01T00:00:00Z", sequence: 3, payload: [
            "modelPrimitiveName": AnyCodable("execute"),
            "operationName": AnyCodable("file_read"),
            "arguments": AnyCodable(["file_path": "/src/main.ts"])
        ])
        XCTAssertTrue(capabilityEvent.summary.contains("File Read"))
        XCTAssertTrue(capabilityEvent.summary.contains("main.ts"))

        // Test session.start summary (shortModelName returns "Opus 4" for "claude-opus-4")
        let startEvent = SessionEvent(id: "e4", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 4, payload: [
            "model": AnyCodable("claude-opus-4")
        ])
        XCTAssertTrue(startEvent.summary.contains("Opus 4"))

        // Test config.model_switch summary
        let switchEvent = SessionEvent(id: "e5", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "config.model_switch", timestamp: "2024-01-01T00:00:00Z", sequence: 5, payload: [
            "previousModel": AnyCodable("claude-sonnet-4"),
            "newModel": AnyCodable("claude-opus-4")
        ])
        XCTAssertTrue(switchEvent.summary.contains("→"))
    }

    // MARK: - Session Drafts Table

    func testSessionDraftsTableExists() async throws {
        // The session_drafts table should exist after initialization
        let name: String = try await database.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name='session_drafts'"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW,
                  let ptr = sqlite3_column_text(stmt, 0) else { return "" }
            return String(cString: ptr)
        }
        XCTAssertEqual(name, "session_drafts")
    }

    func testSessionDraftsTable_basicCRUD() async throws {
        // Insert via withDB
        let insertSQL = """
            INSERT INTO session_drafts (session_id, text, attachment_metadata_json, updated_at)
            VALUES ('test-session', 'hello world', '[]', '2026-04-03T00:00:00Z')
        """
        try await database.withDB { db in
            guard sqlite3_exec(db, insertSQL, nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
            }
        }

        // Select via withDB
        let text: String = try await database.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let selectSQL = "SELECT text FROM session_drafts WHERE session_id = 'test-session'"
            guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW,
                  let ptr = sqlite3_column_text(stmt, 0) else { return "" }
            return String(cString: ptr)
        }
        XCTAssertEqual(text, "hello world")
    }

    func testClearAll_includesSessionDrafts() async throws {
        // Insert a draft via withDB
        try await database.withDB { db in
            let sql = """
                INSERT INTO session_drafts (session_id, text, attachment_metadata_json, updated_at)
                VALUES ('test-session', 'draft text', '[]', '2026-04-03T00:00:00Z')
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw EventDatabaseError.executeFailed(sqliteErrorMessage(db))
            }
        }

        // Clear all
        try await database.clearAll()

        // Verify draft is gone via withDB
        let count: Int32 = try await database.withDB { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = "SELECT COUNT(*) FROM session_drafts"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
            return sqlite3_column_int(stmt, 0)
        }
        XCTAssertEqual(count, 0)
    }
}
