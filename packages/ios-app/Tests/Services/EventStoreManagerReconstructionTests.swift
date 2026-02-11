import XCTest
@testable import TronMobile

/// Tests for the unified getSessionEvents method and its integration
/// with getReconstructedState / getChatMessages.
///
/// These tests verify that session reconstruction uses getBySession (single SQL query)
/// instead of getAncestors (N+1 parent-chain walk), fixing the bug where a broken
/// parent chain caused truncated history on session resume.
final class EventStoreManagerReconstructionTests: XCTestCase {

    var database: EventDatabase!
    var storeManager: EventStoreManager!

    @MainActor
    override func setUp() async throws {
        database = EventDatabase()
        try await database.initialize()
        try database.clearAll()

        let rpcClient = RPCClient(serverURL: URL(string: "http://localhost:7399")!)
        storeManager = EventStoreManager(eventDB: database, rpcClient: rpcClient)
    }

    @MainActor
    override func tearDown() async throws {
        try? database.clearAll()
        database.close()
    }

    // MARK: - Helpers

    private func makeSession(
        id: String,
        headEventId: String?,
        rootEventId: String? = nil,
        isFork: Bool = false
    ) -> CachedSession {
        CachedSession(
            id: id,
            workspaceId: "/test",
            rootEventId: rootEventId,
            headEventId: headEventId,
            title: "Test",
            latestModel: "claude-sonnet-4",
            workingDirectory: "/test",
            createdAt: "2024-01-01T00:00:00Z",
            lastActivityAt: "2024-01-01T00:00:00Z",
            eventCount: 0,
            messageCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            lastTurnInputTokens: 0,
            cost: 0.0,
            isFork: isFork
        )
    }

    private func makeEvent(
        id: String,
        parentId: String?,
        sessionId: String,
        type: String = "message.user",
        sequence: Int,
        payload: [String: AnyCodable] = ["content": AnyCodable("test")]
    ) -> SessionEvent {
        SessionEvent(
            id: id,
            parentId: parentId,
            sessionId: sessionId,
            workspaceId: "/test",
            type: type,
            timestamp: "2024-01-01T00:0\(sequence):00Z",
            sequence: sequence,
            payload: payload
        )
    }

    // MARK: - getSessionEvents: Non-Forked Sessions

    @MainActor
    func testGetSessionEvents_nonForkedSession_returnsAllEventsBySequence() async throws {
        // Create 10 events for a non-forked session with proper parent chain
        var events: [SessionEvent] = []
        for i in 1...10 {
            let type = i == 1 ? "session.start" : (i % 2 == 0 ? "message.user" : "message.assistant")
            events.append(makeEvent(
                id: "e\(i)",
                parentId: i > 1 ? "e\(i - 1)" : nil,
                sessionId: "s1",
                type: type,
                sequence: i,
                payload: type == "session.start" ? [:] : ["content": AnyCodable("msg \(i)")]
            ))
        }

        try database.events.insertBatch(events)
        try database.sessions.insert(makeSession(id: "s1", headEventId: "e10", rootEventId: "e1"))

        let (result, presorted) = try storeManager.getSessionEvents(sessionId: "s1")

        XCTAssertEqual(result.count, 10)
        XCTAssertFalse(presorted)
        // Should be in sequence order
        XCTAssertEqual(result.map { $0.id }, (1...10).map { "e\($0)" })
    }

    @MainActor
    func testGetSessionEvents_nonForkedSessionWithBrokenChain_stillReturnsAllEvents() async throws {
        // Core regression test: create 10 events where event at sequence 5 has NULL parent_id
        // This simulates the actual bug — a sync gap that breaks the parent chain
        var events: [SessionEvent] = []
        for i in 1...10 {
            let type = i == 1 ? "session.start" : (i % 2 == 0 ? "message.user" : "message.assistant")
            let parentId: String? = (i == 1 || i == 5) ? nil : "e\(i - 1)"
            events.append(makeEvent(
                id: "e\(i)",
                parentId: parentId,
                sessionId: "s1",
                type: type,
                sequence: i,
                payload: type == "session.start" ? [:] : ["content": AnyCodable("msg \(i)")]
            ))
        }

        try database.events.insertBatch(events)
        try database.sessions.insert(makeSession(id: "s1", headEventId: "e10", rootEventId: "e1"))

        let (result, _) = try storeManager.getSessionEvents(sessionId: "s1")

        // getBySession returns ALL events regardless of parent chain breaks
        XCTAssertEqual(result.count, 10)

        // Contrast with getAncestors which would stop at the break:
        // getAncestors("e10") would follow e10→e9→e8→e7→e6→(e5 has nil parent)→stop
        // returning only 6 events instead of 10
        let ancestors = try database.events.getAncestors("e10")
        XCTAssertLessThan(ancestors.count, result.count, "getAncestors should return fewer events due to broken chain")
    }

