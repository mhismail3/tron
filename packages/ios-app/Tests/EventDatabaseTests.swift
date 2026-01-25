import XCTest
@testable import TronMobile

/// Tests for the EventDatabase SQLite store
final class EventDatabaseTests: XCTestCase {

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

    // MARK: - Event Operations

    @MainActor
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

        try database.events.insert(event)

        let retrieved = try database.events.get("event-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "event-1")
        XCTAssertEqual(retrieved?.type, "session.start")
        XCTAssertNil(retrieved?.parentId)
    }

    @MainActor
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

        try database.events.insertBatch(events)

        let sessionEvents = try database.events.getBySession("session-1")
        XCTAssertEqual(sessionEvents.count, 3)
    }

    @MainActor
    func testGetEventsBySession() async throws {
        // Insert events for two sessions
        try database.events.insert(SessionEvent(
            id: "s1-e1",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "session.start",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [:]
        ))

        try database.events.insert(SessionEvent(
            id: "s2-e1",
            parentId: nil,
            sessionId: "session-2",
            workspaceId: "/test",
            type: "session.start",
            timestamp: ISO8601DateFormatter().string(from: Date()),
            sequence: 1,
            payload: [:]
        ))

        let session1Events = try database.events.getBySession("session-1")
        XCTAssertEqual(session1Events.count, 1)
        XCTAssertEqual(session1Events.first?.id, "s1-e1")

        let session2Events = try database.events.getBySession("session-2")
        XCTAssertEqual(session2Events.count, 1)
        XCTAssertEqual(session2Events.first?.id, "s2-e1")
    }

    // MARK: - Ancestor Traversal

    @MainActor
    func testGetAncestors() async throws {
        // Create a chain of events
        let events = [
            SessionEvent(id: "root", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "child1", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:]),
            SessionEvent(id: "child2", parentId: "child1", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [:]),
            SessionEvent(id: "child3", parentId: "child2", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:03:00Z", sequence: 4, payload: [:])
        ]

        try database.events.insertBatch(events)

        let ancestors = try database.events.getAncestors("child3")
        XCTAssertEqual(ancestors.count, 4)
        XCTAssertEqual(ancestors.map { $0.id }, ["root", "child1", "child2", "child3"])
    }

    @MainActor
    func testGetAncestorsCrossSession() async throws {
        // Create parent session events
        let parentEvents = [
            SessionEvent(id: "p-root", parentId: nil, sessionId: "parent-session",
                         workspaceId: "/test", type: "session.start",
                         timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "p-user", parentId: "p-root", sessionId: "parent-session",
                         workspaceId: "/test", type: "message.user",
                         timestamp: "2024-01-01T00:01:00Z", sequence: 2,
                         payload: ["content": AnyCodable("Hello from parent")]),
            SessionEvent(id: "p-assistant", parentId: "p-user", sessionId: "parent-session",
                         workspaceId: "/test", type: "message.assistant",
                         timestamp: "2024-01-01T00:02:00Z", sequence: 3,
                         payload: ["content": AnyCodable("Hi there!")])
        ]
        try database.events.insertBatch(parentEvents)

        // Create forked session with root linking to parent session
        let forkedEvents = [
            SessionEvent(id: "f-root", parentId: "p-assistant", sessionId: "forked-session",
                         workspaceId: "/test", type: "session.fork",
                         timestamp: "2024-01-01T00:03:00Z", sequence: 1, payload: [:])
        ]
        try database.events.insertBatch(forkedEvents)

        // getAncestors should traverse across session boundary
        let ancestors = try database.events.getAncestors("f-root")

        XCTAssertEqual(ancestors.count, 4) // p-root, p-user, p-assistant, f-root
        XCTAssertEqual(ancestors.map { $0.id }, ["p-root", "p-user", "p-assistant", "f-root"])

        // Verify messages can be transformed from cross-session ancestors
        let messages = UnifiedEventTransformer.transformPersistedEvents(ancestors)
        XCTAssertEqual(messages.count, 2) // user + assistant from parent
    }

    @MainActor
    func testGetChildren() async throws {
        // Create a branching structure
        let events = [
            SessionEvent(id: "root", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "branch1", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:]),
            SessionEvent(id: "branch2", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "session.fork", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [:])
        ]

        try database.events.insertBatch(events)

        let children = try database.events.getChildren("root")
        XCTAssertEqual(children.count, 2)
    }

    @MainActor
    func testDeleteEventsBySession() async throws {
        try database.events.insertBatch([
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01", sequence: 2, payload: [:])
        ])

        var events = try database.events.getBySession("s1")
        XCTAssertEqual(events.count, 2)

        try database.events.deleteBySession("s1")

        events = try database.events.getBySession("s1")
        XCTAssertEqual(events.count, 0)
    }

    @MainActor
    func testInsertEventsIgnoringDuplicates() async throws {
        // Insert initial events
        let initialEvents = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:])
        ]
        try database.events.insertBatch(initialEvents)

        // Verify initial state
        var allEvents = try database.events.getBySession("s1")
        XCTAssertEqual(allEvents.count, 2)

        // Try to insert mix of duplicates and new events
        let mixedEvents = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]), // duplicate
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:]), // duplicate
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [:]) // new
        ]
        let insertedCount = try database.events.insertIgnoringDuplicates(mixedEvents)

        // Should only insert the new event
        XCTAssertEqual(insertedCount, 1)

        // Verify total count
        allEvents = try database.events.getBySession("s1")
        XCTAssertEqual(allEvents.count, 3)

        // Verify the new event exists
        let newEvent = try database.events.get("e3")
        XCTAssertNotNil(newEvent)
        XCTAssertEqual(newEvent?.type, "message.assistant")
    }

    // MARK: - Session Operations

    @MainActor
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

        try database.sessions.insert(session)

        let retrieved = try database.sessions.get("session-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.id, "session-1")
        XCTAssertEqual(retrieved?.title, "Test Session")
        XCTAssertEqual(retrieved?.inputTokens, 100)
        XCTAssertEqual(retrieved?.outputTokens, 200)
    }

    @MainActor
    func testGetAllSessions() async throws {
        try database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Session 1", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01T00:00:00Z", lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0, messageCount: 0, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        try database.sessions.insert(CachedSession(
            id: "s2", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Session 2", latestModel: "claude-opus-4",
            workingDirectory: "/test",
            createdAt: "2024-01-02T00:00:00Z", lastActivityAt: "2024-01-02T00:00:00Z",
            eventCount: 0, messageCount: 0, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        let sessions = try database.sessions.getAll()
        XCTAssertEqual(sessions.count, 2)
        // Should be sorted by lastActivityAt desc
        XCTAssertEqual(sessions.first?.id, "s2")
    }

    @MainActor
    func testDeleteSession() async throws {
        try database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 0, messageCount: 0, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        var session = try database.sessions.get("s1")
        XCTAssertNotNil(session)

        try database.sessions.delete("s1")

        session = try database.sessions.get("s1")
        XCTAssertNil(session)
    }

    // MARK: - State Reconstruction (Unified Transformer)

    @MainActor
    func testTransformEventsToMessages() async throws {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: ["content": AnyCodable("Hello")]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: ["content": AnyCodable("Hi there!")])
        ]

        try database.events.insertBatch(events)

        // Use unified transformer to get messages
        let ancestors = try database.events.getAncestors("e3")
        let messages = UnifiedEventTransformer.transformPersistedEvents(ancestors)

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0].role, .user)
        XCTAssertEqual(messages[1].role, .assistant)
    }

    @MainActor
    func testReconstructSessionState() async throws {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [
                "content": AnyCodable("Hello"),
                "tokenUsage": AnyCodable(["inputTokens": 10, "outputTokens": 0])
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [
                "content": AnyCodable("Hi there!"),
                "tokenUsage": AnyCodable(["inputTokens": 10, "outputTokens": 50]),
                "turn": AnyCodable(1)
            ])
        ]

        try database.events.insertBatch(events)
        try database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: "e1", headEventId: "e3",
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 3, messageCount: 2, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        // Use unified transformer to reconstruct state
        let ancestors = try database.events.getAncestors("e3")
        let state = UnifiedEventTransformer.reconstructSessionState(from: ancestors)

        XCTAssertEqual(state.messages.count, 2)
        XCTAssertEqual(state.currentTurn, 1)
    }

    // MARK: - Tree Visualization

    @MainActor
    func testBuildTreeVisualization() async throws {
        let events = [
            SessionEvent(id: "root", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "msg1", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: ["content": AnyCodable("Hello")]),
            SessionEvent(id: "msg2", parentId: "msg1", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: ["content": AnyCodable("Hi")])
        ]

        try database.events.insertBatch(events)
        try database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: "root", headEventId: "msg2",
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 3, messageCount: 2, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        let tree = try database.tree.build("s1")
        XCTAssertEqual(tree.count, 3)

        // Check root
        let root = tree.first { $0.id == "root" }
        XCTAssertNotNil(root)
        XCTAssertEqual(root?.depth, 0)
        XCTAssertNil(root?.parentId)

        // Check head
        let head = tree.first { $0.id == "msg2" }
        XCTAssertNotNil(head)
        XCTAssertTrue(head?.isHead ?? false)
        XCTAssertEqual(head?.depth, 2)
    }

    @MainActor
    func testBranchPointDetection() async throws {
        // Create a branching structure
        let events = [
            SessionEvent(id: "root", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "fork-point", parentId: "root", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [:]),
            SessionEvent(id: "branch-a", parentId: "fork-point", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [:]),
            SessionEvent(id: "branch-b", parentId: "fork-point", sessionId: "s1", workspaceId: "/test", type: "session.fork", timestamp: "2024-01-01T00:02:00Z", sequence: 4, payload: [:])
        ]

        try database.events.insertBatch(events)
        try database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: "root", headEventId: "branch-a",
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 4, messageCount: 1, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        let tree = try database.tree.build("s1")

        let forkPoint = tree.first { $0.id == "fork-point" }
        XCTAssertNotNil(forkPoint)
        XCTAssertTrue(forkPoint?.isBranchPoint ?? false)
        XCTAssertEqual(forkPoint?.childCount, 2)
    }

    // MARK: - Sync State

    @MainActor
    func testSyncState() async throws {
        let syncState = SyncState(
            key: "session-1",
            lastSyncedEventId: "event-5",
            lastSyncTimestamp: "2024-01-01T00:00:00Z",
            pendingEventIds: ["event-6", "event-7"]
        )

        try database.sync.update(syncState)

        let retrieved = try database.sync.getState("session-1")
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.key, "session-1")
        XCTAssertEqual(retrieved?.lastSyncedEventId, "event-5")
        XCTAssertEqual(retrieved?.pendingEventIds.count, 2)
    }

    // MARK: - Phase 1: Enriched Message Metadata

    @MainActor
    func testEnrichedAssistantMessageMetadata() async throws {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [
                "content": AnyCodable("Hello")
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [
                "content": AnyCodable("Hi there!"),
                "model": AnyCodable("claude-sonnet-4-20250514"),
                "latency": AnyCodable(1234),
                "turn": AnyCodable(1),
                "hasThinking": AnyCodable(true),
                "stopReason": AnyCodable("end_turn"),
                "tokenUsage": AnyCodable(["inputTokens": 100, "outputTokens": 200])
            ])
        ]

        try database.events.insertBatch(events)
        try database.sessions.insert(CachedSession(
            id: "s1", workspaceId: "/test", rootEventId: "e1", headEventId: "e3",
            title: "Test", latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01", lastActivityAt: "2024-01-01",
            eventCount: 3, messageCount: 2, inputTokens: 0, outputTokens: 0, lastTurnInputTokens: 0, cost: 0.0
        ))

        // Use unified transformer to reconstruct state
        let ancestors = try database.events.getAncestors("e3")
        let state = UnifiedEventTransformer.reconstructSessionState(from: ancestors)

        XCTAssertEqual(state.messages.count, 2)

        let assistantMessage = state.messages[1]
        XCTAssertEqual(assistantMessage.role, .assistant)
        XCTAssertEqual(assistantMessage.model, "claude-sonnet-4-20250514")
        XCTAssertEqual(assistantMessage.latencyMs, 1234)
        XCTAssertEqual(assistantMessage.turnNumber, 1)
        XCTAssertEqual(assistantMessage.hasThinking, true)
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

        // Test tool.call summary
        let toolEvent = SessionEvent(id: "e3", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "tool.call", timestamp: "2024-01-01T00:00:00Z", sequence: 3, payload: [
            "name": AnyCodable("Read"),
            "arguments": AnyCodable(["file_path": "/src/main.ts"])
        ])
        XCTAssertTrue(toolEvent.summary.contains("Read"))
        XCTAssertTrue(toolEvent.summary.contains("main.ts"))

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

    // MARK: - Phase 4: Consolidated Analytics Tests

    func testConsolidatedAnalyticsComputation() {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [
                "model": AnyCodable("claude-sonnet-4")
            ]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [
                "content": AnyCodable("Hello")
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [
                "content": AnyCodable("Hi!"),
                "model": AnyCodable("claude-sonnet-4-20250514"),
                "latency": AnyCodable(500),
                "turn": AnyCodable(1),
                "tokenUsage": AnyCodable(["inputTokens": 50, "outputTokens": 100])
            ]),
            SessionEvent(id: "e4", parentId: "e3", sessionId: "s1", workspaceId: "/test", type: "tool.call", timestamp: "2024-01-01T00:03:00Z", sequence: 4, payload: [
                "name": AnyCodable("Read"),
                "turn": AnyCodable(1),
                "toolCallId": AnyCodable("tc1")
            ]),
            SessionEvent(id: "e5", parentId: "e4", sessionId: "s1", workspaceId: "/test", type: "tool.result", timestamp: "2024-01-01T00:03:01Z", sequence: 5, payload: [
                "toolCallId": AnyCodable("tc1"),
                "isError": AnyCodable(false),
                "duration": AnyCodable(100)
            ]),
            SessionEvent(id: "e6", parentId: "e5", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:04:00Z", sequence: 6, payload: [
                "content": AnyCodable("Here's the file content"),
                "model": AnyCodable("claude-sonnet-4-20250514"),
                "latency": AnyCodable(300),
                "turn": AnyCodable(2),
                "tokenUsage": AnyCodable(["inputTokens": 100, "outputTokens": 150])
            ])
        ]

        let analytics = ConsolidatedAnalytics(from: events)

        // Verify turn count
        XCTAssertEqual(analytics.totalTurns, 2)

        // Verify tool calls total
        XCTAssertEqual(analytics.totalToolCalls, 1)

        // Verify tools are tracked per-turn
        XCTAssertEqual(analytics.turns.first?.tools.count, 1)
        XCTAssertEqual(analytics.turns.first?.tools.first, "Read")

        // Verify average latency (500 + 300) / 2 = 400
        XCTAssertEqual(analytics.avgLatency, 400)

        // Verify no errors
        XCTAssertEqual(analytics.totalErrors, 0)
    }

    func testConsolidatedAnalyticsErrorTracking() {
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "session.start", timestamp: "2024-01-01T00:00:00Z", sequence: 1, payload: [:]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "error.agent", timestamp: "2024-01-01T00:01:00Z", sequence: 2, payload: [
                "error": AnyCodable("Something went wrong"),
                "recoverable": AnyCodable(true),
                "turn": AnyCodable(1)
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "error.provider", timestamp: "2024-01-01T00:02:00Z", sequence: 3, payload: [
                "error": AnyCodable("Rate limit exceeded"),
                "retryable": AnyCodable(true),
                "turn": AnyCodable(1)
            ])
        ]

        let analytics = ConsolidatedAnalytics(from: events)

        XCTAssertEqual(analytics.totalErrors, 2)
        // Errors are now tracked per-turn
        XCTAssertEqual(analytics.turns.first?.errorCount, 2)
        XCTAssertTrue(analytics.turns.first?.errors.contains("Something went wrong") ?? false)
        XCTAssertTrue(analytics.turns.first?.errors.contains("Rate limit exceeded") ?? false)
    }

    func testConsolidatedAnalyticsCostExtraction() {
        // Test that cost is properly extracted from stream.turn_end events
        // including handling of Int vs Double type (JSON may serialize 0.0 as 0)
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:01:00Z", sequence: 1, payload: [
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "tokenUsage": AnyCodable(["inputTokens": 1000, "outputTokens": 500])
            ]),
            // Cost as Double (normal case)
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "stream.turn_end", timestamp: "2024-01-01T00:02:00Z", sequence: 2, payload: [
                "turn": AnyCodable(1),
                "cost": AnyCodable(0.0105),  // Double
                "tokenUsage": AnyCodable(["inputTokens": 1000, "outputTokens": 500])
            ]),
            SessionEvent(id: "e3", parentId: "e2", sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:03:00Z", sequence: 3, payload: [
                "turn": AnyCodable(2),
                "model": AnyCodable("claude-sonnet-4"),
                "tokenUsage": AnyCodable(["inputTokens": 2000, "outputTokens": 1000])
            ]),
            // Cost as Int (edge case when cost is 0)
            SessionEvent(id: "e4", parentId: "e3", sessionId: "s1", workspaceId: "/test", type: "stream.turn_end", timestamp: "2024-01-01T00:04:00Z", sequence: 4, payload: [
                "turn": AnyCodable(2),
                "cost": AnyCodable(0),  // Int (JSON serializes 0.0 as 0)
                "tokenUsage": AnyCodable(["inputTokens": 2000, "outputTokens": 1000])
            ])
        ]

        let analytics = ConsolidatedAnalytics(from: events)

        XCTAssertEqual(analytics.totalTurns, 2)
        // First turn should have the Double cost
        XCTAssertEqual(analytics.turns[0].cost, 0.0105, accuracy: 0.0001)
        // Second turn should have 0 cost (extracted from Int)
        XCTAssertEqual(analytics.turns[1].cost, 0.0, accuracy: 0.0001)
    }

    func testConsolidatedAnalyticsCacheTokens() {
        // Test that cache tokens are properly tracked and affect cost calculation
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:01:00Z", sequence: 1, payload: [
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "tokenUsage": AnyCodable([
                    "inputTokens": 10000,
                    "outputTokens": 500,
                    "cacheReadTokens": 8000,
                    "cacheCreationTokens": 1000
                ])
            ]),
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "stream.turn_end", timestamp: "2024-01-01T00:02:00Z", sequence: 2, payload: [
                "turn": AnyCodable(1),
                // No cost provided - should be calculated from tokens
                "tokenUsage": AnyCodable([
                    "inputTokens": 10000,
                    "outputTokens": 500,
                    "cacheReadTokens": 8000,
                    "cacheCreationTokens": 1000
                ])
            ])
        ]

        let analytics = ConsolidatedAnalytics(from: events)

        XCTAssertEqual(analytics.totalTurns, 1)
        let turn = analytics.turns[0]

        // Verify cache tokens are tracked
        XCTAssertEqual(turn.cacheReadTokens, 8000)
        XCTAssertEqual(turn.cacheCreationTokens, 1000)

        // Cost should be calculated with cache pricing:
        // Base input: (10000 - 8000 - 1000) = 1000 tokens @ $3/M = $0.003
        // Cache creation: 1000 tokens @ $3/M * 1.25 = $0.00375
        // Cache read: 8000 tokens @ $3/M * 0.1 = $0.0024
        // Output: 500 tokens @ $15/M = $0.0075
        // Total: $0.003 + $0.00375 + $0.0024 + $0.0075 = $0.01665
        XCTAssertEqual(turn.cost, 0.01665, accuracy: 0.001)
    }

    func testConsolidatedAnalyticsCostFallback() {
        // Test that cost is calculated from tokens when not provided in event
        let events = [
            SessionEvent(id: "e1", parentId: nil, sessionId: "s1", workspaceId: "/test", type: "message.assistant", timestamp: "2024-01-01T00:01:00Z", sequence: 1, payload: [
                "turn": AnyCodable(1),
                "model": AnyCodable("claude-sonnet-4"),
                "tokenUsage": AnyCodable(["inputTokens": 1000000, "outputTokens": 100000])
            ]),
            // No cost in stream.turn_end - should calculate from tokens
            SessionEvent(id: "e2", parentId: "e1", sessionId: "s1", workspaceId: "/test", type: "stream.turn_end", timestamp: "2024-01-01T00:02:00Z", sequence: 2, payload: [
                "turn": AnyCodable(1),
                "tokenUsage": AnyCodable(["inputTokens": 1000000, "outputTokens": 100000])
            ])
        ]

        let analytics = ConsolidatedAnalytics(from: events)

        // Cost should be calculated:
        // Input: 1M tokens @ $3/M = $3.00
        // Output: 100K tokens @ $15/M = $1.50
        // Total: $4.50
        XCTAssertEqual(analytics.totalCost, 4.50, accuracy: 0.01)
    }

    // MARK: - Deduplication Tests

    @MainActor
    func testDeduplicateSessionRemovesDuplicates() async throws {
        // Create duplicate events with same type and content prefix
        let events = [
            SessionEvent(
                id: "local-uuid-1",
                parentId: nil,
                sessionId: "session-1",
                workspaceId: "/test",
                type: "message.user",
                timestamp: "2024-01-01T00:00:01Z",
                sequence: 1,
                payload: ["content": AnyCodable("Hello world, this is a test message")]
            ),
            SessionEvent(
                id: "evt_server-1",
                parentId: nil,
                sessionId: "session-1",
                workspaceId: "/test",
                type: "message.user",
                timestamp: "2024-01-01T00:00:02Z",
                sequence: 2,
                payload: ["content": AnyCodable("Hello world, this is a test message")]
            )
        ]

        try database.events.insertBatch(events)

        // Verify both events exist
        let beforeEvents = try database.events.getBySession("session-1")
        XCTAssertEqual(beforeEvents.count, 2)

        // Deduplicate
        let removedCount = try database.deduplicateSession("session-1")

        // Should remove the local event, keep the server event
        XCTAssertEqual(removedCount, 1)

        let afterEvents = try database.events.getBySession("session-1")
        XCTAssertEqual(afterEvents.count, 1)
        XCTAssertEqual(afterEvents.first?.id, "evt_server-1")
    }

    @MainActor
    func testDeduplicatePrefersEventsWithToolBlocks() async throws {
        // Create duplicate events where one has tool blocks
        let eventsWithoutTools = SessionEvent(
            id: "evt_no-tools",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "message.assistant",
            timestamp: "2024-01-01T00:00:01Z",
            sequence: 1,
            payload: ["content": AnyCodable([
                ["type": "text", "text": "Here is my response"]
            ])]
        )

        let eventsWithTools = SessionEvent(
            id: "local-with-tools",
            parentId: nil,
            sessionId: "session-1",
            workspaceId: "/test",
            type: "message.assistant",
            timestamp: "2024-01-01T00:00:02Z",
            sequence: 2,
            payload: ["content": AnyCodable([
                ["type": "text", "text": "Here is my response"],
                ["type": "tool_use", "id": "tool-1", "name": "read_file", "input": ["path": "/test"]]
            ])]
        )

        try database.events.insertBatch([eventsWithoutTools, eventsWithTools])

        let removedCount = try database.deduplicateSession("session-1")

        // Should remove the event without tools, keep the one with tools
        XCTAssertEqual(removedCount, 1)

        let afterEvents = try database.events.getBySession("session-1")
        XCTAssertEqual(afterEvents.count, 1)
        XCTAssertEqual(afterEvents.first?.id, "local-with-tools")
    }

    @MainActor
    func testDeduplicateNoDuplicatesReturnsZero() async throws {
        // Create unique events (different content)
        let events = [
            SessionEvent(
                id: "event-1",
                parentId: nil,
                sessionId: "session-1",
                workspaceId: "/test",
                type: "message.user",
                timestamp: "2024-01-01T00:00:01Z",
                sequence: 1,
                payload: ["content": AnyCodable("First message")]
            ),
            SessionEvent(
                id: "event-2",
                parentId: "event-1",
                sessionId: "session-1",
                workspaceId: "/test",
                type: "message.assistant",
                timestamp: "2024-01-01T00:00:02Z",
                sequence: 2,
                payload: ["content": AnyCodable("Response message")]
            )
        ]

        try database.events.insertBatch(events)

        let removedCount = try database.deduplicateSession("session-1")

        XCTAssertEqual(removedCount, 0)

        let afterEvents = try database.events.getBySession("session-1")
        XCTAssertEqual(afterEvents.count, 2)
    }

    @MainActor
    func testDeduplicateAllSessions() async throws {
        // Create duplicates in two sessions
        let session1Events = [
            SessionEvent(id: "s1-local", parentId: nil, sessionId: "session-1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:00:01Z", sequence: 1, payload: ["content": AnyCodable("Hello session 1")]),
            SessionEvent(id: "s1-evt_server", parentId: nil, sessionId: "session-1", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:00:02Z", sequence: 2, payload: ["content": AnyCodable("Hello session 1")])
        ]

        let session2Events = [
            SessionEvent(id: "s2-local", parentId: nil, sessionId: "session-2", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:00:01Z", sequence: 1, payload: ["content": AnyCodable("Hello session 2")]),
            SessionEvent(id: "evt_s2-server", parentId: nil, sessionId: "session-2", workspaceId: "/test", type: "message.user", timestamp: "2024-01-01T00:00:02Z", sequence: 2, payload: ["content": AnyCodable("Hello session 2")])
        ]

        // Insert sessions first
        try database.sessions.insert(CachedSession(
            id: "session-1", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Session 1", latestModel: "claude-sonnet-4", workingDirectory: "/test",
            createdAt: "2024-01-01T00:00:00Z", lastActivityAt: "2024-01-01T00:00:02Z",
            endedAt: nil, eventCount: 2, messageCount: 2, inputTokens: 0, outputTokens: 0,
            lastTurnInputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, cost: 0,
            isFork: false, serverOrigin: nil
        ))
        try database.sessions.insert(CachedSession(
            id: "session-2", workspaceId: "/test", rootEventId: nil, headEventId: nil,
            title: "Session 2", latestModel: "claude-sonnet-4", workingDirectory: "/test",
            createdAt: "2024-01-01T00:00:00Z", lastActivityAt: "2024-01-01T00:00:02Z",
            endedAt: nil, eventCount: 2, messageCount: 2, inputTokens: 0, outputTokens: 0,
            lastTurnInputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, cost: 0,
            isFork: false, serverOrigin: nil
        ))

        try database.events.insertBatch(session1Events)
        try database.events.insertBatch(session2Events)

        let totalRemoved = try database.deduplicateAllSessions()

        // Should remove 1 duplicate from each session
        XCTAssertEqual(totalRemoved, 2)
    }
}
