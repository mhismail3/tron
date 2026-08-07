import XCTest
import SQLite3
@testable import TronMobile

/// Tests for the EventDatabase SQLite store
@MainActor
final class EventDatabaseTests: XCTestCase {

    var database: EventDatabase!
    var testState: IsolatedTestState!

    override func setUp() async throws {
        testState = IsolatedTestState(label: "event-database")
        testState.registerTeardown(with: self)
        database = testState.makeDatabase()
        try await database.initialize()
        try await database.clearAll()
    }

    override func tearDown() async throws {
        try? await database.clearAll()
        await testState.cleanup()
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

    func testExplicitDatabasePathInitializesIsolatedStore() async throws {
        let isolatedDatabase = testState.makeDatabase(fileName: "isolated.db")
        XCTAssertTrue(isolatedDatabase.dbPath.hasPrefix(testState.rootURL.path))
        XCTAssertTrue(isolatedDatabase.dbPath.hasSuffix("isolated.db"))

        try await isolatedDatabase.initialize()
        await isolatedDatabase.close()
    }

    func testInitializationDropsObsoleteEventSyncCursorTable() async throws {
        let legacyDatabase = testState.makeDatabase(fileName: "legacy-sync-cursor.db")
        var legacyHandle: OpaquePointer?
        guard sqlite3_open(legacyDatabase.dbPath, &legacyHandle) == SQLITE_OK else {
            XCTFail("Could not create legacy database fixture")
            return
        }
        XCTAssertEqual(
            sqlite3_exec(
                legacyHandle,
                "CREATE TABLE sync_state (key TEXT PRIMARY KEY); INSERT INTO sync_state VALUES ('session-1')",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(legacyHandle)
        legacyHandle = nil

        try await legacyDatabase.initialize()
        let obsoleteTableCount = try await legacyDatabase.withDB { db in
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT COUNT(*) FROM sqlite_schema WHERE type = 'table' AND name = 'sync_state'"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else {
                throw EventDatabaseError.prepareFailed(
                    "Could not inspect canonical cache schema"
                )
            }
            return Int(sqlite3_column_int(statement, 0))
        }

        XCTAssertEqual(obsoleteTableCount, 0)
        await legacyDatabase.close()
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

    func testInsertIgnoringDuplicatesPersistsMultipleEvents() async throws {
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

        let insertedCount = try await database.events.insertIgnoringDuplicates(events)

        let sessionEvents = try await database.events.getBySession("session-1")
        XCTAssertEqual(insertedCount, 3)
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

        _ = try await database.events.insertIgnoringDuplicates(events)

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
        _ = try await database.events.insertIgnoringDuplicates(parentEvents)

        // Create forked session with root linking to parent session
        let forkedEvents = [
            SessionEvent(id: "f-root", parentId: "p-assistant", sessionId: "forked-session",
                         workspaceId: "/test", type: "session.fork",
                         timestamp: "2024-01-01T00:03:00Z", sequence: 1, payload: [:])
        ]
        _ = try await database.events.insertIgnoringDuplicates(forkedEvents)

        // getAncestors should traverse across session boundary
        let ancestors = try await database.events.getAncestors("f-root")

        XCTAssertEqual(ancestors.count, 4) // p-root, p-user, p-assistant, f-root
        XCTAssertEqual(ancestors.map { $0.id }, ["p-root", "p-user", "p-assistant", "f-root"])

        // Verify messages can be transformed from cross-session ancestors
        let messages = UnifiedEventTransformer.transformPersistedEvents(ancestors)
        XCTAssertEqual(messages.count, 2) // user + assistant from parent
    }

    func testRecentSessionWindowIsBoundedAndReturnedOldestFirst() async throws {
        let events = (1...8).map { sequence in
            SessionEvent(
                id: "window-\(sequence)",
                parentId: sequence == 1 ? nil : "window-\(sequence - 1)",
                sessionId: "window-session",
                workspaceId: "/test",
                type: "message.user",
                timestamp: "2026-08-07T12:00:\(String(format: "%02d", sequence))Z",
                sequence: sequence,
                payload: ["content": AnyCodable("message \(sequence)")]
            )
        }
        _ = try await database.events.insertIgnoringDuplicates(events)

        let recent = try await database.events.getRecentBySession("window-session", limit: 3)

        XCTAssertEqual(recent.map(\.id), ["window-6", "window-7", "window-8"])
    }

    func testRecentAncestorWindowIsBoundedAcrossSessions() async throws {
        let events = (1...8).map { sequence in
            SessionEvent(
                id: "ancestor-\(sequence)",
                parentId: sequence == 1 ? nil : "ancestor-\(sequence - 1)",
                sessionId: sequence < 7 ? "parent-session" : "fork-session",
                workspaceId: "/test",
                type: sequence == 7 ? "session.fork" : "message.user",
                timestamp: "2026-08-07T12:00:\(String(format: "%02d", sequence))Z",
                sequence: sequence < 7 ? sequence : sequence - 6,
                payload: [:]
            )
        }
        _ = try await database.events.insertIgnoringDuplicates(events)

        let recent = try await database.events.getRecentAncestors("ancestor-8", limit: 3)

        XCTAssertEqual(recent.map(\.id), ["ancestor-6", "ancestor-7", "ancestor-8"])
    }

    func testProviderRequestCacheWriteAlwaysDefersAuditBody() async throws {
        let event = SessionEvent(
            id: "provider-audit",
            parentId: nil,
            sessionId: "audit-session",
            workspaceId: "/test",
            type: SessionEventType.modelProviderRequest.rawValue,
            timestamp: "2026-08-07T12:00:00Z",
            sequence: 1,
            payload: [
                "contextManifest": AnyCodable(["messages": [["content": "large body"]]]),
                "padding": AnyCodable(String(repeating: "x", count: 20_000)),
            ]
        )

        try await database.events.insert(event)
        let storedEvent = try await database.events.get(event.id)
        let cached = try XCTUnwrap(storedEvent)

        XCTAssertEqual(cached.payload["projection"]?.stringValue, "deferred")
        XCTAssertNil(cached.payload["contextManifest"])
        XCTAssertNil(cached.payload["padding"])
    }

    func testDeleteEventsBySession() async throws {
        _ = try await database.events.insertIgnoringDuplicates([
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
        _ = try await database.events.insertIgnoringDuplicates(initialEvents)

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

        _ = try await database.events.insertIgnoringDuplicates(events)

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

        _ = try await database.events.insertIgnoringDuplicates(events)
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

        _ = try await database.events.insertIgnoringDuplicates(events)
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
        XCTAssertTrue(assistantMessage.isFinalAssistantResponse)
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

        // Test tool-backed tool.invocation.started transport summary
        let toolEvent = SessionEvent(id: "e3", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "tool.invocation.started", timestamp: "2024-01-01T00:00:00Z", sequence: 3, payload: [
            "toolName": AnyCodable("filesystem_read"),
            "arguments": AnyCodable(["path": "/src/main.ts"])
        ])
        XCTAssertTrue(toolEvent.summary.contains("Filesystem Read"))
        XCTAssertTrue(toolEvent.summary.contains("main.ts"))

        // Test session.start summary (shortModelName returns "Opus 4" for "claude-opus-4")
        let startEvent = SessionEvent(id: "e4", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 4, payload: [
            "model": AnyCodable("claude-opus-4")
        ])
        XCTAssertTrue(startEvent.summary.contains("Opus 4"))

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