    @MainActor
    func testGetSessionEvents_nonForkedSessionWithMissingEvents_returnsWhatExists() async throws {
        // Create events 1-5 and 8-10 (gap at 6-7 simulating partial sync)
        let sequences = [1, 2, 3, 4, 5, 8, 9, 10]
        var events: [SessionEvent] = []
        for i in sequences {
            let type = i == 1 ? "session.start" : (i % 2 == 0 ? "message.user" : "message.assistant")
            events.append(makeEvent(
                id: "e\(i)",
                parentId: i > 1 ? "e\(i - 1)" : nil,
                sessionId: "s1",
                type: type,
                sequence: i,
                payload: type == "session.start" ? [:] : ["content": AnyCodable("msg \(i)")]
            ))
        }

        try database.events.insertBatch(events)
        try database.sessions.insert(makeSession(id: "s1", headEventId: "e10", rootEventId: "e1"))

        let (result, _) = try storeManager.getSessionEvents(sessionId: "s1")

        // getBySession returns all 8 events that exist
        XCTAssertEqual(result.count, 8)

        // getAncestors would stop at the gap: e10→e9→e8→(e7 missing)→stop = 3 events
        let ancestors = try database.events.getAncestors("e10")
        XCTAssertEqual(ancestors.count, 3, "getAncestors stops at first missing event")
    }

    // MARK: - getSessionEvents: Forked Sessions

    @MainActor
    func testGetSessionEvents_forkedSession_includesParentEvents() async throws {
        // Create parent session with 3 events
        let parentEvents = [
            makeEvent(id: "p1", parentId: nil, sessionId: "parent", type: "session.start", sequence: 1, payload: [:]),
            makeEvent(id: "p2", parentId: "p1", sessionId: "parent", type: "message.user", sequence: 2),
            makeEvent(id: "p3", parentId: "p2", sessionId: "parent", type: "message.assistant", sequence: 3),
        ]
        try database.events.insertBatch(parentEvents)
        try database.sessions.insert(makeSession(id: "parent", headEventId: "p3", rootEventId: "p1"))

        // Create forked session with first event's parentId pointing to parent's last event
        let forkEvents = [
            makeEvent(id: "f1", parentId: "p3", sessionId: "forked", type: "session.fork", sequence: 1, payload: [:]),
            makeEvent(id: "f2", parentId: "f1", sessionId: "forked", type: "message.user", sequence: 2),
            makeEvent(id: "f3", parentId: "f2", sessionId: "forked", type: "message.assistant", sequence: 3),
        ]
        try database.events.insertBatch(forkEvents)
        try database.sessions.insert(makeSession(id: "forked", headEventId: "f3", rootEventId: "f1", isFork: true))

        let (result, presorted) = try storeManager.getSessionEvents(sessionId: "forked")

        // Should include parent events + fork events = 6 total
        XCTAssertEqual(result.count, 6)
        XCTAssertTrue(presorted)
        // Parent events first, then fork events
        XCTAssertEqual(result.map { $0.id }, ["p1", "p2", "p3", "f1", "f2", "f3"])
    }

    // MARK: - getSessionEvents: Edge Cases

    @MainActor
    func testGetSessionEvents_emptySession_returnsEmpty() async throws {
        // Session exists but has no events
        try database.sessions.insert(makeSession(id: "empty", headEventId: nil))

        let (result, _) = try storeManager.getSessionEvents(sessionId: "empty")
        XCTAssertTrue(result.isEmpty)
    }

    @MainActor
    func testGetSessionEvents_nonExistentSession_returnsEmpty() async throws {
        let (result, _) = try storeManager.getSessionEvents(sessionId: "does-not-exist")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Integration: getReconstructedState

    @MainActor
    func testGetReconstructedState_nonForkedSession_usesGetBySession() async throws {
        // Create a session with events including notification.interrupted
        // to simulate the actual bug scenario
        let events = [
            makeEvent(id: "e1", parentId: nil, sessionId: "s1", type: "session.start", sequence: 1, payload: [:]),
            makeEvent(id: "e2", parentId: "e1", sessionId: "s1", type: "message.user", sequence: 2,
                      payload: ["content": AnyCodable("Hello before interruption")]),
            makeEvent(id: "e3", parentId: "e2", sessionId: "s1", type: "message.assistant", sequence: 3,
                      payload: ["content": AnyCodable("Response before interruption")]),
            makeEvent(id: "e4", parentId: "e3", sessionId: "s1", type: "notification.interrupted", sequence: 4, payload: [:]),
            makeEvent(id: "e5", parentId: "e4", sessionId: "s1", type: "message.user", sequence: 5,
                      payload: ["content": AnyCodable("Hello after interruption")]),
            makeEvent(id: "e6", parentId: "e5", sessionId: "s1", type: "message.assistant", sequence: 6,
                      payload: ["content": AnyCodable("Response after interruption")]),
        ]
        try database.events.insertBatch(events)
        try database.sessions.insert(makeSession(id: "s1", headEventId: "e6", rootEventId: "e1"))

        let state = try storeManager.getReconstructedState(sessionId: "s1")

        // Should have messages from both before AND after interruption
        XCTAssertGreaterThanOrEqual(state.messages.count, 4, "Should include messages from before and after interruption")

        // Verify messages span the interruption
        let userMessages = state.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 2)
    }

    @MainActor
    func testGetReconstructedState_forkedSession_includesParentMessages() async throws {
        // Create parent session
        let parentEvents = [
            makeEvent(id: "p1", parentId: nil, sessionId: "parent", type: "session.start", sequence: 1, payload: [:]),
            makeEvent(id: "p2", parentId: "p1", sessionId: "parent", type: "message.user", sequence: 2,
                      payload: ["content": AnyCodable("Parent user message")]),
            makeEvent(id: "p3", parentId: "p2", sessionId: "parent", type: "message.assistant", sequence: 3,
                      payload: ["content": AnyCodable("Parent assistant response")]),
        ]
        try database.events.insertBatch(parentEvents)
        try database.sessions.insert(makeSession(id: "parent", headEventId: "p3", rootEventId: "p1"))

        // Create forked session
        let forkEvents = [
            makeEvent(id: "f1", parentId: "p3", sessionId: "forked", type: "session.fork", sequence: 1, payload: [:]),
            makeEvent(id: "f2", parentId: "f1", sessionId: "forked", type: "message.user", sequence: 2,
                      payload: ["content": AnyCodable("Fork user message")]),
            makeEvent(id: "f3", parentId: "f2", sessionId: "forked", type: "message.assistant", sequence: 3,
                      payload: ["content": AnyCodable("Fork assistant response")]),
        ]
        try database.events.insertBatch(forkEvents)
        try database.sessions.insert(makeSession(id: "forked", headEventId: "f3", rootEventId: "f1", isFork: true))

        let state = try storeManager.getReconstructedState(sessionId: "forked")

        // Should include messages from both parent and forked sessions
        let userMessages = state.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 2, "Should include user messages from parent and fork")

        let assistantMessages = state.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 2, "Should include assistant messages from parent and fork")
    }

    // MARK: - Integration: getChatMessages

    @MainActor
    func testGetChatMessages_withBrokenChain_returnsAllMessages() async throws {
        // The core user-facing test: broken parent chain should NOT truncate chat history
        let events = [
            makeEvent(id: "e1", parentId: nil, sessionId: "s1", type: "session.start", sequence: 1, payload: [:]),
            makeEvent(id: "e2", parentId: "e1", sessionId: "s1", type: "message.user", sequence: 2,
                      payload: ["content": AnyCodable("First question")]),
            makeEvent(id: "e3", parentId: "e2", sessionId: "s1", type: "message.assistant", sequence: 3,
                      payload: ["content": AnyCodable("First answer")]),
            // Event e4 has a broken parent chain (simulates sync gap)
            makeEvent(id: "e4", parentId: nil, sessionId: "s1", type: "message.user", sequence: 4,
                      payload: ["content": AnyCodable("Second question")]),
            makeEvent(id: "e5", parentId: "e4", sessionId: "s1", type: "message.assistant", sequence: 5,
                      payload: ["content": AnyCodable("Second answer")]),
        ]
        try database.events.insertBatch(events)
        try database.sessions.insert(makeSession(id: "s1", headEventId: "e5", rootEventId: "e1"))

        let messages = try storeManager.getChatMessages(sessionId: "s1")

        // Should have all 4 messages despite broken parent chain at e4
        XCTAssertEqual(messages.count, 4, "All messages should be returned despite broken parent chain")
    }

    // MARK: - Thinking Deduplication

    @MainActor
    func testGetReconstructedState_filtersLocalThinkingEvents_noDuplicates() async throws {
        // Simulate the bug: ThinkingState persists stream.thinking_complete events locally
        // with sequence: 0 and parentId: nil. When getBySession returns ALL events for
        // the session, these local events would be included and sorted to the beginning
        // (seq 0), producing duplicate thinking blocks — once from the local event and
        // once from the thinking content block inside message.assistant.

        // message.assistant payload with thinking + text content blocks
        // (content is an array of blocks, matching real server format)
        let assistantPayload: [String: AnyCodable] = [
            "content": AnyCodable([
                ["type": "thinking", "thinking": "Let me think about this carefully..."] as [String: Any],
                ["type": "text", "text": "The answer is 42."] as [String: Any]
            ] as [[String: Any]]),
            "turn": AnyCodable(1)
        ]

        // Locally-persisted thinking event (from ThinkingState.endTurn)
        let thinkingPayload: [String: AnyCodable] = [
            "turnNumber": AnyCodable(1),
            "content": AnyCodable("Let me think about this carefully..."),
            "preview": AnyCodable("Let me think about this carefully..."),
            "characterCount": AnyCodable(38),
            "model": AnyCodable("claude-sonnet-4")
        ]

        let events = [
            // Local thinking event: seq 0, parentId nil (exactly as ThinkingState persists it)
            makeEvent(id: "evt_thinking_local", parentId: nil, sessionId: "s1",
                      type: "stream.thinking_complete", sequence: 0, payload: thinkingPayload),
            // Normal server events
            makeEvent(id: "e1", parentId: nil, sessionId: "s1",
                      type: "session.start", sequence: 1, payload: [:]),
            makeEvent(id: "e2", parentId: "e1", sessionId: "s1",
                      type: "message.user", sequence: 2,
                      payload: ["content": AnyCodable("What is the meaning of life?")]),
            makeEvent(id: "e3", parentId: "e2", sessionId: "s1",
                      type: "message.assistant", sequence: 3, payload: assistantPayload),
        ]

        try database.events.insertBatch(events)
        try database.sessions.insert(makeSession(id: "s1", headEventId: "e3", rootEventId: "e1"))

        let state = try storeManager.getReconstructedState(sessionId: "s1")

        // Count thinking messages
        let thinkingMessages = state.messages.filter {
            if case .thinking = $0.content { return true }
            return false
        }

        // Should have exactly ONE thinking message (from message.assistant content blocks),
        // not two (which would happen if stream.thinking_complete also produced one)
        XCTAssertEqual(thinkingMessages.count, 1,
            "Thinking should appear once (from message.assistant), not duplicated by stream.thinking_complete")

        // Verify the user message and text response are present
        let userMessages = state.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1)

        let assistantTextMessages = state.messages.filter {
            guard $0.role == .assistant else { return false }
            if case .text = $0.content { return true }
            return false
        }
        XCTAssertEqual(assistantTextMessages.count, 1)
    }
}
